// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Dani Sandoval
//
// World Rally sprite engine (Gaelco REF.930217) - two-phase, line-buffer based.
// Modeled on MAME gaelco_wrally_sprites.cpp.
//
// PHASE 1 (SCAN+CLEAR): runs concurrently with the tilemap render. Clears the
// visible line buffer and scans all 510 sprite-RAM entries, testing each Y;
// on-line sprites are pushed to a small hit buffer. Uses only the sprite-RAM
// and line-buffer ports (NOT the shared GFX port), so it is free under the
// tilemap. The Y test reads only w0, so off-line sprites cost ~3 cycles.
// PHASE 2 (DRAW): fetches GFX + writes pixels for the buffered hits. This needs
// the GFX ROM port, which the tilemap holds until it finishes (gfx_ok is gated
// by ~tm_busy upstream), so the draw naturally waits for the tilemap then runs.
//
// This keeps sprite work inside one scanline even when the tilemap now renders
// every line: the ~2us scan/clear no longer competes with the post-tilemap
// budget, which is reserved for the (few) on-line sprites.
//
// Sprite RAM: 4 words/entry, entries at word offsets 3,7,...0x7FB (510 entries).
//   w0: [7:0] Y (screen y = (240 - Y) & 0xFF), [14] flip X, [15] flip Y
//   w2: [9:0] X (less 0x0F, wraps at 1024), [13:10] color, [14] shadow mode
//   w3: [13:0] code;  high priority when code >= 0x3700 (MAME hack)
//
// Line buffer pixel format (matches MAME temp bitmap packing):
//   [13:11] shadow bank   [9] shadow enable   [8] priority   [7:0] pen(0=transp)

module wrally_sprites #(
    // Hard per-line draw deadline (in clk_sys cycles since the line-start pulse).
    // The draw phase only gets the GFX port after the tilemap frees it (~3226),
    // so the line has ~6144 cycles total. If a crowded line has more on-line
    // sprites than fit, the engine MUST still return to S_IDLE before the next
    // line's start pulse, or that start is missed -> the page never flips ->
    // sprites display one line stale (vertical smear). So we stop drawing once
    // linecnt passes this deadline and drop the remaining (last-scanned) sprites,
    // like a real arcade per-line sprite limit. The line is 6144 cyc; the done
    // check stops within ~1 cyc (the pipelined draw can halt mid-sprite), so 6050
    // is safe (>90 cyc margin before the next start) while drawing the most
    // sprites possible.
    parameter [12:0] DRAW_DEADLINE = 13'd6050
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,        // pulse at line start (overlaps tilemap)
    input  wire [8:0]  vrender,      // line about to be displayed
    input  wire        flip,
    output reg         busy,

    // sprite RAM read port (2K x 16 BRAM, registered read, 1 cycle latency)
    output reg  [10:0] spram_addr,
    input  wire [15:0] spram_data,

    // GFX ROM (16-bit words within the 2MB tile region)
    output reg  [19:0] gfx_addr,
    output reg         gfx_rd,
    input  wire [15:0] gfx_data,
    input  wire        gfx_ok,

    // line buffer read side (display); 1 cycle latency
    input  wire [9:0]  disp_x,
    output reg  [13:0] disp_pix
);

    // double line buffer, 1024 px wide (sprite coordinate space)
    reg [13:0] linebuf [0:2047];
    reg        page;                  // render page; display reads ~page

    always @(posedge clk) disp_pix <= linebuf[{~page, disp_x}];

    // hit buffer: sprites found on this line (drawn in phase 2). Bounded; if a
    // line ever exceeds this it drops extras (graceful, like HW sprite limits).
    localparam integer MAXSPR = 7'd95;
    reg [13:0] h_code  [0:127];
    reg [9:0]  h_x     [0:127];
    reg [3:0]  h_color [0:127];
    reg [3:0]  h_grow  [0:127];
    reg        h_flipx [0:127];
    reg        h_hipri [0:127];
    reg        h_shadow[0:127];
    reg [6:0]  n_hits;
    reg [6:0]  di;                    // draw index

    localparam [9:0] CLR_W = 10'd384; // clear the full hcnt range (visible)

    localparam [3:0] S_IDLE=4'd0, S_CLR=4'd1, S_A0=4'd2, S_L0=4'd3,
                     S_L2=4'd4, S_L3=4'd5, S_TEST=4'd6,
                     S_DINIT=4'd8, S_DRUN=4'd9;
    reg [3:0]  state;

    reg [8:0]  entry;
    reg [9:0]  clr_x;
    reg [12:0] linecnt;               // cycles since the line-start pulse
    reg [15:0] w0, w2, w3;
    reg [1:0]  word_i;                // fetch-engine word counter
    reg [3:0]  px;
    reg [13:0] old;
    reg [9:0]  xpos;

    // ---- scan-side decode (w0 just latched) ----
    wire [7:0]  spr_y  = w0[7:0];
    wire        flipy  = w0[15];
    wire [8:0]  sy     = flip ? ({1'b0, 8'd240 - spr_y} + 9'd248)
                              : {1'b0, 8'd240 - spr_y};
    wire [8:0]  dy     = (vrender - sy) & 9'h1FF;
    wire        hit    = (dy < 9'd16);
    wire [3:0]  grow_w = flipy ? (4'd15 - dy[3:0]) : dy[3:0];

    // ---- pipelined draw: a FETCH engine fills a 2-slot ping-pong buffer with a
    // sprite's 4 gfx words + draw params, while a DRAW engine drains the slots
    // into the line buffer. The 16-cyc draw of one sprite overlaps the ~36-cyc
    // gfx fetch of the next, roughly halving per-sprite cost vs the old
    // fetch-then-draw serialisation (the gfx port and line-buffer port are
    // independent, so both engines run every cycle). ----
    reg [15:0] b_lo0[0:1], b_lo1[0:1], b_hi0[0:1], b_hi1[0:1];
    reg [9:0]  b_x  [0:1];
    reg [3:0]  b_col[0:1];
    reg        b_hi [0:1], b_sh[0:1], b_fx[0:1];
    reg        b_full[0:1];           // slot holds a fetched sprite ready to draw

    // fetch engine
    reg        f_slot;                // slot the fetch writes
    reg [6:0]  f_di;                  // next hit-buffer entry to fetch
    reg        f_run;                 // a fetch is in progress
    reg [13:0] f_code;
    reg [3:0]  f_grow;

    // draw engine
    reg        d_slot;                // slot the draw reads
    reg        d_run;                 // a draw is in progress
    reg        d_rd;                  // shadow read phase (vs write phase)

    // draw-side decode reads from the active draw slot
    wire [3:0]  gx    = b_fx[d_slot] ? (4'd15 - px) : px;
    wire [2:0]  bidx  = 3'd7 - gx[2:0];
    wire [15:0] wlo   = gx[3] ? b_lo1[d_slot] : b_lo0[d_slot];
    wire [15:0] whi   = gx[3] ? b_hi1[d_slot] : b_hi0[d_slot];
    wire [3:0]  pen   = {whi[{1'b1, bidx}], whi[{1'b0, bidx}],
                         wlo[{1'b1, bidx}], wlo[{1'b0, bidx}]};
    wire [9:0]  xpos_c= (b_x[d_slot] + {6'd0, px} - 10'h00F) & 10'h3FF;

    wire [10:0] w0_addr = {entry, 2'b11};   // entry*4 + 3

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; page <= 1'b0; gfx_rd <= 1'b0;
            linecnt <= 13'd0;
        end else begin
            // position within the scanline; reset by the per-line start pulse
            if (start)           linecnt <= 13'd0;
            else if (~&linecnt)  linecnt <= linecnt + 13'd1;

            case (state)
            S_IDLE: if (start) begin
                busy  <= 1'b1;
                page  <= ~page;
                clr_x <= 10'd0;
                state <= S_CLR;
            end

            // ---- phase 1: clear visible line, then scan all entries ----
            // Reads w0/w2/w3 with the original pipelined timing (address set 2
            // states before the latch, to cover the 1-cycle sprite-RAM read
            // latency). Runs concurrently with the tilemap render (sprite-RAM +
            // line-buffer ports only), so reading all 3 words is free.
            S_CLR: begin
                linebuf[{page, clr_x}] <= 14'd0;
                clr_x <= clr_x + 10'd1;
                if (clr_x == CLR_W-1) begin
                    entry      <= 9'd0;
                    n_hits     <= 7'd0;
                    spram_addr <= 11'd3;      // entry 0, w0
                    state      <= S_A0;
                end
            end

            S_A0: begin                        // w0 addr settling; point at w2
                spram_addr <= spram_addr + 11'd2;
                state <= S_L0;
            end

            S_L0: begin                        // data = w0 (Y); point at w3
                w0 <= spram_data;
                spram_addr <= spram_addr + 11'd1;
                state <= S_L2;
            end

            S_L2: begin                        // data = w2 (X/color/shadow)
                w2 <= spram_data;
                state <= S_L3;
            end

            S_L3: begin                        // data = w3 (code)
                w3 <= spram_data;
                state <= S_TEST;
            end

            S_TEST: begin                      // store on-line, on-screen sprites
                // hit = Y on this line; X<=398 means the sprite's (X-15..X) span
                // can reach the visible 0..383 line buffer. X in [399,1023] is
                // parked off-screen, so cull it (matches MAME's per-pixel clip)
                // to spend the draw budget only on real sprites.
                if (hit && (w2[9:0] <= 10'd398) && (n_hits < MAXSPR)) begin
                    h_code [n_hits] <= w3[13:0];
                    h_x    [n_hits] <= w2[9:0];
                    h_color[n_hits] <= w2[13:10];
                    h_grow [n_hits] <= grow_w;
                    h_flipx[n_hits] <= w0[14];
                    h_hipri[n_hits] <= (w3[13:0] >= 14'h3700);
                    h_shadow[n_hits]<= w2[14];
                    n_hits <= n_hits + 7'd1;
                end
                if (entry == 9'd509) state <= S_DINIT;
                else begin
                    entry      <= entry + 9'd1;
                    spram_addr <= {entry + 9'd1, 2'b11};  // next entry w0
                    state      <= S_A0;
                end
            end

            // ---- phase 2: pipelined draw of the buffered hits (needs GFX port).
            // FETCH engine fills the free ping-pong slot; DRAW engine drains the
            // ready slot into the line buffer. Both run every cycle on independent
            // ports, so the 16-cyc draw overlaps the ~36-cyc fetch of the next
            // sprite (~halves per-sprite cost vs serial fetch-then-draw). ----
            S_DINIT: begin
                di     <= 7'd0;          // sprites drawn
                f_di   <= 7'd0;          // next sprite to fetch
                f_slot <= 1'b0;  d_slot <= 1'b0;
                f_run  <= 1'b0;  d_run  <= 1'b0;  d_rd <= 1'b0;
                b_full[0] <= 1'b0;  b_full[1] <= 1'b0;
                gfx_rd <= 1'b0;
                if (n_hits == 7'd0) begin busy <= 1'b0; state <= S_IDLE; end
                else state <= S_DRUN;
            end

            S_DRUN: begin
                if (di == n_hits || linecnt >= DRAW_DEADLINE) begin
                    // all drawn, or out of line budget (drop the rest gracefully
                    // so we reach S_IDLE before the next start -> page still flips)
                    busy <= 1'b0;  gfx_rd <= 1'b0;  state <= S_IDLE;
                end else begin
                    // ---------- FETCH ENGINE (owns the GFX port) ----------
                    if (f_run) begin
                        gfx_addr <= {1'b0, f_code, 5'b00000}     // code*32
                                  + (word_i[1] ? 20'h80000 : 20'h00000)
                                  + (word_i[0] ? 20'd16 : 20'd0)
                                  + {16'd0, f_grow};
                        gfx_rd <= 1'b1;
                        if (gfx_rd && gfx_ok) begin
                            gfx_rd <= 1'b0;
                            case (word_i)
                                2'd0: b_lo0[f_slot] <= gfx_data;
                                2'd1: b_lo1[f_slot] <= gfx_data;
                                2'd2: b_hi0[f_slot] <= gfx_data;
                                2'd3: b_hi1[f_slot] <= gfx_data;
                            endcase
                            word_i <= word_i + 2'd1;
                            if (word_i == 2'd3) begin   // sprite fetched
                                b_full[f_slot] <= 1'b1;
                                f_run  <= 1'b0;
                                f_slot <= ~f_slot;
                                f_di   <= f_di + 7'd1;
                            end
                        end
                    end else if ((f_di < n_hits) && !b_full[f_slot]) begin
                        // start fetching the next sprite into the free slot
                        b_x  [f_slot] <= h_x   [f_di];
                        b_col[f_slot] <= h_color[f_di];
                        b_hi [f_slot] <= h_hipri[f_di];
                        b_sh [f_slot] <= h_shadow[f_di];
                        b_fx [f_slot] <= h_flipx[f_di];
                        f_code <= h_code[f_di];
                        f_grow <= h_grow[f_di];
                        word_i <= 2'd0;
                        f_run  <= 1'b1;
                    end

                    // ---------- DRAW ENGINE (owns the line-buffer port) ----------
                    if (d_run) begin
                        if (b_sh[d_slot] && !d_rd) begin
                            old  <= linebuf[{page, xpos_c}];   // shadow: read old
                            xpos <= xpos_c;
                            d_rd <= 1'b1;
                        end else begin
                            if (!b_sh[d_slot]) begin           // direct write
                                if (pen != 4'd0)
                                    linebuf[{page, xpos_c}] <=
                                        {5'd0, b_hi[d_slot], b_col[d_slot], pen};
                            end else if (pen >= 4'd8) begin    // shadow blend
                                if (old[7:0] != 8'd0 || old[9:8] != 2'd0)
                                    linebuf[{page, xpos}] <=
                                        {old[13:11] | pen[2:0], old[10], 1'b1, old[8], old[7:0]};
                                else
                                    linebuf[{page, xpos}] <=
                                        {pen[2:0], 1'b0, 1'b1, b_hi[d_slot], 8'd0};
                            end
                            d_rd <= 1'b0;
                            if (px == 4'd15) begin             // sprite drawn
                                b_full[d_slot] <= 1'b0;
                                d_run  <= 1'b0;
                                d_slot <= ~d_slot;
                                di     <= di + 7'd1;
                            end else px <= px + 4'd1;
                        end
                    end else if (b_full[d_slot]) begin
                        px <= 4'd0;  d_rd <= 1'b0;  d_run <= 1'b1;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

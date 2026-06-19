// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Dani Sandoval
//
// World Rally video subsystem (Gaelco REF.930217, two TPC1020AFN FPGAs)
//
// Two 64x32 tilemaps of 16x16 4bpp tiles + sprites, 8192-color palette
// (xBBBBRRRRGGGG, 8 shadow banks of 1024). Line-buffer architecture: while
// line N is shown, line N+1 is rendered (tilemaps first, then sprites).
//
// Timing model (assumption, see doc/hardware.md): 6 MHz pixel clock,
// 384x260 total, visible 368x232 at MAME coordinates x 8..375, y 16..247.
//
// Mixing order, from MAME wrally.cpp screen_update (bottom to top):
//   t1 cat0 (opaque) < t0 cat0 < t1 cat1 < t0 cat1 pens 1-7
//   < sprites pri0 < t0 cat1 pens 8-15 < sprites pri1
// Sprite shadows re-bank the palette of the pixel below (8 banks).

module wrally_video #(
    parameter HTOTAL = 10'd384,
    parameter VTOTAL = 9'd260,
    parameter HB_END = 10'd8,    // first visible pixel
    parameter HB_STR = 10'd376,  // first blanked pixel
    parameter VB_END = 9'd16,
    parameter VB_STR = 9'd248
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        cen_pix,      // 6 MHz enable

    input  wire        flip,
    input  wire [15:0] vregs0,       // scrolly tilemap 0
    input  wire [15:0] vregs1,       // scrollx tilemap 0 (+4)
    input  wire [15:0] vregs2,       // scrolly tilemap 1
    input  wire [15:0] vregs3,       // scrollx tilemap 1

    // VRAM video-side read port (8K x 16, registered, 1 cycle)
    output reg  [12:0] vram_addr,
    input  wire [15:0] vram_data,

    // palette video-side read port (8K x 16, registered, 1 cycle)
    output wire [12:0] pal_addr,
    input  wire [15:0] pal_data,

    // sprite RAM video-side read port (through wrally_sprites)
    output wire [10:0] spram_addr,
    input  wire [15:0] spram_data,

    // GFX ROM, 16-bit words in the 2MB tile region (shared tilemap/sprite)
    output wire [19:0] gfx_addr,
    output wire        gfx_rd,
    input  wire [15:0] gfx_data,
    input  wire        gfx_ok,

    output reg  [3:0]  red, green, blue,
    output reg         hblank, vblank, hsync, vsync,
    output wire        vint          // vertical interrupt strobe (one clk)
);

    // ------------------------------------------------------------- counters
    reg [9:0] hcnt;
    reg [8:0] vcnt;

    wire line_last = (hcnt == HTOTAL-1);
    always @(posedge clk) begin
        if (rst) begin
            hcnt <= 10'd0; vcnt <= 9'd0;
        end else if (cen_pix) begin
            hcnt <= line_last ? 10'd0 : hcnt + 10'd1;
            if (line_last) vcnt <= (vcnt == VTOTAL-1) ? 9'd0 : vcnt + 9'd1;
        end
    end

    assign vint = cen_pix && line_last && (vcnt == VB_STR-1);

    // line to be rendered while vcnt is displayed
    wire [8:0] vrender = (vcnt == VTOTAL-1) ? 9'd0 : vcnt + 9'd1;
    wire       render_go = cen_pix && (hcnt == 10'd0);

    // ------------------------------------------------- tilemap line buffers
    // entry: [9] category, [8:4] color, [3:0] pen
    reg [9:0] lb0 [0:1023];  // 2 pages x 512 (384 used)
    reg [9:0] lb1 [0:1023];
    reg       lpage;         // render page; display reads ~lpage

    // ------------------------------------------------------ tilemap fetcher
    // scroll: MAME wrally.cpp screen_update (+4 x offset on tilemap 0).
    // Flip screen handled by coordinate reversal (approximation - cocktail
    // mode untested, see README).
    // 1024 - x == -x in mod-1024 scroll space
    wire [9:0] sx0 = flip ? (10'd0 - vregs1[9:0] - 10'd4) : (vregs1[9:0] + 10'd4);
    wire [9:0] sx1 = flip ? (10'd0 - vregs3[9:0])         : vregs3[9:0];
    wire [8:0] sy0 = flip ? (9'd248 - vregs0[8:0])           : vregs0[8:0];
    wire [8:0] sy1 = flip ? (9'd248 - vregs2[8:0])           : vregs2[8:0];

    localparam [2:0] T_IDLE = 3'd0, T_ENT0 = 3'd1, T_ENT1 = 3'd2,
                     T_ATTR = 3'd3, T_GFX = 3'd4, T_EMIT = 3'd5, T_DONE = 3'd6;
    reg [2:0]  tstate;
    reg        tlayer;            // 0 = tilemap0, 1 = tilemap1
    reg [4:0]  tile_i;            // 0..24 (25 tiles cover 384+15)
    reg [15:0] t_code, t_attr;
    reg [1:0]  t_word;
    reg [15:0] t_lo0, t_lo1, t_hi0, t_hi1;
    reg [4:0]  t_px;
    reg        tm_busy;
    reg        t_gfx_rd;
    reg [19:0] t_gfx_addr;

    wire [8:0] vy0  = (vrender + sy0) & 9'h1FF;
    wire [8:0] vy1  = (vrender + sy1) & 9'h1FF;
    wire [9:0] sx   = tlayer ? sx1 : sx0;
    wire [8:0] vy   = tlayer ? vy1 : vy0;
    // MAME get_tile_info: TILE_FLIPYX((data2>>6)&3) -> flipX=attr[6], flipY=attr[7]
    // (TILE_FLIPYX is (yx&3): bit0=TILE_FLIPX, bit1=TILE_FLIPY; the wrally.cpp doc
    // comment that says bit6=flipy/bit7=flipx is mislabeled). flip Y mirrors the
    // row; flip X mirrors the pixel column.
    wire [3:0] trow = t_attr[7] ? (4'd15 - vy[3:0]) : vy[3:0];  // flip y = attr[7]

    // pixel pen extraction (same GFX layout as sprites)
    wire [3:0] e_gx   = t_attr[6] ? (4'd15 - t_px[3:0]) : t_px[3:0]; // flip x = attr[6]
    wire [2:0] e_bidx = 3'd7 - e_gx[2:0];
    wire [15:0] e_wlo = e_gx[3] ? t_lo1 : t_lo0;
    wire [15:0] e_whi = e_gx[3] ? t_hi1 : t_hi0;
    wire [3:0]  e_pen = {e_whi[{1'b1, e_bidx}], e_whi[{1'b0, e_bidx}],
                         e_wlo[{1'b1, e_bidx}], e_wlo[{1'b0, e_bidx}]};

    // screen x for emitted pixel: tile_i*16 - fine_scroll + px
    wire signed [11:0] emit_x = $signed({3'b000, tile_i, 4'b0000})
                              - $signed({8'd0, sx[3:0]})
                              + $signed({8'd0, t_px[3:0]});

    // helper column addresses
    wire [5:0] tcol_start  = sx0[9:4];               // layer 0 first tile
    wire [5:0] tcol1_start = sx1[9:4];               // layer 1 first tile
    wire [5:0] tcol_next   = sx[9:4] + {1'b0, tile_i} + 6'd1;

    always @(posedge clk) begin
        if (rst) begin
            tstate <= T_IDLE; tm_busy <= 1'b0; t_gfx_rd <= 1'b0;
        end else case (tstate)
            T_IDLE: if (render_go) begin
                tm_busy <= 1'b1;
                lpage   <= ~lpage;
                tlayer  <= 1'b0;
                tile_i  <= 5'd0;
                vram_addr <= {1'b0, vy0[8:4], tcol_start, 1'b0};
                tstate  <= T_ENT0;
            end

            T_ENT0: begin   // address settling for code word
                vram_addr <= vram_addr | 13'd1;     // attr word
                tstate <= T_ENT1;
            end

            T_ENT1: begin   // vram_data = code
                t_code <= vram_data;
                tstate <= T_ATTR;
            end

            T_ATTR: begin   // vram_data = attr
                t_attr <= vram_data;
                t_word <= 2'd0;
                tstate <= T_GFX;
            end

            T_GFX: begin
                t_gfx_addr <= {1'b0, t_code[13:0], 5'b00000}
                            + (t_word[1] ? 20'h80000 : 20'h00000)
                            + (t_word[0] ? 20'd16 : 20'd0)
                            + {16'd0, trow};
                t_gfx_rd <= 1'b1;
                if (t_gfx_rd && gfx_ok) begin
                    t_gfx_rd <= 1'b0;
                    case (t_word)
                        2'd0: t_lo0 <= gfx_data;
                        2'd1: t_lo1 <= gfx_data;
                        2'd2: t_hi0 <= gfx_data;
                        2'd3: t_hi1 <= gfx_data;
                    endcase
                    t_word <= t_word + 2'd1;
                    if (t_word == 2'd3) begin
                        t_px   <= 5'd0;
                        tstate <= T_EMIT;
                    end
                end
            end

            T_EMIT: begin
                if (emit_x >= 0 && emit_x < $signed({2'd0, HTOTAL})) begin
                    if (!tlayer)
                        lb0[{lpage, emit_x[8:0]}] <=
                            {t_attr[5], t_attr[4:0], e_pen};
                    else
                        lb1[{lpage, emit_x[8:0]}] <=
                            {t_attr[5], t_attr[4:0], e_pen};
                end
                t_px <= t_px + 5'd1;
                if (t_px == 5'd15) begin
                    if (tile_i == 5'd24) begin
                        if (!tlayer) begin
                            tlayer <= 1'b1;
                            tile_i <= 5'd0;
                            vram_addr <= {1'b1, vy1[8:4], tcol1_start, 1'b0};
                            tstate <= T_ENT0;
                        end else begin
                            tm_busy <= 1'b0;
                            tstate  <= T_IDLE;   // ready for next render_go now;
                        end                      // parking in T_DONE wasted a
                                                 // scanline -> vertical doubling
                    end else begin
                        tile_i <= tile_i + 5'd1;
                        vram_addr <= {tlayer, vy[8:4], tcol_next, 1'b0};
                        tstate <= T_ENT0;
                    end
                end
            end

            T_DONE: if (render_go) tstate <= T_IDLE; else tstate <= T_DONE;

            default: tstate <= T_IDLE;
        endcase
    end

    // --------------------------------------------------------- sprite engine
    wire        spr_busy;
    wire [19:0] s_gfx_addr;
    wire        s_gfx_rd;
    reg         spr_start;

    // Start sprites at line begin (same render_go as the tilemap, same vrender).
    // Their clear+scan use the sprite-RAM/line-buffer ports, so they overlap the
    // tilemap render for free; the GFX fetch/draw phase then waits for the
    // tilemap to release the shared GFX port (gfx_ok is gated by ~tm_busy).
    always @(posedge clk) begin
        if (rst) spr_start <= 1'b0;
        else     spr_start <= render_go;
    end

    wire [9:0]  spr_disp_x;
    wire [13:0] spr_pix;

    wrally_sprites u_sprites(
        .clk        (clk),
        .rst        (rst),
        .start      (spr_start),
        .vrender    (vrender),
        .flip       (flip),
        .busy       (spr_busy),
        .spram_addr (spram_addr),
        .spram_data (spram_data),
        .gfx_addr   (s_gfx_addr),
        .gfx_rd     (s_gfx_rd),
        .gfx_data   (gfx_data),
        .gfx_ok     (gfx_ok & ~tm_busy),
        .disp_x     (spr_disp_x),
        .disp_pix   (spr_pix)
    );

    // GFX port: tilemap FSM owns it while busy, sprites afterwards
    assign gfx_addr = tm_busy ? t_gfx_addr : s_gfx_addr;
    assign gfx_rd   = tm_busy ? t_gfx_rd   : s_gfx_rd;

    // --------------------------------------------------------------- mixer
    // pipeline: hcnt -> linebuffer read (1) -> mix/palette addr (1)
    //           -> palette data (1) -> RGB. PIPE = 3 cen ticks.
    reg [9:0] mix0, mix1;
    always @(posedge clk) if (cen_pix) begin
        mix0 <= lb0[{~lpage, hcnt[8:0]}];
        mix1 <= lb1[{~lpage, hcnt[8:0]}];
    end
    // sprite buffer x: sprite space is 1024 wide; screen x maps 1:1
    assign spr_disp_x = hcnt;

    wire [3:0] t0_pen  = mix0[3:0];
    wire       t0_cat  = mix0[9];
    wire [8:0] t0_idx  = mix0[8:0];
    wire [3:0] t1_pen  = mix1[3:0];
    wire       t1_cat  = mix1[9];
    wire [8:0] t1_idx  = mix1[8:0];

    wire [7:0] sp_pen8  = spr_pix[7:0];
    wire       sp_pri   = spr_pix[8];
    wire       sp_shad  = spr_pix[9];
    wire [2:0] sp_bank  = spr_pix[13:11];
    wire       sp_valid = (sp_pen8 != 8'd0) || sp_shad;

    reg  [9:0] base_idx;     // layers below sprites pri0
    reg        t0hi;         // t0 cat1 pens 8-15 present
    reg  [9:0] mix_idx;
    reg  [2:0] mix_bank;

    always @* begin
        // bottom-up painter
        base_idx = {1'b0, t1_idx};                          // t1 opaque
        if (t0_pen != 4'd0 && !t0_cat) base_idx = {1'b0, t0_idx};
        if (t1_pen != 4'd0 &&  t1_cat) base_idx = {1'b0, t1_idx};
        if (t0_pen != 4'd0 && t0_pen < 4'd8 && t0_cat)
            base_idx = {1'b0, t0_idx};
        t0hi = (t0_pen >= 4'd8) && t0_cat;

        mix_idx  = base_idx;
        mix_bank = 3'd0;

        if (sp_valid && !sp_pri) begin
            if (!sp_shad)       mix_idx = 10'h200 + {2'd0, sp_pen8};
            else begin
                mix_bank = sp_bank;
                if (sp_pen8 != 8'd0) mix_idx = 10'h200 + {2'd0, sp_pen8};
            end
        end
        if (t0hi) begin
            mix_idx  = {1'b0, t0_idx};
            mix_bank = 3'd0;
        end
        if (sp_valid && sp_pri) begin
            if (!sp_shad)       begin mix_idx = 10'h200 + {2'd0, sp_pen8}; mix_bank = 3'd0; end
            else begin
                mix_bank = sp_bank;
                if (sp_pen8 != 8'd0) mix_idx = 10'h200 + {2'd0, sp_pen8};
            end
        end
    end

    assign pal_addr = {mix_bank, mix_idx};

    // ------------------------------------------------------ output pipeline
    localparam PIPE = 3;
    reg [PIPE-1:0] hb_d, vb_d, hs_d, vs_d;

    wire hb_now = (hcnt < HB_END) || (hcnt >= HB_STR);
    wire vb_now = (vcnt < VB_END) || (vcnt >= VB_STR);
    wire hs_now = (hcnt >= 10'd378) && (hcnt < 10'd382);
    wire vs_now = (vcnt >= 9'd252) && (vcnt < 9'd255);

    always @(posedge clk) if (cen_pix) begin
        hb_d <= {hb_d[PIPE-2:0], hb_now};
        vb_d <= {vb_d[PIPE-2:0], vb_now};
        hs_d <= {hs_d[PIPE-2:0], hs_now};
        vs_d <= {vs_d[PIPE-2:0], vs_now};

        hblank <= hb_d[PIPE-1];
        vblank <= vb_d[PIPE-1];
        hsync  <= hs_d[PIPE-1];
        vsync  <= vs_d[PIPE-1];

        // palette word: x BBBB RRRR GGGG
        if (hb_d[PIPE-1] || vb_d[PIPE-1]) begin
            red <= 4'd0; green <= 4'd0; blue <= 4'd0;
        end else begin
            blue  <= pal_data[11:8];
            red   <= pal_data[7:4];
            green <= pal_data[3:0];
        end
    end

endmodule

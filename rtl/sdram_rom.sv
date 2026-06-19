// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Dani Sandoval
//
// Simple SDRAM ROM controller for World Rally (MiSTer 32MB module, 16-bit).
// Three read ports (cpu / gfx / oki) + one write port (ioctl download).
// CAS latency 2, single-word reads, auto-refresh when idle. UNTESTED - this
// is scaffold code; timing review against the SDRAM datasheet is required.
//
// clk = 96 MHz. SDRAM_CLK should be phase-shifted by the PLL (-2ns typical).

module sdram_rom(
    input  wire        clk,
    input  wire        init,          // power-on / pll-locked reset
    input  wire        cap_late,      // read-data capture point: 0 = bstate6
                                      // (JEDEC CL2 min); 1 = bstate7 (+1 clk).
                                      // On real HW the chip tAC + SDRAM_CLK
                                      // phase push the data eye ~1 clk later
                                      // than the CL2 minimum, so bstate6 samples
                                      // BEFORE the eye opens (the gfx striping);
                                      // bstate7 lands in the eye. Both are plain
                                      // clk-posedge input captures (no CDC).

    // SDRAM chip interface
    inout  wire [15:0] SDRAM_DQ,
    output reg  [12:0] SDRAM_A,
    output reg  [1:0]  SDRAM_BA,
    output reg  [1:0]  SDRAM_DQM,
    output reg         SDRAM_nCS,
    output reg         SDRAM_nRAS,
    output reg         SDRAM_nCAS,
    output reg         SDRAM_nWE,
    output wire        SDRAM_CKE,

    // download write port (word writes, addr = word address)
    input  wire        dl_wr,
    input  wire [23:0] dl_addr,
    input  wire [15:0] dl_data,
    output reg         dl_ack,

    // read port 0: 68000 program (highest priority after gfx)
    input  wire        cpu_rd,
    input  wire [23:0] cpu_addr,
    output reg  [15:0] cpu_dout,
    output reg         cpu_ok,

    // read port 1: gfx (highest priority)
    input  wire        gfx_rd,
    input  wire [23:0] gfx_addr,
    output reg  [15:0] gfx_dout,
    output reg         gfx_ok,

    // read port 2: oki
    input  wire        oki_rd,
    input  wire [23:0] oki_addr,
    output reg  [15:0] oki_dout,
    output reg         oki_ok
);

    assign SDRAM_CKE = 1'b1;

    // Proper bidirectional DQ: drive only during writes, else high-Z.
    reg [15:0] dq_out;
    reg        dq_oe;
    assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;

    localparam CMD_NOP     = 4'b0111;
    localparam CMD_ACTIVE  = 4'b0011;
    localparam CMD_READ    = 4'b0101;
    localparam CMD_WRITE   = 4'b0100;
    localparam CMD_PRECHG  = 4'b0010;
    localparam CMD_REFRESH = 4'b0001;
    localparam CMD_MODE    = 4'b0000;

    reg [3:0] cmd;
    always @* {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

    // init sequence then request service
    localparam I_WAIT = 0, I_PRE = 1, I_REF1 = 2, I_REF2 = 3, I_MODE = 4,
               I_RUN  = 5;
    reg [2:0]  istate;
    reg [15:0] delay;

    // requester edge tracking: each port holds rd high until ok
    reg  [1:0]  owner;        // 0 cpu, 1 gfx, 2 oki, 3 write/refresh
    reg  [3:0]  bstate;
    reg  [23:0] addr_l;
    reg  [15:0] wdata_l;
    reg         is_write;
    reg  [9:0]  ref_cnt;
    reg         ref_due;
    // OKI has no read strobe (jt6295 just drives rom_addr, oki_rd tied high),
    // so re-fetch whenever the address changes instead of waiting for rd to
    // drop. oki_served = address whose data is currently in oki_dout.
    reg  [23:0] oki_served;
    // After a gfx read, briefly reserve the bus for gfx so the video fetch FSMs
    // can issue their next word read without cpu/oki stealing the slot in the
    // handshake gap (cuts per-word cost ~15->~10 cyc, freeing per-line budget
    // for tiles + sprites). cpu/oki are only held while gfx isn't yet pending.
    reg  [2:0]  gfx_hold;

    wire pend_gfx = gfx_rd && !gfx_ok;
    wire pend_cpu = cpu_rd && !cpu_ok;
    wire pend_oki = oki_rd && (!oki_ok || (oki_addr != oki_served));
    wire pend_wr  = dl_wr  && !dl_ack;

    // Bounded OKI anti-starvation. The OKI is normally the LOWEST read priority
    // (gated by gfx_hold like cpu) so it NEVER perturbs the tight per-line gfx
    // fetch budget -> no video flicker. But if a pending OKI read goes unserved
    // for OKI_URGENT clk it escalates ABOVE gfx (and past gfx_hold) for one read.
    // This bounds OKI latency to ~100 clk, far inside its ~400-clk jt6295 service
    // window, while only stealing a gfx slot in the very densest scenes.
    localparam [6:0] OKI_URGENT = 7'd96;
    reg  [6:0] oki_wait;
    wire oki_urgent = pend_oki && (oki_wait >= OKI_URGENT);

    always @(posedge clk) begin
        cmd <= CMD_NOP;
        dq_oe <= 1'b0;

        // refresh interval ~7.8us @96MHz = 750 cycles
        ref_cnt <= ref_cnt + 10'd1;
        if (ref_cnt == 10'd740) begin ref_due <= 1'b1; ref_cnt <= 10'd0; end

        if (gfx_hold != 3'd0) gfx_hold <= gfx_hold - 3'd1;

        if (init) begin
            istate <= I_WAIT; delay <= 16'd19200;   // 200us
            cpu_ok <= 1'b0; gfx_ok <= 1'b0; oki_ok <= 1'b0; dl_ack <= 1'b0;
            bstate <= 4'd0; ref_due <= 1'b0; ref_cnt <= 10'd0; gfx_hold <= 3'd0;
            oki_served <= 24'hFFFFFF; oki_wait <= 7'd0;
        end else case (istate)
            I_WAIT: begin
                delay <= delay - 16'd1;
                if (delay == 0) begin cmd <= CMD_PRECHG; SDRAM_A[10] <= 1'b1;
                                      delay <= 16'd4; istate <= I_REF1; end
            end
            I_REF1: begin
                delay <= delay - 16'd1;
                if (delay == 0) begin cmd <= CMD_REFRESH; delay <= 16'd8;
                                      istate <= I_REF2; end
            end
            I_REF2: begin
                delay <= delay - 16'd1;
                if (delay == 0) begin cmd <= CMD_REFRESH; delay <= 16'd8;
                                      istate <= I_MODE; end
            end
            I_MODE: begin
                delay <= delay - 16'd1;
                if (delay == 0) begin
                    cmd <= CMD_MODE;
                    SDRAM_A  <= 13'b000_0_00_010_0_000;  // CL2, burst 1
                    SDRAM_BA <= 2'b00;
                    delay <= 16'd4;
                    istate <= I_RUN;
                end
            end

            I_RUN: begin
                // drop ok when the requester releases rd
                if (!cpu_rd) cpu_ok <= 1'b0;
                if (!gfx_rd) gfx_ok <= 1'b0;
                // OKI: rd is tied high, so invalidate ok when addr moves on
                if (!oki_rd || (oki_ok && oki_addr != oki_served)) oki_ok <= 1'b0;
                if (!dl_wr)  dl_ack <= 1'b0;

                // anti-starvation: count how long a pending OKI read waits
                if (!pend_oki)              oki_wait <= 7'd0;
                else if (oki_wait != 7'h7F) oki_wait <= oki_wait + 7'd1;

                case (bstate)
                4'd0: begin
                    if (ref_due) begin
                        cmd <= CMD_REFRESH; ref_due <= 1'b0; bstate <= 4'd8;
                    end else if (pend_wr || oki_urgent || pend_gfx ||
                                 ((gfx_hold == 3'd0) && (pend_cpu || pend_oki))) begin
                        // Priority: write > urgent-OKI > gfx > (gfx_hold clear:) cpu
                        // > normal-OKI. gfx keeps its burst reservation (gfx_hold)
                        // so the video fetch budget is undisturbed; OKI only jumps
                        // the queue once it has waited OKI_URGENT clk (rare).
                        is_write <= pend_wr;
                        owner    <= pend_wr    ? 2'd3 :
                                    oki_urgent ? 2'd2 :
                                    pend_gfx   ? 2'd1 :
                                    pend_cpu   ? 2'd0 : 2'd2;
                        addr_l   <= pend_wr    ? dl_addr :
                                    oki_urgent ? oki_addr :
                                    pend_gfx   ? gfx_addr :
                                    pend_cpu   ? cpu_addr : oki_addr;
                        wdata_l  <= dl_data;
                        bstate   <= 4'd1;
                    end
                end
                4'd1: begin                    // ACTIVE row
                    cmd      <= CMD_ACTIVE;
                    SDRAM_BA <= addr_l[23:22];
                    SDRAM_A  <= addr_l[21:9];
                    bstate   <= 4'd2;
                end
                4'd2: bstate <= 4'd3;          // tRCD
                4'd3: begin                    // READ/WRITE with autoprecharge
                    SDRAM_BA <= addr_l[23:22];
                    SDRAM_A  <= {4'b0010, addr_l[8:0]};  // A10=1 autoprechg
                    SDRAM_DQM <= 2'b00;
                    if (is_write) begin
                        cmd <= CMD_WRITE;
                        dq_out <= wdata_l;
                        dq_oe  <= 1'b1;
                        bstate <= 4'd6;
                    end else begin
                        cmd <= CMD_READ;
                        bstate <= 4'd4;
                    end
                end
                4'd4: bstate <= 4'd5;          // CL2 latency wait
                4'd5: bstate <= 4'd6;          // CL2 latency wait
                4'd6: begin                    // CL2 minimum capture point
                    if (is_write) begin
                        dl_ack <= 1'b1;        // writes route 3->6 directly
                    end else if (!cap_late) begin  // early capture (legacy)
                        case (owner)
                            2'd0: begin cpu_dout <= SDRAM_DQ; cpu_ok <= 1'b1; end
                            2'd1: begin gfx_dout <= SDRAM_DQ; gfx_ok <= 1'b1;
                                        gfx_hold <= 3'd5; end
                            2'd2: begin oki_dout <= SDRAM_DQ; oki_ok <= 1'b1;
                                        oki_served <= addr_l; end
                            default: ;
                        endcase
                    end
                    bstate <= 4'd7;
                end
                4'd7: begin                    // +1 clk: data-eye centre on HW
                    if (!is_write && cap_late) begin
                        case (owner)
                            2'd0: begin cpu_dout <= SDRAM_DQ; cpu_ok <= 1'b1; end
                            2'd1: begin gfx_dout <= SDRAM_DQ; gfx_ok <= 1'b1;
                                        gfx_hold <= 3'd5; end
                            2'd2: begin oki_dout <= SDRAM_DQ; oki_ok <= 1'b1;
                                        oki_served <= addr_l; end
                            default: ;
                        endcase
                    end
                    bstate <= 4'd0;            // tRP / tWR recovery margin
                end
                4'd8: bstate <= 4'd9;          // refresh tRFC chain
                4'd9: bstate <= 4'd10;
                4'd10: bstate <= 4'd11;
                4'd11: bstate <= 4'd12;
                4'd12: bstate <= 4'd13;
                4'd13: bstate <= 4'd0;
                default: bstate <= 4'd0;
                endcase
            end
            default: istate <= I_RUN;
        endcase
    end

endmodule

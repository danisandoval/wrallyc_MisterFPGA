// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Dani Sandoval
//
// DS5002FP-flavoured 8051 built around the R8051 CPU core (Li Xinbing,
// Apache-2.0, vendor/R8051).
//
// World Rally's MCU program (wrdallas.bin) was statically analysed
// (recursive-descent disassembly, see session notes / README): it uses NO
// timers, NO serial port and never enables interrupts (IE never written).
// The only SFRs it touches outside the CPU registers are:
//   PCON (0x87)  - watchdog/power-fail bits; plain R/W register here
//   TA   (0xC7)  - timed-access gate; accepted and ignored
//   MCON (0xC6)  - written 0x88 at boot
//   RPCTL(0xD8)  - written 0x20 at boot (EXBS=1!)
//   CRCR (0xC1)  - written 0x80 at boot
//
// MOVX routing implements MAME ds5002fp.cpp external_ram_iaddr():
//   PES (MCON.2)                        -> peripherals (unused, reads 0)
//   !PM (MCON.1) && !EXBS (RPCTL.5) &&
//     addr >= partition && addr <= range -> internal SRAM as data
//   otherwise                            -> expanded bus (host shared RAM)
// xd_addr[16] = 1 selects internal SRAM, matching MAME's +0x10000 trick.
// Note World Rally sets EXBS=1 right after boot, so in practice all MOVX
// go to the shared RAM.

module mcs51_core(
    input  wire        clk,
    input  wire        cen,
    input  wire        rst,

    // program memory (byte, registered read expected)
    output wire [15:0] rom_addr,
    input  wire [7:0]  rom_data,

    // MOVX bus, 17-bit MAME-style address (bit16 = internal SRAM as data)
    output wire [16:0] xd_addr,
    output wire [7:0]  xd_dout,
    input  wire [7:0]  xd_din,
    output wire        xd_we,
    output wire        xd_rd
);

    // ------------------------------------------------------------- R8051
    // R8051 protocol notes (from reading r8051.v, verified in sim):
    // rom_en/rom_addr and the ram enables are COMBINATIONAL and only valid
    // during the requesting work_en cycle; the address drifts to the next
    // value immediately after. The data must therefore be captured against
    // the request-cycle address and held until the core's next enabled
    // cycle consumes it (cmd0 = rom_byte is combinational at that point).
    wire        rom_en;
    reg         rom_vld;

    // 8051 mode (not TYPE8052): DS5002FP has a 128-byte scratchpad;
    // indirect accesses fold into the data/sfr enables inside r8051.
    wire        rd_en_data, rd_en_sfr, rd_en_xdata;
    wire [15:0] rd_addr;
    reg  [7:0]  rd_byte;
    wire        wr_en_data, wr_en_sfr, wr_en_xdata;
    wire [15:0] wr_addr;
    wire [7:0]  wr_byte;

    wire [15:0] cpu_rom_addr;

    r8051 u_cpu(
        .clk            (clk),
        .rst            (rst),
        .cpu_en         (cen),
        .cpu_restart    (1'b0),

        .rom_en         (rom_en),
        .rom_addr       (cpu_rom_addr),
        .rom_byte       (rom_data),
        .rom_vld        (rom_vld),

        .ram_rd_en_data (rd_en_data),
        .ram_rd_en_sfr  (rd_en_sfr),
        .ram_rd_en_xdata(rd_en_xdata),
        .ram_rd_addr    (rd_addr),
        .ram_rd_byte    (rd_byte),
        .ram_rd_vld     (1'b1),

        .ram_wr_en_data (wr_en_data),
        .ram_wr_en_sfr  (wr_en_sfr),
        .ram_wr_en_xdata(wr_en_xdata),
        .ram_wr_addr    (wr_addr),
        .ram_wr_byte    (wr_byte)
    );

    always @(posedge clk) rom_vld <= rom_en;

    // hold the fetch address from the request cycle so the program memory
    // keeps serving the requested byte until it is consumed
    reg  [15:0] fetch_a;
    always @(posedge clk) if (rom_en) fetch_a <= cpu_rom_addr;
    assign rom_addr = rom_en ? cpu_rom_addr : fetch_a;

    // ------------------------------------------- internal RAM (128 bytes)
    reg [7:0] iram [0:127];
    reg [7:0] iram_q;

    always @(posedge clk) begin
        if (wr_en_data) iram[wr_addr[6:0]] <= wr_byte;
        if (rd_en_data) iram_q <= iram[rd_addr[6:0]];
    end

    // ------------------------------------------------------ SFR registers
    reg [7:0] pcon, mcon, rpctl, crcr;

    always @(posedge clk) begin
        if (rst) begin
            // NVRAM bootstrap defaults (MAME wrally.cpp ROM region):
            pcon  <= 8'h00;
            mcon  <= 8'h88;
            rpctl <= 8'h00;
            crcr  <= 8'h80;
        end else if (wr_en_sfr) case (wr_addr[7:0])
            8'h87: pcon  <= wr_byte;
            8'hC6: mcon  <= wr_byte;
            8'hD8: rpctl <= wr_byte;
            8'hC1: crcr  <= wr_byte;
            default: ;                // TA (0xC7) and others: ignored
        endcase
    end

    reg [7:0] sfr_q;
    always @(posedge clk) if (rd_en_sfr) case (rd_addr[7:0])
        8'h87:   sfr_q <= pcon;
        8'hC6:   sfr_q <= mcon;
        8'hD8:   sfr_q <= rpctl;
        8'hC1:   sfr_q <= crcr;
        default: sfr_q <= 8'h00;
    endcase

    // ------------------------------------------------------- MOVX routing
    wire [15:0] range = (mcon[3] ? (rpctl[0] ? 16'hFFFF : 16'h7FFF)
                                 : (rpctl[0] ? 16'h3FFF : 16'h1FFF));
    wire [15:0] partition = mcon[4] ? 16'h1000 : 16'h0000;

    function automatic to_sram(input [15:0] a);
        to_sram = !mcon[2] && !mcon[1] && !rpctl[5]
                  && (a >= partition) && (a <= range);
    endfunction

    // read and write cannot collide in the same cen tick on this core.
    // Like the fetch address, MOVX addresses are only valid during the
    // request cycle - hold them until the data is consumed.
    wire [15:0] x_a    = wr_en_xdata ? wr_addr : rd_addr;
    wire [16:0] xa_now = {to_sram(x_a), x_a};
    reg  [16:0] xa_r;
    always @(posedge clk) if (rd_en_xdata || wr_en_xdata) xa_r <= xa_now;

    assign xd_addr = (rd_en_xdata || wr_en_xdata) ? xa_now : xa_r;
    assign xd_dout = wr_byte;
    assign xd_we   = wr_en_xdata;
    assign xd_rd   = rd_en_xdata;

    // ---------------------------------------------------------- read mux
    reg [1:0] rd_src;   // 0 iram, 1 sfr, 2 xdata
    always @(posedge clk) begin
        if (rd_en_data)        rd_src <= 2'd0;
        else if (rd_en_sfr)    rd_src <= 2'd1;
        else if (rd_en_xdata)  rd_src <= 2'd2;
    end

    always @* case (rd_src)
        2'd0:    rd_byte = iram_q;
        2'd1:    rd_byte = sfr_q;
        default: rd_byte = xd_din;
    endcase

endmodule

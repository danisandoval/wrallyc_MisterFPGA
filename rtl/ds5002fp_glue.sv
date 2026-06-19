// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Dani Sandoval
//
// DS5002FP subsystem for World Rally.
//
// MAME's wrdallas.bin dump is PLAINTEXT 8051 code (decrypted with Gaelco's
// help) so no Dallas bus encryption is needed; what remains is a standard
// 8051 CPU plus the DS5002FP memory partitioning. With the registers the
// game runs under (MCON=0x88, RPCTL=0x00 -> PA=partition 0x0000, range
// 0x7FFF, partitioned mode, expanded bus enabled; from MAME
// ds5002fp.cpp::external_ram_iaddr):
//
//   code  fetch 0x0000-0x7FFF -> 32KB SRAM
//   MOVX  0x0000-0x7FFF       -> the same SRAM, as data (byte-wide bus)
//   MOVX  0x8000-0xFFFF       -> expanded bus = 68000 shared RAM,
//                                address masked to 0x3FFF (16KB, mirrored)
//
// The MCON/RPCTL values are bootstrap defaults held in NVRAM; the game does
// not change them (assumption - matches MAME behaviour, where they are ROM
// defaults).
//
// The 8051 CPU core itself is vendored (see get_deps.sh / README). Expected
// wrapper interface `mcs51_core`: a synchronous 8051 with external program
// and MOVX buses. Timers/interrupts/serial per standard 8051; the DS5002FP
// watchdog and RNG are not required by the World Rally program as emulated
// by MAME (it implements none of them beyond the registers).

module ds5002fp_glue(
    input  wire        clk,
    input  wire        rst,
    input  wire        cen12,       // DS5002FP clock enable (12 MHz)

    // shared RAM byte port (to wrally_top)
    output wire [13:0] sh_addr,
    output wire [7:0]  sh_dout,
    input  wire [7:0]  sh_din,
    output wire        sh_we,

    // program SRAM download (CPU must be in reset while dl_wr pulses)
    input  wire        dl_wr,
    input  wire [14:0] dl_addr,
    input  wire [7:0]  dl_data
);

    // 32KB battery-backed SRAM: code + data. Port A = code fetch,
    // port B = MOVX data / download.
    reg [7:0] sram [0:32767];
    reg [7:0] code_q, data_q;

    wire [15:0] rom_addr;
    wire [16:0] xd_addr;     // MAME-style: bit16 = internal SRAM as data
    wire [7:0]  xd_dout;
    wire        xd_we, xd_rd;

    wire        xd_is_sram = xd_addr[16];
    wire        sram_we    = dl_wr || (xd_we && xd_is_sram);
    wire [14:0] sram_waddr = dl_wr ? dl_addr : xd_addr[14:0];
    wire [7:0]  sram_wdata = dl_wr ? dl_data : xd_dout;

    always @(posedge clk) begin
        if (sram_we) sram[sram_waddr] <= sram_wdata;
        code_q <= sram[rom_addr[14:0]];
        data_q <= sram[xd_addr[14:0]];
    end

    // expanded bus -> 68000 shared RAM (16KB mirrored)
    assign sh_addr = xd_addr[13:0];
    assign sh_dout = xd_dout;
    assign sh_we   = xd_we && !xd_is_sram;

    // registered reads: select with the space of the issued read
    reg xd_was_sram;
    always @(posedge clk) if (xd_rd) xd_was_sram <= xd_is_sram;

    wire [7:0] xd_din = xd_was_sram ? data_q : sh_din;

    mcs51_core u_mcu(
        .clk      (clk),
        .cen      (cen12),
        .rst      (rst),

        .rom_addr (rom_addr),
        .rom_data (code_q),

        .xd_addr  (xd_addr),
        .xd_dout  (xd_dout),
        .xd_din   (xd_din),
        .xd_we    (xd_we),
        .xd_rd    (xd_rd)
    );

    wire unused = &{1'b0, xd_rd, rom_addr[15], 1'b0};

endmodule

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Dani Sandoval
//
// World Rally system top (Gaelco REF.930217)
// 68000 @ 12 MHz + DS5002FP @ 12 MHz + OKI MSM6295 @ 1 MHz + Gaelco video.
// clk is the system clock (96 MHz assumed for the clock-enable ratios here).
//
// External ROM ports go to SDRAM (see mister/ level):
//   cpu_rom : 512K x 16  (68000 program)
//   gfx_rom : 1M   x 16  (tiles + sprites)
//   oki_rom : 1M   x 8   (ADPCM, banked)

module wrally_top(
    input  wire        clk,
    input  wire        rst,

    // clock enables, all derived from clk
    input  wire        cen12,        // 12 MHz   (68000, DS5002FP)
    input  wire        cen12b,       // 12 MHz, opposite phase (fx68k phi2)
    input  wire        cen6,         // 6 MHz    (pixel)
    input  wire        cen1,         // 1 MHz    (OKI)

    // control
    input  wire        service,      // SYSTEM bit 0 (active low)
    input  wire        test,         // SYSTEM bit 1 (active low)
    input  wire [15:0] dipsw,        // 0x700000 (SW2 low byte, SW1 high)
    input  wire [15:0] p1_p2,        // 0x700002, assembled by platform top
    input  wire [7:0]  wheel,        // optical wheel counter (0x700004 b15:8)
    input  wire [7:0]  analog0,      // pot wheel P1
    input  wire [7:0]  analog1,     // pot wheel P2

    // 68000 program ROM
    output wire [18:0] cpu_rom_addr, // word address
    input  wire [15:0] cpu_rom_data,
    output wire        cpu_rom_cs,
    input  wire        cpu_rom_ok,

    // GFX ROM
    output wire [19:0] gfx_rom_addr, // word address
    input  wire [15:0] gfx_rom_data,
    output wire        gfx_rom_rd,
    input  wire        gfx_rom_ok,

    // OKI ROM (byte-wide, post-banking 1MB space)
    output wire [19:0] oki_rom_addr,
    input  wire [7:0]  oki_rom_data,
    output wire        oki_rom_rd,
    input  wire        oki_rom_ok,

    // DS5002FP program SRAM download (32KB at ioctl offset 0x400000)
    input  wire        dl_wr,
    input  wire [14:0] dl_addr,
    input  wire [7:0]  dl_data,

    // video out
    output wire [3:0]  red, green, blue,
    output wire        hblank, vblank, hsync, vsync,

    // sound out
    output wire signed [15:0] snd,

    output wire [1:0]  coin_lockout,
    output wire [1:0]  coin_counter,
    input  wire        flip_dip_unused
);

    // ------------------------------------------------------------ 68000 bus
    wire [23:1] eab;
    wire [15:0] cpu_dout;
    reg  [15:0] cpu_din;
    wire        ASn, UDSn, LDSn, RWn;
    wire        FC0, FC1, FC2;
    reg         DTACKn;
    wire        VPAn;
    reg         irq6;

    wire bus_rd = !ASn &&  RWn;
    wire bus_wr = !ASn && !RWn && (!UDSn || !LDSn);
    wire iack   = FC0 && FC1 && FC2 && !ASn;

    fx68k u_cpu(
        .clk     (clk),
        .HALTn   (1'b1),
        .extReset(rst),
        .pwrUp   (rst),
        .enPhi1  (cen12),
        .enPhi2  (cen12b),

        .eRWn    (RWn),
        .ASn     (ASn),
        .LDSn    (LDSn),
        .UDSn    (UDSn),
        .E       (),
        .VMAn    (),
        .FC0     (FC0), .FC1(FC1), .FC2(FC2),
        .BGn     (),
        .oRESETn (),
        .oHALTEDn(),

        .DTACKn  (DTACKn),
        .VPAn    (VPAn),
        .BERRn   (1'b1),
        .BRn     (1'b1),
        .BGACKn  (1'b1),
        .IPL0n   (irq6 ? 1'b1 : 1'b1),   // level 6 = ~110
        .IPL1n   (irq6 ? 1'b0 : 1'b1),
        .IPL2n   (irq6 ? 1'b0 : 1'b1),

        .iEdb    (cpu_din),
        .oEdb    (cpu_dout),
        .eab     (eab)
    );

    assign VPAn = !iack;     // autovector all interrupts

    // address decode (eab = word address A23..A1)
    wire sel_rom    = !ASn && (eab[23:20] == 4'h0);
    wire sel_vram   = !ASn && (eab[23:16] == 8'h10) && !eab[15];        // 0x100000
    wire sel_vregs  = !ASn && (eab[23:16] == 8'h10) &&  eab[15] && !eab[3]; // 0x108000-7
    wire sel_clrint = !ASn && (eab[23:16] == 8'h10) &&  eab[15] &&  eab[3]; // 0x10800c
    wire sel_pal    = !ASn && (eab[23:16] == 8'h20);                    // 0x200000
    wire sel_spr    = !ASn && (eab[23:12] == 12'h440);                  // 0x440000
    wire sel_io     = !ASn && (eab[23:16] == 8'h70);                    // 0x700000
    wire sel_share  = !ASn && (eab[23:14] == {8'hFE, 2'b11});           // 0xFEC000

    // DTACK: ROM waits for SDRAM, everything else is immediate
    always @(posedge clk) begin
        if (rst) DTACKn <= 1'b1;
        else     DTACKn <= !( (sel_rom && cpu_rom_ok) ||
                              sel_vram || sel_vregs || sel_clrint ||
                              sel_pal || sel_spr || sel_io || sel_share ||
                              iack );
    end

    assign cpu_rom_addr = eab[19:1];
    assign cpu_rom_cs   = sel_rom && RWn;

    // ------------------------------------------------------- video interrupt
    wire vint;
    always @(posedge clk) begin
        if (rst)                                   irq6 <= 1'b0;
        else if (vint)                             irq6 <= 1'b1;
        else if (iack || (sel_clrint && !RWn))     irq6 <= 1'b0;
    end

    // ----------------------------------------------------------- VRAM (16KB)
    // CPU writes pass through the Gaelco encryption device. Pairing rule (MAME
    // gaelcrpt.cpp gaelco_decrypt): a write is the "2nd half" iff it has the same
    // PC and offset == prev_offset+1; AND m_lastpc is reset to 0 after every 2nd
    // half, so writes pair strictly in TWOS — (w0,w1),(w2,w3),... — they do NOT
    // chain (w2 decrypts with 0-context, NOT with w1). For long-aligned move.l /
    // movem.l (always even word offset) that is exactly the (even=1st, odd=2nd)
    // pairing => the !last_waddr[0] path is the MAME-correct one (a "chained"
    // variant that pairs every consecutive word over-chains and is WRONG).
    // last_was_vramw is cleared by any non-VRAM bus cycle
    // (an instruction fetch between two separate instrs), a good proxy for the
    // "same instruction" the two word-writes of one move.l/movem share.
    wire [15:0] vram_dec;
    reg  [12:0] last_waddr;
    reg         last_was_vramw;
    wire        vram_we = sel_vram && !RWn && !DTACKn;   // one pulse per cycle
    reg         vram_we_d;
    wire        vram_we_pulse = vram_we && !vram_we_d;

    wire second_half = last_was_vramw && (eab[13:1] == last_waddr + 13'd1)
                       && !last_waddr[0];

    always @(posedge clk) begin
        vram_we_d <= vram_we;
        if (rst) begin
            last_was_vramw <= 1'b0;
        end else if (vram_we_pulse) begin
            last_was_vramw <= 1'b1;
            last_waddr     <= eab[13:1];
        end else if (!ASn && !DTACKn && !sel_vram) begin
            last_was_vramw <= 1'b0;   // any other bus cycle breaks the pair
        end
    end

    gaelco_crypt u_crypt(
        .clk        (clk),
        .rst        (rst),
        .wr         (vram_we_pulse),
        .second_half(second_half),
        .enc_data   (cpu_dout),
        .dec_data   (vram_dec)
    );

    // VRAM: 8K x 16 dual port (CPU rw / video r)
    reg [15:0] vram [0:8191];
    reg [15:0] vram_q, vram_vq;
    wire [12:0] vvram_addr;
    always @(posedge clk) begin
        if (vram_we_pulse) vram[eab[13:1]] <= vram_dec;
        vram_q  <= vram[eab[13:1]];
        vram_vq <= vram[vvram_addr];
    end

    // --------------------------------------------------------- video registers
    reg [15:0] vregs[0:3];
    always @(posedge clk) if (sel_vregs && !RWn && !DTACKn)
        vregs[eab[2:1]] <= cpu_dout;

    // ----------------------------------------------------------- palette (16KB)
    // Two 8-bit byte lanes (hi/lo) so each is a plain full-width-write RAM
    // (no byte enables -> infers as M10K exactly like VRAM). Port A = CPU
    // R/W of that byte, port B = video read.
    wire [15:0] pal_q, pal_vq;
    wire [12:0] vpal_addr;
    wire        pal_we = sel_pal && !RWn && !DTACKn;
    dpram_be #(.AW(13), .DW(8)) u_palram_hi(
        .clk(clk),
        .a_addr(eab[13:1]), .a_data(cpu_dout[15:8]), .a_be(1'b1),
        .a_wr(pal_we && !UDSn), .a_q(pal_q[15:8]),
        .b_addr(vpal_addr), .b_data(8'd0), .b_be(1'b1), .b_wr(1'b0), .b_q(pal_vq[15:8])
    );
    dpram_be #(.AW(13), .DW(8)) u_palram_lo(
        .clk(clk),
        .a_addr(eab[13:1]), .a_data(cpu_dout[7:0]), .a_be(1'b1),
        .a_wr(pal_we && !LDSn), .a_q(pal_q[7:0]),
        .b_addr(vpal_addr), .b_data(8'd0), .b_be(1'b1), .b_wr(1'b0), .b_q(pal_vq[7:0])
    );

    // --------------------------------------------------------- sprite RAM (4KB)
    // Two 8-bit byte lanes (hi/lo), plain full-width-write RAMs (no byte
    // enables) so they infer as M10K. Port A = CPU R/W, port B = video read.
    wire [15:0] spr_q, spr_vq;
    wire [10:0] vspr_addr;
    wire        spr_we = sel_spr && !RWn && !DTACKn;
    dpram_be #(.AW(11), .DW(8)) u_sprram_hi(
        .clk(clk),
        .a_addr(eab[11:1]), .a_data(cpu_dout[15:8]), .a_be(1'b1),
        .a_wr(spr_we && !UDSn), .a_q(spr_q[15:8]),
        .b_addr(vspr_addr), .b_data(8'd0), .b_be(1'b1), .b_wr(1'b0), .b_q(spr_vq[15:8])
    );
    dpram_be #(.AW(11), .DW(8)) u_sprram_lo(
        .clk(clk),
        .a_addr(eab[11:1]), .a_data(cpu_dout[7:0]), .a_be(1'b1),
        .a_wr(spr_we && !LDSn), .a_q(spr_q[7:0]),
        .b_addr(vspr_addr), .b_data(8'd0), .b_be(1'b1), .b_wr(1'b0), .b_q(spr_vq[7:0])
    );

    // -------------------------------------------- shared RAM (16KB, 68k + MCU)
    // Two 8-bit byte lanes, each a true dual-port block RAM (dpram_be):
    //   port A = 68000 (16-bit word, UDS=hi lane, LDS=lo lane)
    //   port B = DS5002FP MCU (8-bit, lane chosen by address bit 0)
    wire      share_we = sel_share && !RWn && !DTACKn;

    // MCU byte port (wired to ds5002fp_glue below)
    wire [13:0] mcu_sh_addr;
    wire [7:0]  mcu_sh_dout;
    wire        mcu_sh_we;

    wire [7:0]  share_hi_q, share_lo_q;     // 68k read (hi/lo byte)
    wire [7:0]  share_hi_mq, share_lo_mq;   // MCU read (hi/lo byte)
    wire [7:0]  mcu_sh_q = mcu_sh_addr[0] ? share_lo_mq : share_hi_mq;

    // Both ports write (68k + MCU) -> true-dual-port template (tdp_ram).
    tdp_ram #(.AW(13), .DW(8)) u_share_hi(
        .clk(clk),
        .a_addr(eab[13:1]),          .a_data(cpu_dout[15:8]),
        .a_wr(share_we && !UDSn),    .a_q(share_hi_q),
        .b_addr(mcu_sh_addr[13:1]),  .b_data(mcu_sh_dout),
        .b_wr(mcu_sh_we && !mcu_sh_addr[0]), .b_q(share_hi_mq)
    );
    tdp_ram #(.AW(13), .DW(8)) u_share_lo(
        .clk(clk),
        .a_addr(eab[13:1]),          .a_data(cpu_dout[7:0]),
        .a_wr(share_we && !LDSn),    .a_q(share_lo_q),
        .b_addr(mcu_sh_addr[13:1]),  .b_data(mcu_sh_dout),
        .b_wr(mcu_sh_we && mcu_sh_addr[0]),  .b_q(share_lo_mq)
    );

    // ------------------------------------------------------------ DS5002FP
    ds5002fp_glue u_mcu(
        .clk        (clk),
        .rst        (rst),
        .cen12      (cen12),
        .sh_addr    (mcu_sh_addr),
        .sh_dout    (mcu_sh_dout),
        .sh_din     (mcu_sh_q),
        .sh_we      (mcu_sh_we),
        .dl_wr      (dl_wr),
        .dl_addr    (dl_addr),
        .dl_data    (dl_data)
    );

    // ------------------------------------------------------------------- I/O
    // 74LS259 output latch (0x70000B + addr[6:4])
    reg [7:0] latch259;
    wire sel_lat = sel_io && !RWn && !LDSn && (eab[3:1] == 3'd5);
    always @(posedge clk) begin
        if (rst) latch259 <= 8'd0;
        else if (sel_lat && !DTACKn)
            latch259[eab[6:4]] <= cpu_dout[0];
    end

    assign coin_lockout = ~latch259[1:0];
    assign coin_counter =  latch259[3:2];
    wire   mute         =  latch259[4];
    wire   flip         =  latch259[5];
    wire   adc_en       =  latch259[6];
    wire   adc_clk      =  latch259[7];

    // pot wheel serial ADC (MAME wrally.cpp adc_en/adc_clk)
    reg [7:0] adc_shift0, adc_shift1;
    reg       adc_clk_d;
    always @(posedge clk) begin
        adc_clk_d <= adc_clk;
        if (!adc_en) begin
            adc_shift0 <= analog0;
            adc_shift1 <= analog1;
        end else if (adc_clk_d && !adc_clk) begin   // falling edge
            adc_shift0 <= {adc_shift0[6:0], 1'b0};
            adc_shift1 <= {adc_shift1[6:0], 1'b0};
        end
    end

    // OKI bank register (0x70000D)
    reg [3:0] okibank;
    always @(posedge clk) begin
        if (rst) okibank <= 4'd0;
        else if (sel_io && !RWn && !LDSn && (eab[3:1] == 3'd6) && !DTACKn)
            okibank <= cpu_dout[3:0];
    end

    // ------------------------------------------------------------------ OKI
    wire [7:0]  oki_dout;
    wire [17:0] oki_addr;        // 256KB internal space
    wire signed [13:0] oki_snd;
    wire oki_sel = sel_io && (eab[3:1] == 3'd7);    // 0x70000E/F
    wire oki_wrn = !(oki_sel && !RWn && !LDSn && !DTACKn);

    // INTERPOL=0 keeps jt6295 self-contained; =1 needs jtframe_fir_mono
    // from the jtframe repo (nicer output filtering, add later)
    jt6295 #(.INTERPOL(0)) u_oki(
        .rst    (rst),
        .clk    (clk),
        .cen    (cen1),
        .ss     (1'b1),              // pin 7 high
        .wrn    (oki_wrn),
        .din    (cpu_dout[7:0]),
        .dout   (oki_dout),
        .rom_addr(oki_addr),
        .rom_data(oki_rom_data),
        .rom_ok (oki_rom_ok),
        .sound  (oki_snd),
        .sample ()
    );

    // banking: 0x00000-0x2FFFF fixed, 0x30000-0x3FFFF = bank (PAL16R4 @ E2)
    assign oki_rom_addr = (oki_addr < 18'h30000)
                        ? {2'd0, oki_addr}
                        : {okibank, oki_addr[15:0]};
    assign oki_rom_rd   = 1'b1;

    assign snd = mute ? 16'd0 : {oki_snd, 2'b00};

    // -------------------------------------------------------------- CPU din
    always @* begin
        cpu_din = 16'hFFFF;
        if      (sel_rom)   cpu_din = cpu_rom_data;
        else if (sel_vram)  cpu_din = vram_q;
        else if (sel_vregs) cpu_din = vregs[eab[2:1]];
        else if (sel_pal)   cpu_din = pal_q;
        else if (sel_spr)   cpu_din = spr_q;
        else if (sel_share) cpu_din = {share_hi_q, share_lo_q};
        else if (sel_io) case (eab[3:1])
            3'd0: cpu_din = dipsw;
            3'd1: cpu_din = p1_p2;
            3'd2: cpu_din = {wheel, 8'hFF};
            3'd4: cpu_din = {12'hFFF, adc_shift1[7], adc_shift0[7], test, service};
            3'd7: cpu_din = {8'hFF, oki_dout};
            default: cpu_din = 16'hFFFF;
        endcase
    end

    // ------------------------------------------------------------------ video
    wrally_video u_video(
        .clk       (clk),
        .rst       (rst),
        .cen_pix   (cen6),
        .flip      (flip),
        .vregs0    (vregs[0]),
        .vregs1    (vregs[1]),
        .vregs2    (vregs[2]),
        .vregs3    (vregs[3]),
        .vram_addr (vvram_addr),
        .vram_data (vram_vq),
        .pal_addr  (vpal_addr),
        .pal_data  (pal_vq),
        .spram_addr(vspr_addr),
        .spram_data(spr_vq),
        .gfx_addr  (gfx_rom_addr),
        .gfx_rd    (gfx_rom_rd),
        .gfx_data  (gfx_rom_data),
        .gfx_ok    (gfx_rom_ok),
        .red       (red),
        .green     (green),
        .blue      (blue),
        .hblank    (hblank),
        .vblank    (vblank),
        .hsync     (hsync),
        .vsync     (vsync),
        .vint      (vint)
    );

endmodule

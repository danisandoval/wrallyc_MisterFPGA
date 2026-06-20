//============================================================================
//  World Rally (Gaelco) for MiSTer - platform top level
//  Port list via the canonical sys/emu_ports.vh include so it always matches
//  the framework (hand-written port lists drift across template versions).
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

    // Ports not used by this core
    assign ADC_BUS  = 'Z;
    assign USER_OUT = '1;
    assign {UART_RTS, UART_TXD, UART_DTR} = 0;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
    assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;
    // VGA_SL, CLK_VIDEO, CE_PIXEL, VGA_R/G/B/HS/VS/DE driven by arcade_video below

    assign VGA_F1 = 0;
    assign VGA_SCALER = 0;
    assign VGA_DISABLE = 0;
    assign HDMI_FREEZE = 0;
    assign HDMI_BLACKOUT = 0;
    assign HDMI_BOB_DEINT = 0;
    assign AUDIO_S = 1;
    assign AUDIO_MIX = 0;
    assign LED_USER = ioctl_download;
    assign LED_POWER = 0;
    assign LED_DISK = 0;
    assign BUTTONS = 0;

    assign VIDEO_ARX = 12'd4;
    assign VIDEO_ARY = 12'd3;

    //////////////////////////////////   CONF   ///////////////////////////
    `include "build_id.v"
    localparam CONF_STR = {
        "WorldRally;;",
        "-;",
        "H0O[2],Aspect Ratio,Original,Full Screen;",
        "O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
        "-;",
        "DIP;",
        "-;",
        "R[0],Reset;",
        "J1,Accelerate,Gear Shift,Start,Coin;",
        "V,v",`BUILD_DATE
    };

    ////////////////////////////////   CLOCKS   ///////////////////////////
    wire clk_sys;          // 96 MHz
    wire pll_locked;

    pll pll(
        .refclk   (CLK_50M),
        .rst      (0),
        .outclk_0 (clk_sys),
        .outclk_1 (SDRAM_CLK),   // 96 MHz, phase shifted (-90 deg)
        .locked   (pll_locked)
    );

    // clock enables
    reg [3:0] cencnt = 0;
    reg       cen12, cen12b, cen6;
    reg [6:0] cen1cnt = 0;
    reg       cen1;
    always @(posedge clk_sys) begin
        cencnt <= cencnt + 1'd1;
        cen12  <= cencnt[2:0] == 3'd0;            // 96/8
        cen12b <= cencnt[2:0] == 3'd4;            // opposite phase
        cen6   <= cencnt == 4'd0;                 // 96/16
        cen1cnt <= (cen1cnt == 7'd95) ? 7'd0 : cen1cnt + 7'd1;
        cen1   <= cen1cnt == 7'd0;                // 96/96
    end

    wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked;

    ///////////////////////////////   HPS IO   ////////////////////////////
    wire [127:0] status;
    wire  [1:0]  buttons;
    wire [31:0]  joystick_0, joystick_1;
    wire         ioctl_download;
    wire         ioctl_wait;
    wire  [7:0]  ioctl_index;
    wire         ioctl_wr;
    wire [26:0]  ioctl_addr;
    wire  [7:0]  ioctl_dout;
    wire         forced_scandoubler;
    wire [21:0]  gamma_bus;
    wire         direct_video;

    hps_io #(.CONF_STR(CONF_STR)) hps_io
    (
        .clk_sys(clk_sys),
        .HPS_BUS(HPS_BUS),

        .buttons(buttons),
        .status(status),
        .status_menumask(direct_video),
        .forced_scandoubler(forced_scandoubler),
        .gamma_bus(gamma_bus),
        .direct_video(direct_video),

        .ioctl_download(ioctl_download),
        .ioctl_index(ioctl_index),
        .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),
        .ioctl_wait(ioctl_wait),

        .joystick_0(joystick_0),
        .joystick_1(joystick_1)
    );

    //////////////////////////////  DOWNLOAD  /////////////////////////////
    // .rom layout: 0x000000 68k, 0x100000 gfx, 0x300000 oki, 0x400000 DS5002
    wire is_rom_dl = ioctl_download && (ioctl_index == 0);
    wire is_dip    = ioctl_download && (ioctl_index == 8'd254);

    // byte stream -> word writes for SDRAM regions
    reg  [7:0]  dl_lsb;
    reg         dl_word_wr;
    reg  [23:0] dl_word_addr;
    reg  [15:0] dl_word_data;
    wire        dl_sdram = is_rom_dl && (ioctl_addr < 27'h400000);
    wire        dl_dssram = is_rom_dl && (ioctl_addr >= 27'h400000)
                                      && (ioctl_addr < 27'h408000);

    always @(posedge clk_sys) begin
        if (dl_sdram && ioctl_wr) begin
            if (!ioctl_addr[0]) dl_lsb <= ioctl_dout;
            else begin
                dl_word_wr   <= 1'b1;
                dl_word_addr <= ioctl_addr[24:1];
                // Region-dependent byte packing (verified vs sim hex):
                //   68k program  (<0x100000): big-endian {even=D15:8, odd=D7:0}
                //   GFX + OKI   (>=0x100000): {odd=D15:8, even=D7:0}
                dl_word_data <= (ioctl_addr < 27'h100000) ? {dl_lsb, ioctl_dout}
                                                          : {ioctl_dout, dl_lsb};
            end
        end
        if (dl_ack) dl_word_wr <= 1'b0;
    end
    // Throttle the HPS download: assert ioctl_wait while an SDRAM word write is
    // pending (each takes ~8-11 clk_sys cycles). Without this the HPS streams
    // faster than the controller can write and most ROM data is lost.
    assign ioctl_wait = dl_word_wr | (dl_sdram && ioctl_wr && ioctl_addr[0]);

    // DIP switches from MRA (index 254): 2 bytes, SW2 low / SW1 high
    reg [15:0] dipsw = 16'hFFDF;
    always @(posedge clk_sys) if (is_dip && ioctl_wr && ioctl_addr < 2)
        dipsw[{ioctl_addr[0], 3'd0} +: 8] <= ioctl_dout;

    //////////////////////////////   SDRAM   //////////////////////////////
    wire        dl_ack;
    wire [18:0] cpu_rom_addr;
    wire [15:0] cpu_rom_data;
    wire        cpu_rom_cs, cpu_rom_ok;
    wire [19:0] gfx_rom_addr;
    wire [15:0] gfx_rom_data;
    wire        gfx_rom_rd, gfx_rom_ok;
    wire [19:0] oki_rom_addr;
    wire [15:0] oki_word;
    wire        oki_rom_rd, oki_rom_ok;

    // SDRAM read-data capture point: bstate7 (+1 clk, lands in the data eye on
    // real HW). bstate6 (JEDEC CL2 min) captured too early and stripped the gfx;
    // bstate7 is HW-confirmed, so it's hardwired. Pure clk-posedge, no CDC.
    wire cap_late = 1'b1;

    sdram_rom sdram_rom(
        .clk      (clk_sys),
        .init     (~pll_locked),
        .cap_late (cap_late),

        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQM({SDRAM_DQMH, SDRAM_DQML}),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_CKE(SDRAM_CKE),

        .dl_wr   (dl_word_wr),
        .dl_addr (dl_word_addr),
        .dl_data (dl_word_data),
        .dl_ack  (dl_ack),

        .cpu_rd  (cpu_rom_cs),
        .cpu_addr({5'd0, cpu_rom_addr}),            // 0x000000 words
        .cpu_dout(cpu_rom_data),
        .cpu_ok  (cpu_rom_ok),

        .gfx_rd  (gfx_rom_rd),
        .gfx_addr({4'd0, gfx_rom_addr} + 24'h080000), // 0x100000 bytes
        .gfx_dout(gfx_rom_data),
        .gfx_ok  (gfx_rom_ok),

        .oki_rd  (oki_rom_rd),
        .oki_addr({5'd0, oki_rom_addr[19:1]} + 24'h180000), // 0x300000 bytes
        .oki_dout(oki_word),
        .oki_ok  (oki_rom_ok)
    );

    // OKI words packed {odd=D15:8, even=D7:0}: even byte = low, odd = high
    wire [7:0] oki_rom_data = oki_rom_addr[0] ? oki_word[15:8] : oki_word[7:0];

    //////////////////////////////   INPUTS   /////////////////////////////
    // joystick bits: 0 R, 1 L, 2 D, 3 U, 4 Accelerate, 5 Gear, 6 Start, 7 Coin
    reg gear1, gear2;
    reg [1:0] gear_d;
    always @(posedge clk_sys) begin
        gear_d <= {joystick_1[5], joystick_0[5]};
        if (joystick_0[5] && !gear_d[0]) gear1 <= ~gear1;
        if (joystick_1[5] && !gear_d[1]) gear2 <= ~gear2;
    end

    wire [15:0] p1_p2 = {
        ~joystick_1[6],          // start2
        ~joystick_0[6],          // start1
        ~joystick_1[4],          // P2 button1 (accelerate)
        ~gear2,                  // P2 gear
        ~joystick_1[1], ~joystick_1[0], ~joystick_1[2], ~joystick_1[3],
        ~joystick_1[7],          // coin2
        ~joystick_0[7],          // coin1
        ~joystick_0[4],          // P1 button1 (accelerate)
        gear1,                   // P1 gear (active high toggle)
        ~joystick_0[1], ~joystick_0[0], ~joystick_0[2], ~joystick_0[3]
    };

    //////////////////////////////   CORE   ///////////////////////////////
    wire [3:0] r4, g4, b4;
    wire hblank, vblank, hsync, vsync;
    wire signed [15:0] snd;

    wrally_top core(
        .clk      (clk_sys),
        .rst      (reset),
        .cen12    (cen12),
        .cen12b   (cen12b),
        .cen6     (cen6),
        .cen1     (cen1),

        .service  (1'b1),
        .test     (1'b1),
        .dipsw    (dipsw),
        .p1_p2    (p1_p2),
        .wheel    (8'hFF),       // TODO: optical wheel emulation
        .analog0  (8'h8A),
        .analog1  (8'h8A),

        .cpu_rom_addr(cpu_rom_addr),
        .cpu_rom_data(cpu_rom_data),
        .cpu_rom_cs  (cpu_rom_cs),
        .cpu_rom_ok  (cpu_rom_ok),

        .gfx_rom_addr(gfx_rom_addr),
        .gfx_rom_data(gfx_rom_data),
        .gfx_rom_rd  (gfx_rom_rd),
        .gfx_rom_ok  (gfx_rom_ok),

        .oki_rom_addr(oki_rom_addr),
        .oki_rom_data(oki_rom_data),
        .oki_rom_rd  (oki_rom_rd),
        .oki_rom_ok  (oki_rom_ok),

        .dl_wr   (is_rom_dl && ioctl_wr && dl_dssram),
        .dl_addr (ioctl_addr[14:0]),
        .dl_data (ioctl_dout),

        .red(r4), .green(g4), .blue(b4),
        .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),

        .snd(snd),
        .coin_lockout(), .coin_counter(),
        .flip_dip_unused(1'b0)
    );

    assign AUDIO_L = snd;
    assign AUDIO_R = snd;

    //////////////////////////////   VIDEO   //////////////////////////////
    // CLK_VIDEO is driven by arcade_video (from .clk_video(clk_sys))
    reg cen6_q;
    always @(posedge clk_sys) cen6_q <= cen6;

    arcade_video #(.WIDTH(368), .DW(12)) arcade_video
    (
        .*,
        .clk_video(clk_sys),
        .ce_pix(cen6_q),
        .RGB_in({r4, g4, b4}),
        .HBlank(hblank),
        .VBlank(vblank),
        .HSync(hsync),
        .VSync(vsync),
        .fx(status[5:3])
    );

endmodule

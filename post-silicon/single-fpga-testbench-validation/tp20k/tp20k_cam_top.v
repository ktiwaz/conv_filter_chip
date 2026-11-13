// Tang Primer 20K camera pipeline: OV3660 (DVP, RGB565 384x384) ->
//   preview_wr -> DDR3 -> preview_rd: colour preview, 576x576 on 720p HDMI;
//   rgb_grab (3x3 average -> 128x128 R, G, B, Y) -> DDR3 -> plane_dma -> DUT
//   run per channel (color_live, fpga_tb_core LIVE_EXT) -> color_frame:
//   the 128x128 output, colour or gray per preset (cam_compositor).
// The UART tester (scripts/tb_host.py) works on this bitstream too.
//
// Clocks: 27 MHz -> rPLL -> 371.25 MHz HDMI serial -> CLKDIV /5 -> 74.25 MHz
//         pixel; the same PLL's CLKOUTD (/8) -> 46.41 MHz fabric (XCLK =
//         23.2 MHz from it); the camera side runs on its PCLK; a second
//         rPLL makes the 94.5 MHz DDR3 clock.
//
// Standalone: after reset, sccb_init powers the camera up and writes the
// register list from cam_init_rom (cam/*.txt), then live mode turns on by
// itself, so no PC is needed (bitstream in flash: make flash-cam).
//
// Camera control from the PC through dbg_bridge GPIO (address 0xF000_0000,
// scripts/cam_host.py). Reset value 0 = automatic init and live mode.
//   GPIO out  bit0 PWDN (1 = power down)    bit1 RESET release (1 = run)
//             bit2 SCL low (open drain)     bit3 SDA low (open drain)
//             bits 0-3 apply only with bit6 MANUAL set (else sccb_init drives them)
//             bit4 invert HREF              bit5 live mode on (like PYNQ sw[1])
//             bit6 MANUAL camera pins       bit7 no automatic live mode after init
//             bit8 freeze the preview writer (read a frame from DDR3)
//             bits 10:9 DUT output: 00 per preset, 01 gray (luma), 10 colour
//   GPIO in   bit0 SCL  bit1 SDA  bit2 VSYNC  bit3 HREF  bit4 a preview frame exists
//             bit5 the output shown is colour  bit6 the bridge window abandoned a request
//             [11:8] filter preset  bit12 DDR3 calibrated  bit13 DDR3 calibration failed
//             [15:14] newest preview bank  [27:16] GPIO out[11:0] read back
//             bit31 init done  [30:28] init NACKs (7 = 7 or more)
// DDR3 (128 MB) is readable and writable over the bridge at 0x1000_0000.
// Frame size / rate / runs: fpga_tb_core's RX_SIZE, RX_FRAMES, LIVE_RUNS.
//
// Buttons (active low): S0 reset, S1 / S2 next / previous filter preset.
// LEDs (active low): led0 heartbeat, led1 live, led5..led2 filter preset.
module tp20k_cam_top #(
    parameter CLK_HZ    = 46_406_250,
    parameter BAUD      = 1_000_000,
    parameter INIT_FILE = "../input_image_w32.hex",   // relative to tp20k/
    // 1: LEDs show clock bring-up state instead (see the LED section)
    parameter DEBUG_LEDS = 0
) (
    input  wire       clk27,
    input  wire       rst_n,
    input  wire       btn_next_n,
    input  wire       btn_prev_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led_n,

    inout  wire       cmos_scl,
    inout  wire       cmos_sda,
    output wire       cmos_xclk,
    output wire       cmos_pwdn,
    output wire       cmos_rst_n,
    input  wire       cmos_pclk,
    input  wire       cmos_vsync,
    input  wire       cmos_href,
    input  wire [7:0] cmos_db,

    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,

    // DDR3 (core board, 1 Gbit x16)
    output wire        ddr_ck,
    output wire        ddr_ck_n,
    output wire        ddr_reset_n,
    output wire        ddr_cke,
    output wire        ddr_cs_n,
    output wire        ddr_ras_n,
    output wire        ddr_cas_n,
    output wire        ddr_we_n,
    output wire        ddr_odt,
    output wire [2:0]  ddr_ba,
    output wire [13:0] ddr_addr,
    output wire [1:0]  ddr_dm,
    inout  wire [1:0]  ddr_dqs,
    inout  wire [1:0]  ddr_dqs_n,
    inout  wire [15:0] ddr_dq
);

    //==================================================
    // Clocks and resets
    //==================================================
    // One PLL for everything: HDMI serial clock, and its /8 output for the
    // fabric (46.41 MHz; the UART divider and the fps counter take CLK_HZ)
    wire sclk, clk, pclk_v, locked;
    rPLL #(
        .FCLKIN("27.0"), .IDIV_SEL(3), .FBDIV_SEL(54), .ODIV_SEL(2),  // 371.25 MHz
        .DYN_SDIV_SEL(8), .CLKOUTD_SRC("CLKOUT")                       // /8: 46.41 MHz
    ) pll (
        .CLKIN(clk27), .CLKOUT(sclk), .CLKOUTD(clk), .LOCK(locked),
        .CLKOUTP(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    CLKDIV #(.DIV_MODE("5")) pdiv (
        .HCLKIN(sclk), .RESETN(locked), .CALIB(1'b0), .CLKOUT(pclk_v)
    );
    wire locked_v = locked;

    reg [3:0] rst_sync = 4'b0000;
    always @(posedge clk or negedge locked)
        if (!locked) rst_sync <= 4'b0000;
        else         rst_sync <= {rst_sync[2:0], rst_n};
    wire aresetn = rst_sync[3];

    // Pixel-clock reset (video_compositor / video_frame / TMDS): released
    // once the video PLL is locked
    reg [3:0] prst_sync = 4'hF;
    always @(posedge pclk_v or negedge locked_v)
        if (!locked_v) prst_sync <= 4'hF;
        else           prst_sync <= {prst_sync[2:0], 1'b0};
    wire prst = prst_sync[3];

    //==================================================
    // UART -> AXI (dbg_bridge), GPIO for the camera
    //==================================================
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire [7:0]  awlen, arlen;
    wire [1:0]  awburst, arburst, bresp, rresp;
    wire [3:0]  wstrb;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rlast, rvalid, rready;
    wire        bid, rid;
    wire [31:0] gpio_out, gpio_in;

    // bridge side (b_*), split by address bit 28 between the tester core
    // (0x0xxx_xxxx, the plain wires above) and the DDR3 window (0x1xxx_xxxx, m_*)
    wire [31:0] b_awaddr, b_wdata, b_araddr, b_rdata, m_rdata;
    wire [7:0]  b_awlen, b_arlen;
    wire [1:0]  b_awburst, b_arburst, b_bresp, b_rresp, m_bresp, m_rresp;
    wire [3:0]  b_wstrb;
    wire        b_awvalid, b_awready, b_wlast, b_wvalid, b_wready, b_bvalid, b_bready;
    wire        b_arvalid, b_arready, b_rlast, b_rvalid, b_rready, b_bid, b_rid;
    wire        m_awready, m_wready, m_bvalid, m_arready, m_rvalid, m_rlast, m_bid, m_rid;

    dbg_bridge #(.CLK_FREQ(CLK_HZ), .UART_SPEED(BAUD)) bridge (
        .clk_i(clk), .rst_i(!aresetn),
        .uart_rxd_i(uart_rx), .uart_txd_o(uart_tx),
        .mem_awvalid_o(b_awvalid), .mem_awaddr_o(b_awaddr), .mem_awid_o(),
        .mem_awlen_o(b_awlen), .mem_awburst_o(b_awburst), .mem_awready_i(b_awready),
        .mem_wvalid_o(b_wvalid), .mem_wdata_o(b_wdata), .mem_wstrb_o(b_wstrb),
        .mem_wlast_o(b_wlast), .mem_wready_i(b_wready),
        .mem_bvalid_i(b_bvalid), .mem_bresp_i(b_bresp), .mem_bid_i({3'd0, b_bid}),
        .mem_bready_o(b_bready),
        .mem_arvalid_o(b_arvalid), .mem_araddr_o(b_araddr), .mem_arid_o(),
        .mem_arlen_o(b_arlen), .mem_arburst_o(b_arburst), .mem_arready_i(b_arready),
        .mem_rvalid_i(b_rvalid), .mem_rdata_i(b_rdata), .mem_rresp_i(b_rresp),
        .mem_rid_i({3'd0, b_rid}), .mem_rlast_i(b_rlast), .mem_rready_o(b_rready),
        .gpio_inputs_i(gpio_in), .gpio_outputs_o(gpio_out)
    );

    // Address split on AW / AR only. W, B and R need no routing: only the
    // slave that accepted the address is in its data / response phase (the
    // bridge has one transaction in flight), the other never raises ready or
    // valid, so those signals go to both and the responses are ORed / muxed.
    wire aw_ddr = b_awaddr[28], ar_ddr = b_araddr[28];

    assign awvalid = b_awvalid && !aw_ddr;
    assign awaddr = b_awaddr;  assign awlen = b_awlen;  assign awburst = b_awburst;
    assign wvalid = b_wvalid;
    assign wdata = b_wdata;  assign wstrb = b_wstrb;  assign wlast = b_wlast;
    assign bready = b_bready;
    assign arvalid = b_arvalid && !ar_ddr;
    assign araddr = b_araddr;  assign arlen = b_arlen;  assign arburst = b_arburst;
    assign rready = b_rready;

    assign b_awready = aw_ddr ? m_awready : awready;
    assign b_wready  = m_wready || wready;
    assign b_bvalid  = m_bvalid || bvalid;
    assign b_bresp   = m_bvalid ? m_bresp : bresp;
    assign b_bid     = m_bvalid ? m_bid   : bid;
    assign b_arready = ar_ddr ? m_arready : arready;
    assign b_rvalid  = m_rvalid || rvalid;
    assign b_rdata   = m_rvalid ? m_rdata : rdata;
    assign b_rresp   = m_rvalid ? m_rresp : rresp;
    assign b_rlast   = m_rvalid ? m_rlast : rlast;
    assign b_rid     = m_rvalid ? m_rid   : rid;

    //==================================================
    // DDR3: controller + PHY on their own PLL (dclk 94.5 MHz), arbiter,
    // AXI window for the bridge (port 0)
    //==================================================
    // 0 preview read, 1 preview write, 2 AXI window, 3 colour grabber, 4 plane DMA
    // (the window's traffic is tiny; the grabber has a FIFO, the DMA frame time)
    localparam NP = 5;
    wire         dclk, drst, d_calib_done, d_calib_fail;
    wire         c_rd, c_wr, c_refresh, c_busy, c_data_ready;
    wire [25:0]  c_addr;
    wire [127:0] c_din_burst, c_dout_burst, a_rdata;
    wire [15:0]  c_be_burst;
    wire [NP-1:0] a_req, a_we, a_gnt, a_rvalid;
    wire [NP*23-1:0]  a_baddr;
    wire [NP*128-1:0] a_wdata;
    wire [NP*16-1:0]  a_wbe;
    wire [31:0]  ddr_accesses;
    wire         win_timeout;           // bridge window gave up on a request (sticky)

    ddr3_sys ddr3 (
        .clk27(clk27), .dclk(dclk), .drst(drst),
        .calib_done(d_calib_done), .calib_fail(d_calib_fail),
        .rd(c_rd), .wr(c_wr), .refresh(c_refresh), .addr(c_addr),
        .din_burst(c_din_burst), .be_burst(c_be_burst), .dout_burst(c_dout_burst),
        .data_ready(c_data_ready), .busy(c_busy),
        .ddr_ck(ddr_ck), .ddr_ck_n(ddr_ck_n), .ddr_reset_n(ddr_reset_n), .ddr_cke(ddr_cke),
        .ddr_cs_n(ddr_cs_n), .ddr_ras_n(ddr_ras_n), .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n),
        .ddr_odt(ddr_odt), .ddr_ba(ddr_ba), .ddr_addr(ddr_addr), .ddr_dm(ddr_dm),
        .ddr_dqs(ddr_dqs), .ddr_dqs_n(ddr_dqs_n), .ddr_dq(ddr_dq)
    );

    // refresh every 7.8 us at 94.5 MHz
    ddr_arb #(.NP(NP), .BA_W(23), .REFRESH_CYC(737)) ddr_arb (
        .clk(dclk), .rst(drst), .ready(d_calib_done && !d_calib_fail),
        .req(a_req), .we(a_we), .baddr(a_baddr), .wdata(a_wdata), .wbe(a_wbe),
        .gnt(a_gnt), .rvalid(a_rvalid), .rdata(a_rdata),
        .c_rd(c_rd), .c_wr(c_wr), .c_refresh(c_refresh), .c_addr(c_addr),
        .c_din_burst(c_din_burst), .c_be_burst(c_be_burst),
        .c_busy(c_busy), .c_data_ready(c_data_ready), .c_dout_burst(c_dout_burst),
        .accesses(ddr_accesses)
    );

    axi_ddr #(.AW(27)) ddr_axi (
        .clk(clk), .aresetn(aresetn),
        .s_axi_awid(1'b0), .s_axi_awaddr(b_awaddr), .s_axi_awlen(b_awlen), .s_axi_awburst(b_awburst),
        .s_axi_awvalid(b_awvalid && aw_ddr), .s_axi_awready(m_awready),
        .s_axi_wdata(b_wdata), .s_axi_wstrb(b_wstrb), .s_axi_wlast(b_wlast),
        .s_axi_wvalid(b_wvalid), .s_axi_wready(m_wready),
        .s_axi_bid(m_bid), .s_axi_bresp(m_bresp), .s_axi_bvalid(m_bvalid),
        .s_axi_bready(b_bready),
        .s_axi_arid(1'b0), .s_axi_araddr(b_araddr), .s_axi_arlen(b_arlen), .s_axi_arburst(b_arburst),
        .s_axi_arvalid(b_arvalid && ar_ddr), .s_axi_arready(m_arready),
        .s_axi_rid(m_rid), .s_axi_rdata(m_rdata), .s_axi_rresp(m_rresp), .s_axi_rlast(m_rlast),
        .s_axi_rvalid(m_rvalid), .s_axi_rready(b_rready),
        .dclk(dclk), .drst(drst),
        .d_req(a_req[2]), .d_we(a_we[2]), .d_baddr(a_baddr[2*23 +: 23]),
        .d_wdata(a_wdata[2*128 +: 128]), .d_wbe(a_wbe[2*16 +: 16]),
        .d_gnt(a_gnt[2]), .d_rvalid(a_rvalid[2]), .d_rdata(a_rdata),
        .d_timeout(win_timeout)
    );

    // DDR3 status into the fabric clock (GPIO in [15:12])
    (* ASYNC_REG = "TRUE" *) reg [1:0] cal_ok_s = 2'b00, cal_fail_s = 2'b00;
    always @(posedge clk) begin
        cal_ok_s   <= {cal_ok_s[0], d_calib_done && !d_calib_fail};
        cal_fail_s <= {cal_fail_s[0], d_calib_fail};
    end

    wire manual      = gpio_out[6];
    wire href_inv    = gpio_out[4];

    //==================================================
    // Standalone camera init (sccb_init); the PC takes the pins with MANUAL
    //==================================================
    wire       init_pwdn, init_rst_n, init_scl_low, init_sda_low, init_done;
    wire [7:0] init_nacks;
    reg  [3:0] pins_m, pins_s;           // synchronized {HREF, VSYNC, SDA, SCL}

    sccb_init #(.CLK_HZ(CLK_HZ)) cam_init (
        .clk(clk), .rst(!aresetn),
        .pwdn(init_pwdn), .rst_n(init_rst_n),
        .scl_low(init_scl_low), .sda_low(init_sda_low), .sda_in(pins_s[1]),
        .done(init_done), .nacks(init_nacks)
    );

    wire cam_pwdn = manual ? gpio_out[0] : init_pwdn;
    wire cam_run  = manual ? gpio_out[1] : init_rst_n;
    wire scl_low  = manual ? gpio_out[2] : init_scl_low;
    wire sda_low  = manual ? gpio_out[3] : init_sda_low;
    wire live_sw  = gpio_out[5] || (init_done && !gpio_out[7]);

    //==================================================
    // Camera pins
    //==================================================
    reg xclk_q = 1'b0;
    always @(posedge clk) xclk_q <= ~xclk_q;           // 23.2 MHz
    assign cmos_xclk  = xclk_q;
    assign cmos_pwdn  = cam_pwdn;
    assign cmos_rst_n = cam_run;
    assign cmos_scl   = scl_low ? 1'b0 : 1'bz;
    assign cmos_sda   = sda_low ? 1'b0 : 1'bz;

    always @(posedge clk) begin
        pins_m <= {cmos_href, cmos_vsync, cmos_sda, cmos_scl};
        pins_s <= pins_m;
    end

    // DVP capture, registered on the camera's PCLK, then RGB565 byte pairs
    // -> pixels (pix565): a pixel every other PCLK while HREF is active
    reg [7:0] cam_y;
    reg       cam_de;
    always @(posedge cmos_pclk) begin
        cam_y  <= cmos_db;
        cam_de <= cmos_href ^ href_inv;
    end

    wire cam_on = cam_run && !cam_pwdn;
    wire frame_start;                   // display frame start (compositor)
    (* ASYNC_REG = "TRUE" *) reg [2:0] cam_rst_s = 3'b111;
    always @(posedge cmos_pclk or negedge cam_on)
        if (!cam_on) cam_rst_s <= 3'b111;
        else         cam_rst_s <= {cam_rst_s[1:0], 1'b0};
    wire cam_rst = cam_rst_s[2];

    wire        px_ce, px_de, px_sol, px_sof;
    wire [15:0] px565;
    wire [23:0] px_rbg;
    pix565 pix (
        .clk(cmos_pclk), .rst(cam_rst), .d(cam_y), .de(cam_de),
        .ce(px_ce), .px_de(px_de), .px_sol(px_sol), .px_sof(px_sof),
        .px(px565), .rgb_rbg(px_rbg)
    );

    //==================================================
    // Colour preview: camera -> DDR3 (preview_wr, triple buffered) ->
    // line buffer (preview_rd) -> compositor
    //==================================================
    localparam [22:0] PV_BASE = 23'h000000, PV_BANK = 23'h008000, PV_LINE = 23'd64;
    wire [1:0]  pv_ready_bank, pv_disp_bank;
    wire        pv_have_frame, pv_overflow;
    wire [15:0] pv_frames, pv_lines;
    wire [8:0]  pv_need_s;
    wire [10:0] pv_addr;
    wire [15:0] pv_data;
    (* ASYNC_REG = "TRUE" *) reg [1:0] freeze_s = 2'b00;
    always @(posedge cmos_pclk) freeze_s <= {freeze_s[0], gpio_out[8]};

    preview_wr #(.BASE(PV_BASE), .BANK_STRIDE(PV_BANK), .LINE_STRIDE(PV_LINE)) pv_wr (
        .rx_clk(cmos_pclk), .rx_rst(cam_rst),
        .ce(px_ce), .px_de(px_de), .px_sol(px_sol), .px_sof(px_sof), .px(px565),
        .freeze(freeze_s[1]), .overflow(pv_overflow),
        .dclk(dclk), .drst(drst),
        .req(a_req[1]), .baddr(a_baddr[1*23 +: 23]), .wdata(a_wdata[1*128 +: 128]),
        .gnt(a_gnt[1]),
        .disp_bank(pv_disp_bank), .ready_bank(pv_ready_bank),
        .have_frame(pv_have_frame), .frames(pv_frames)
    );
    assign a_we[1] = 1'b1;
    assign a_wbe[1*16 +: 16] = 16'hFFFF;

    preview_rd #(.BASE(PV_BASE), .BANK_STRIDE(PV_BANK), .LINE_STRIDE(PV_LINE)) pv_rd (
        .pclk(pclk_v), .prst(prst), .frame_start(frame_start),
        .need_s(pv_need_s), .rd_addr(pv_addr), .rd_data(pv_data),
        .dclk(dclk), .drst(drst),
        .req(a_req[0]), .baddr(a_baddr[0 +: 23]), .gnt(a_gnt[0]),
        .rvalid(a_rvalid[0]), .rdata(a_rdata),
        .ready_bank(pv_ready_bank), .disp_bank(pv_disp_bank), .lines_fetched(pv_lines)
    );
    assign a_we[0] = 1'b0;
    assign a_wdata[0 +: 128] = 128'd0;
    assign a_wbe[0 +: 16] = 16'd0;

    // into the fabric clock (GPIO in) and the pixel clock
    (* ASYNC_REG = "TRUE" *) reg [2:0] pv_rb_s0 = 3'b000, pv_rb_s1 = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [1:0] pv_valid_p = 2'b00;
    always @(posedge clk) begin
        pv_rb_s0 <= {pv_have_frame, pv_ready_bank};
        pv_rb_s1 <= pv_rb_s0;
    end
    always @(posedge pclk_v) pv_valid_p <= {pv_valid_p[0], pv_have_frame};

    //==================================================
    // Tester core: live mode on the camera
    //==================================================
    wire [31:0] gpio_unused;
    wire        busy, done, live_on;
    wire [3:0]  kernel_index;
    wire        st_bypass, st_ext, st_custom;
    wire [103:0] st_name;
    wire [7:0]  st_fps;
    wire        disp_start, disp_done, disp_in_we, disp_out_we, disp_masked, video_pattern;
    wire [13:0] disp_in_addr, disp_out_addr;
    wire [7:0]  disp_in_data, disp_out_data;
    wire [14:0] disp_lo, disp_hi;

    (* ASYNC_REG = "TRUE" *) reg [1:0] win_timeout_s = 2'b00;
    always @(posedge clk) win_timeout_s <= {win_timeout_s[0], win_timeout};

    // colour live mode (color_live, below)
    wire        ext_frame, ext_drop, ext_start, ext_rd_en, frame_color;
    wire [11:0] ext_rd_addr;
    wire [31:0] ext_rd_data;
    reg  [11:0] grab_h_s0, grab_h_s1, grab_v_s0, grab_v_s1;   // quasi-static

    assign gpio_in = {init_done, init_nacks[7:3] != 5'd0 ? 3'd7 : init_nacks[2:0],
                      gpio_out[11:0], pv_rb_s1[1:0], cal_fail_s[1], cal_ok_s[1], kernel_index,
                      1'b0, win_timeout_s[1], frame_color, pv_rb_s1[2], pins_s};

    fpga_tb_core #(
        .INIT_FILE(INIT_FILE),
        .ID_WIDTH(1),
        .HDMI(1),
        .CAP_AXI_WR(0),
        .IN_BYTE_WE(0),         // the UART bridge writes whole aligned words
        .CLK_HZ(CLK_HZ),
        .GRAB_CROP_X(0),
        .GRAB_CROP_Y(0),
        .GRAB_SCALE(3),
        .GRAB_BANKS(1),
        .GRAB_GRAY_IN(0),       // luminance from the RGB565 pixels
        .GRAB_PIX_CE(1),        // one pixel every other PCLK
        .LIVE_EXT(1)            // live runs from color_live (no internal grabber)
    ) core (
        .clk(clk),
        .aresetn(aresetn),
        .start_sw(live_sw),
        .btn_next(!btn_next_n),
        .btn_prev(!btn_prev_n),
        .rx_clk(cmos_pclk),
        .rx_locked(cam_on),
        .rx_data(px_rbg),
        .rx_de(px_de),
        .rx_ce(px_ce),
        .ext_frame(ext_frame), .ext_drop(ext_drop), .ext_start(ext_start),
        .ext_rd_en(ext_rd_en), .ext_rd_addr(ext_rd_addr), .ext_rd_data(ext_rd_data),
        .ext_h(grab_h_s1), .ext_v(grab_v_s1),
        .s_axi_awid(1'b0), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(3'd2), .s_axi_awburst(awburst),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(1'b0), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(3'd2), .s_axi_arburst(arburst),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .busy(busy), .done(done),
        .start_pulse(), .stream_addr(), .pixel_valid(),
        .dut_dataout(), .dut_output_valid(), .dut_status(),
        .kernel_index(kernel_index), .live_on(live_on),
        .st_bypass(st_bypass), .st_ext(st_ext), .st_custom(st_custom),
        .st_name(st_name), .st_fps(st_fps),
        .disp_start(disp_start), .disp_done(disp_done),
        .disp_in_we(disp_in_we), .disp_in_addr(disp_in_addr), .disp_in_data(disp_in_data),
        .disp_out_we(disp_out_we), .disp_out_addr(disp_out_addr), .disp_out_data(disp_out_data),
        .disp_masked(disp_masked), .disp_lo(disp_lo), .disp_hi(disp_hi),
        .video_pattern(video_pattern),
        .chip_clk(), .chip_reset_n(), .chip_kernel_valid(), .chip_normalization_valid(),
        .chip_pixel_valid(), .chip_test_mode(), .chip_datain(),
        .chip_dataout(8'd0), .chip_output_valid(1'b0), .chip_status(2'd0)
    );

    //==================================================
    // Colour DUT runs: rgb_grab (camera -> 128x128 R, G, B, Y in DDR3) ->
    // color_live: per channel plane_dma (DDR3 -> DUT input RAM) and a live
    // run; outputs into color_frame's channel planes
    //==================================================
    localparam [22:0] GR_BASE = 23'h020000, GR_BANK = 23'h001000;
    wire        gr_toggle, gr_bank;
    wire [15:0] gr_frames;
    wire [11:0] grab_h, grab_v;
    rgb_grab #(.BASE(GR_BASE), .BANK_STRIDE(GR_BANK)) grab (
        .rx_clk(cmos_pclk), .rx_rst(cam_rst),
        .ce(px_ce), .px_de(px_de), .px_sol(px_sol), .px_sof(px_sof), .px(px565),
        .h_active(grab_h), .v_active(grab_v),
        .dclk(dclk), .drst(drst),
        .req(a_req[3]), .baddr(a_baddr[3*23 +: 23]), .wdata(a_wdata[3*128 +: 128]),
        .gnt(a_gnt[3]), .frame_toggle(gr_toggle), .frame_bank(gr_bank), .frames(gr_frames)
    );
    assign a_we[3] = 1'b1;
    assign a_wbe[3*16 +: 16] = 16'hFFFF;
    always @(posedge clk) begin
        grab_h_s0 <= grab_h; grab_h_s1 <= grab_h_s0;
        grab_v_s0 <= grab_v; grab_v_s1 <= grab_v_s0;
    end

    wire       dma_bank, dma_req_t, dma_done_t;
    wire [1:0] dma_ch;
    plane_dma #(.BASE(GR_BASE), .BANK_STRIDE(GR_BANK)) dma (
        .clk(clk), .bank(dma_bank), .ch(dma_ch), .req_t(dma_req_t), .done_t(dma_done_t),
        .rd_en(ext_rd_en), .rd_addr(ext_rd_addr), .rd_data(ext_rd_data),
        .dclk(dclk), .drst(drst),
        .req(a_req[4]), .baddr(a_baddr[4*23 +: 23]), .gnt(a_gnt[4]),
        .rvalid(a_rvalid[4]), .rdata(a_rdata)
    );
    assign a_we[4] = 1'b0;
    assign a_wdata[4*128 +: 128] = 128'd0;
    assign a_wbe[4*16 +: 16] = 16'd0;

    // Colour or gray per frame: GPIO out [10:9] = 01 forces gray, 10 colour;
    // otherwise the preset decides (edge detectors gray), custom kernels colour
    wire preset_color;
    kernel_color kcolor (.index(kernel_index), .color(preset_color));
    wire want_color = gpio_out[9] ? 1'b0 : gpio_out[10] ? 1'b1 : (st_custom || preset_color);

    wire [2:0] ch_we;
    color_live clive (
        .clk(clk), .aresetn(aresetn),
        .frame_toggle(gr_toggle), .frame_bank(gr_bank),
        .live(live_on), .color(want_color), .busy(busy), .run_done(disp_done),
        .dma_bank(dma_bank), .dma_ch(dma_ch), .dma_req_t(dma_req_t), .dma_done_t(dma_done_t),
        .ext_frame(ext_frame), .ext_drop(ext_drop), .ext_start(ext_start),
        .ch_we(ch_we), .frame_color(frame_color)
    );

    //==================================================
    // Display: colour output planes -> compositor -> HDMI
    //==================================================
    wire        has_frame, disp_masked_p;
    wire [14:0] disp_lo_p, disp_hi_p;
    wire [13:0] rd_addr;
    wire [4:0]  rd_r, rd_g, rd_b;

    color_frame frames (
        .clk(clk), .aresetn(aresetn),
        .ch_we(ch_we), .run_done(disp_done),
        .run_lo(disp_lo), .run_hi(disp_hi), .run_masked(disp_masked),
        .out_we(disp_out_we), .out_addr(disp_out_addr), .out_data(disp_out_data),
        .pclk(pclk_v), .prst(prst), .frame_start(frame_start),
        .rd_addr(rd_addr), .rd_r(rd_r), .rd_g(rd_g), .rd_b(rd_b),
        .has_frame(has_frame),
        .disp_lo(disp_lo_p), .disp_hi(disp_hi_p), .disp_masked(disp_masked_p)
    );

    wire [7:0] r, g, b;
    wire       de, hs, vs;

    cam_compositor comp (
        .pclk(pclk_v), .prst(prst),
        .frame_start(frame_start),
        .need_s(pv_need_s), .pv_addr(pv_addr), .pv_data(pv_data), .pv_valid(pv_valid_p[1]),
        .rd_addr(rd_addr), .rd_r(rd_r), .rd_g(rd_g), .rd_b(rd_b),
        .has_frame(has_frame), .out_lo(disp_lo_p), .out_hi(disp_hi_p),
        .st_color(frame_color),
        .out_masked(disp_masked_p), .pattern(video_pattern),
        .st_live(live_on), .st_bypass(st_bypass), .st_ext(st_ext), .st_custom(st_custom),
        .st_name(st_name), .st_fps(st_fps),
        .r(r), .g(g), .b(b), .de(de), .hs(hs), .vs(vs)
    );

    hdmi_tx_gowin tx (
        .pclk(pclk_v), .sclk(sclk), .rst(prst),
        .r(r), .g(g), .b(b), .de(de), .hs(hs), .vs(vs),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    //==================================================
    // LEDs (active low)
    //==================================================
    reg [24:0] heartbeat = 25'd0;
    always @(posedge clk) heartbeat <= heartbeat + 25'd1;

    // DEBUG_LEDS: {S0, 27 MHz reference blink, video reset released, fabric
    // reset released, PLL locked, fabric heartbeat} (bit 5 .. bit 0). The
    // reference counts the raw oscillator, so heartbeat vs reference shows
    // whether the fabric clock is right without any PLL involved.
    reg [24:0] ref27 = 25'd0;
    always @(posedge clk27) ref27 <= ref27 + 25'd1;
    assign led_n = DEBUG_LEDS ? ~{rst_n, ref27[24], !prst, aresetn, locked, heartbeat[24]}
                              : ~{kernel_index, live_on, heartbeat[24]};

endmodule

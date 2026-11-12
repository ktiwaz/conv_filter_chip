// Tang Primer 20K camera pipeline: OV3660 (DVP, Y8 384x384) -> grabber
// (3x3 box average -> 128x128) -> DUT run per frame (fpga_tb_core live mode)
// -> 720p HDMI with input and output panes (the PYNQ video_compositor).
// The UART tester (scripts/tb_host.py) works on this bitstream too.
//
// Clocks: 27 MHz -> rPLL -> 371.25 MHz HDMI serial -> CLKDIV /5 -> 74.25 MHz
//         pixel; the same PLL's CLKOUTD (/8) -> 46.41 MHz fabric (XCLK =
//         23.2 MHz from it); the grabber runs on the camera's PCLK.
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
//   GPIO in   bit0 SCL  bit1 SDA  bit2 VSYNC  bit3 HREF  [11:8] filter preset
//             [23:16] GPIO out[7:0] read back
//             bit31 init done  [30:24] init NACKs (127 = 127 or more)
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
    output wire [2:0] tmds_d_n
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

    dbg_bridge #(.CLK_FREQ(CLK_HZ), .UART_SPEED(BAUD)) bridge (
        .clk_i(clk), .rst_i(!aresetn),
        .uart_rxd_i(uart_rx), .uart_txd_o(uart_tx),
        .mem_awvalid_o(awvalid), .mem_awaddr_o(awaddr), .mem_awid_o(),
        .mem_awlen_o(awlen), .mem_awburst_o(awburst), .mem_awready_i(awready),
        .mem_wvalid_o(wvalid), .mem_wdata_o(wdata), .mem_wstrb_o(wstrb),
        .mem_wlast_o(wlast), .mem_wready_i(wready),
        .mem_bvalid_i(bvalid), .mem_bresp_i(bresp), .mem_bid_i({3'd0, bid}),
        .mem_bready_o(bready),
        .mem_arvalid_o(arvalid), .mem_araddr_o(araddr), .mem_arid_o(),
        .mem_arlen_o(arlen), .mem_arburst_o(arburst), .mem_arready_i(arready),
        .mem_rvalid_i(rvalid), .mem_rdata_i(rdata), .mem_rresp_i(rresp),
        .mem_rid_i({3'd0, rid}), .mem_rlast_i(rlast), .mem_rready_o(rready),
        .gpio_inputs_i(gpio_in), .gpio_outputs_o(gpio_out)
    );

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

    // DVP capture, registered on the camera's PCLK: one Y8 byte per PCLK
    // while HREF is active
    reg [7:0] cam_y;
    reg       cam_de;
    always @(posedge cmos_pclk) begin
        cam_y  <= cmos_db;
        cam_de <= cmos_href ^ href_inv;
    end

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

    assign gpio_in = {init_done, init_nacks[7] ? 7'h7F : init_nacks[6:0],
                      gpio_out[7:0], 4'd0, kernel_index, 4'd0, pins_s};

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
        .GRAB_GRAY_IN(1)
    ) core (
        .clk(clk),
        .aresetn(aresetn),
        .start_sw(live_sw),
        .btn_next(!btn_next_n),
        .btn_prev(!btn_prev_n),
        .rx_clk(cmos_pclk),
        .rx_locked(cam_run && !cam_pwdn),
        .rx_data({16'd0, cam_y}),
        .rx_de(cam_de),
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
    // Display: frame buffers (single bank) -> compositor -> HDMI
    //==================================================
    wire        frame_start, has_frame, disp_masked_p;
    wire [14:0] disp_lo_p, disp_hi_p;
    wire [13:0] rd_addr;
    wire [7:0]  rd_in, rd_out;

    video_frame #(.BANKS(1)) frames (
        .clk(clk), .aresetn(aresetn),
        .run_start(disp_start), .run_done(disp_done),
        .run_lo(disp_lo), .run_hi(disp_hi), .run_masked(disp_masked),
        .in_we(disp_in_we), .in_addr(disp_in_addr), .in_data(disp_in_data),
        .out_we(disp_out_we), .out_addr(disp_out_addr), .out_data(disp_out_data),
        .pclk(pclk_v), .prst(prst), .frame_start(frame_start),
        .rd_addr(rd_addr), .rd_in(rd_in), .rd_out(rd_out),
        .has_frame(has_frame),
        .disp_lo(disp_lo_p), .disp_hi(disp_hi_p), .disp_masked(disp_masked_p)
    );

    wire [7:0] r, g, b;
    wire       de, hs, vs;

    video_compositor #(
        .TITLE_LIVE("INPUT (CAMERA)      ")
    ) comp (
        .pclk(pclk_v), .prst(prst),
        .frame_start(frame_start),
        .rd_addr(rd_addr), .rd_in(rd_in), .rd_out(rd_out),
        .has_frame(has_frame), .out_lo(disp_lo_p), .out_hi(disp_hi_p),
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

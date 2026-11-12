// 720p60 check of the live-display path on the Tang Primer 20K: the PYNQ
// video_compositor (rtl/video_out.v) driving hdmi_tx_gowin.
//
// Clocks: 27 MHz -> rPLL -> 371.25 MHz serial (27 * 55 / 4) -> CLKDIV /5 ->
// 74.25 MHz pixel clock (exact CEA-861 720p60).
//
// Default: the compositor's test pattern (colour bars, white edge, bouncing
// square). Hold S1 (pin T3) to see the live layout instead: both panes filled
// with synthetic gradients (input = column ramp, output = row ramp, read
// through the normal frame-buffer addressing), titles and the status line.
// LEDs (active low): led0 PLL locked, led1 frame heartbeat.
module hdmi720_top (
    input  wire       clk27,
    input  wire       rst_n,
    input  wire       btn_n,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led_n
);

    wire sclk, pclk, locked;

    rPLL #(
        .FCLKIN("27.0"),
        .IDIV_SEL(3),       // PFD 6.75 MHz
        .FBDIV_SEL(54),     // 6.75 * 55 = 371.25 MHz
        .ODIV_SEL(2)        // VCO 742.5 MHz
    ) pll (
        .CLKIN(clk27), .CLKOUT(sclk), .LOCK(locked),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    CLKDIV #(.DIV_MODE("5")) pdiv (
        .HCLKIN(sclk), .RESETN(locked), .CALIB(1'b0), .CLKOUT(pclk)
    );

    reg [3:0] prst_sync = 4'hF;
    always @(posedge pclk or negedge locked)
        if (!locked) prst_sync <= 4'hF;
        else         prst_sync <= {prst_sync[2:0], !rst_n};
    wire prst = prst_sync[3];

    reg [1:0] btn_s = 2'b11;
    always @(posedge pclk) btn_s <= {btn_s[0], btn_n};
    wire show_layout = !btn_s[1];

    // Synthetic frame buffers, 1-cycle read latency like video_frame
    wire [13:0] rd_addr;
    reg  [7:0]  rd_in, rd_out;
    always @(posedge pclk) begin
        rd_in  <= {rd_addr[6:0], 1'b0};     // column ramp
        rd_out <= {rd_addr[13:7], 1'b0};    // row ramp
    end

    wire [7:0] r, g, b;
    wire       de, hs, vs, frame_start;

    video_compositor comp (
        .pclk(pclk), .prst(prst),
        .frame_start(frame_start),
        .rd_addr(rd_addr), .rd_in(rd_in), .rd_out(rd_out),
        .has_frame(1'b1), .out_lo(15'd0), .out_hi(15'd16384), .out_masked(1'b1),
        .pattern(!show_layout),
        .st_live(1'b1), .st_bypass(1'b0), .st_ext(1'b0), .st_custom(1'b0),
        .st_name("EMBOSS       "), .st_fps(8'h30),
        .r(r), .g(g), .b(b), .de(de), .hs(hs), .vs(vs)
    );

    hdmi_tx_gowin tx (
        .pclk(pclk), .sclk(sclk), .rst(prst),
        .r(r), .g(g), .b(b), .de(de), .hs(hs), .vs(vs),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    reg [5:0] fcount = 6'd0;
    always @(posedge pclk) if (frame_start) fcount <= fcount + 6'd1;
    assign led_n = ~{4'b0000, fcount[5], locked};

endmodule

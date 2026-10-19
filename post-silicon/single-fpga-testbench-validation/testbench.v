module testbench #(
    parameter INIT_FILE = "input_image_w32.hex",
    parameter EDID_FILE = "edid_720p.data"
) (
    input  wire refclk_125,
    input  wire [1:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led,

    // HDMI out (720p60)
    output wire       hdmi_tx_clk_p,
    output wire       hdmi_tx_clk_n,
    output wire [2:0] hdmi_tx_d_p,
    output wire [2:0] hdmi_tx_d_n,

    // HDMI in (720p60 EDID)
    input  wire       hdmi_rx_clk_p,
    input  wire       hdmi_rx_clk_n,
    input  wire [2:0] hdmi_rx_d_p,
    input  wire [2:0] hdmi_rx_d_n,
    inout  wire       hdmi_rx_scl,
    inout  wire       hdmi_rx_sda,
    output wire       hdmi_rx_hpd,

    // Link to the external DUT board (RPi header, see tcl/link_pins.tcl)
    output wire       chip_clk,
    output wire       chip_reset_n,
    output wire       chip_kernel_valid,
    output wire       chip_normalization_valid,
    output wire       chip_pixel_valid,
    output wire       chip_test_mode,
    output wire [7:0] chip_datain,
    input  wire [7:0] chip_dataout,
    input  wire       chip_output_valid,
    input  wire [1:0] chip_status
);

    wire clk;
    wire clk_200;
    wire rst;
    wire locked;
    assign rst = sw[0];

    clk_wiz_0 clk_gen
    (
        // Clock out ports
        .clk_out1(clk),     // output clk_out1
        .clk_out2(clk_200), // output clk_out2 (HDMI-in IDELAY reference)
        // Status and control signals
        .reset(rst), // input reset
        .locked(locked),       // output locked
        // Clock in ports
        .clk_in1(refclk_125)      // input clk_in1
    );

    reg [25:0] counter = 0;
    reg led_reg;

    // Flash LED to show that clock is running
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            led_reg <= 0;
            counter <= 0;
        end
        else if (counter == 49_999_999) begin
            counter <= 0;
            led_reg <= ~led_reg;
        end
        else begin
            counter <= counter + 1'b1;
        end
    end

    // Reset synchronizer: async assert, sync deassert once the clock is locked
    reg [2:0] rst_sync;
    always @(posedge clk or posedge rst) begin
        if (rst)
            rst_sync <= 3'b000;
        else
            rst_sync <= {rst_sync[1:0], locked};
    end

    wire aresetn = rst_sync[2];

    // JTAG-to-AXI master
    wire [0:0]  axi_awid,    axi_bid,   axi_arid,  axi_rid;
    wire [31:0] axi_awaddr,  axi_araddr;
    wire [7:0]  axi_awlen,   axi_arlen;
    wire [2:0]  axi_awsize,  axi_arsize;
    wire [1:0]  axi_awburst, axi_arburst;
    wire        axi_awvalid, axi_awready;
    wire [31:0] axi_wdata;
    wire [3:0]  axi_wstrb;
    wire        axi_wlast,   axi_wvalid,  axi_wready;
    wire [1:0]  axi_bresp;
    wire        axi_bvalid,  axi_bready;
    wire        axi_arvalid, axi_arready;
    wire [31:0] axi_rdata;
    wire [1:0]  axi_rresp;
    wire        axi_rlast,   axi_rvalid,  axi_rready;

    jtag_axi_0 jtag_axi (
        .aclk(clk),
        .aresetn(aresetn),
        .m_axi_awid(axi_awid),
        .m_axi_awaddr(axi_awaddr),
        .m_axi_awlen(axi_awlen),
        .m_axi_awsize(axi_awsize),
        .m_axi_awburst(axi_awburst),
        .m_axi_awlock(),
        .m_axi_awcache(),
        .m_axi_awprot(),
        .m_axi_awqos(),
        .m_axi_awvalid(axi_awvalid),
        .m_axi_awready(axi_awready),
        .m_axi_wdata(axi_wdata),
        .m_axi_wstrb(axi_wstrb),
        .m_axi_wlast(axi_wlast),
        .m_axi_wvalid(axi_wvalid),
        .m_axi_wready(axi_wready),
        .m_axi_bid(axi_bid),
        .m_axi_bresp(axi_bresp),
        .m_axi_bvalid(axi_bvalid),
        .m_axi_bready(axi_bready),
        .m_axi_arid(axi_arid),
        .m_axi_araddr(axi_araddr),
        .m_axi_arlen(axi_arlen),
        .m_axi_arsize(axi_arsize),
        .m_axi_arburst(axi_arburst),
        .m_axi_arlock(),
        .m_axi_arcache(),
        .m_axi_arprot(),
        .m_axi_arqos(),
        .m_axi_arvalid(axi_arvalid),
        .m_axi_arready(axi_arready),
        .m_axi_rid(axi_rid),
        .m_axi_rdata(axi_rdata),
        .m_axi_rresp(axi_rresp),
        .m_axi_rlast(axi_rlast),
        .m_axi_rvalid(axi_rvalid),
        .m_axi_rready(axi_rready)
    );

    // Input RAM -> DUT sequencer -> conv_filter_top -> capture RAM, with AXI access
    wire        busy, done, start_pulse;
    wire [13:0] stream_addr;
    wire        pixel_valid;
    wire [7:0]  dut_dataout;
    wire        dut_output_valid;
    wire [1:0]  dut_status;

    // Live: the LEDs show the filter preset index (binary). Otherwise
    // led0 locked, led1 heartbeat, led2 done, led3 busy.
    wire [3:0] kernel_index;
    wire       live_on;
    assign led = live_on ? kernel_index : {busy, done, led_reg, locked};

    //==================================================
    // HDMI in
    //==================================================
    wire        rx_clk, rx_locked, rx_de;
    wire [23:0] rx_data;

    hdmi_in #(
        .EDID_FILE(EDID_FILE)
    ) hdmi_rx (
        .ref_clk_200(clk_200),
        .rst(!locked),
        .tmds_clk_p(hdmi_rx_clk_p),
        .tmds_clk_n(hdmi_rx_clk_n),
        .tmds_data_p(hdmi_rx_d_p),
        .tmds_data_n(hdmi_rx_d_n),
        .ddc_scl(hdmi_rx_scl),
        .ddc_sda(hdmi_rx_sda),
        .hpd(hdmi_rx_hpd),
        .rx_clk(rx_clk),
        .rx_locked(rx_locked),
        .rx_data(rx_data),
        .rx_de(rx_de),
        .rx_hs(),
        .rx_vs()
    );

    // Display frame-buffer writes from the core
    wire        disp_start, disp_done, disp_in_we, disp_out_we, disp_masked, video_pattern;
    wire [13:0] disp_in_addr, disp_out_addr;
    wire [7:0]  disp_in_data, disp_out_data;
    wire [14:0] disp_lo, disp_hi;

    fpga_tb_core #(
        .INIT_FILE(INIT_FILE),
        .ID_WIDTH(1)
    ) core (
        .clk(clk),
        .aresetn(aresetn),
        .start_sw(sw[1]),
        .btn_next(btn[0]),
        .btn_prev(btn[1]),
        .rx_clk(rx_clk),
        .rx_locked(rx_locked),
        .rx_data(rx_data),
        .rx_de(rx_de),
        .s_axi_awid(axi_awid),
        .s_axi_awaddr(axi_awaddr),
        .s_axi_awlen(axi_awlen),
        .s_axi_awsize(axi_awsize),
        .s_axi_awburst(axi_awburst),
        .s_axi_awvalid(axi_awvalid),
        .s_axi_awready(axi_awready),
        .s_axi_wdata(axi_wdata),
        .s_axi_wstrb(axi_wstrb),
        .s_axi_wlast(axi_wlast),
        .s_axi_wvalid(axi_wvalid),
        .s_axi_wready(axi_wready),
        .s_axi_bid(axi_bid),
        .s_axi_bresp(axi_bresp),
        .s_axi_bvalid(axi_bvalid),
        .s_axi_bready(axi_bready),
        .s_axi_arid(axi_arid),
        .s_axi_araddr(axi_araddr),
        .s_axi_arlen(axi_arlen),
        .s_axi_arsize(axi_arsize),
        .s_axi_arburst(axi_arburst),
        .s_axi_arvalid(axi_arvalid),
        .s_axi_arready(axi_arready),
        .s_axi_rid(axi_rid),
        .s_axi_rdata(axi_rdata),
        .s_axi_rresp(axi_rresp),
        .s_axi_rlast(axi_rlast),
        .s_axi_rvalid(axi_rvalid),
        .s_axi_rready(axi_rready),
        .busy(busy),
        .done(done),
        .start_pulse(start_pulse),
        .stream_addr(stream_addr),
        .pixel_valid(pixel_valid),
        .dut_dataout(dut_dataout),
        .dut_output_valid(dut_output_valid),
        .dut_status(dut_status),
        .kernel_index(kernel_index),
        .live_on(live_on),
        .disp_start(disp_start),
        .disp_done(disp_done),
        .disp_in_we(disp_in_we),
        .disp_in_addr(disp_in_addr),
        .disp_in_data(disp_in_data),
        .disp_out_we(disp_out_we),
        .disp_out_addr(disp_out_addr),
        .disp_out_data(disp_out_data),
        .disp_masked(disp_masked),
        .disp_lo(disp_lo),
        .disp_hi(disp_hi),
        .video_pattern(video_pattern),
        .chip_clk(chip_clk),
        .chip_reset_n(chip_reset_n),
        .chip_kernel_valid(chip_kernel_valid),
        .chip_normalization_valid(chip_normalization_valid),
        .chip_pixel_valid(chip_pixel_valid),
        .chip_test_mode(chip_test_mode),
        .chip_datain(chip_datain),
        .chip_dataout(chip_dataout),
        .chip_output_valid(chip_output_valid),
        .chip_status(chip_status)
    );


    //==================================================
    // HDMI out: TX pixel/serial clocks from the fabric clock
    //==================================================
    wire pclk, sclk, video_locked;

    clk_wiz_1 video_clk_gen (
        .clk_out1(pclk),    // ~74.25 MHz pixel clock
        .clk_out2(sclk),    // 5x serial clock
        .reset(!locked),
        .locked(video_locked),
        .clk_in1(clk)
    );

    wire        prst, frame_start, has_frame;
    wire [14:0] disp_lo_p, disp_hi_p;
    wire        disp_masked_p;
    wire [13:0] rd_addr;
    wire [7:0]  rd_in, rd_out;

    // Display: input (left) and DUT output (right), 4x, side by side
    video_out hdmi_out (
        .pclk(pclk),
        .sclk(sclk),
        .rst(!video_locked),
        .prst(prst),
        .frame_start(frame_start),
        .rd_addr(rd_addr),
        .rd_in(rd_in),
        .rd_out(rd_out),
        .has_frame(has_frame),
        .out_lo(disp_lo_p),
        .out_hi(disp_hi_p),
        .out_masked(disp_masked_p),
        .pattern(video_pattern),
        .tmds_clk_p(hdmi_tx_clk_p),
        .tmds_clk_n(hdmi_tx_clk_n),
        .tmds_data_p(hdmi_tx_d_p),
        .tmds_data_n(hdmi_tx_d_n)
    );

    video_frame frames (
        .clk(clk),
        .aresetn(aresetn),
        .run_start(disp_start),
        .run_done(disp_done),
        .run_lo(disp_lo),
        .run_hi(disp_hi),
        .run_masked(disp_masked),
        .in_we(disp_in_we),
        .in_addr(disp_in_addr),
        .in_data(disp_in_data),
        .out_we(disp_out_we),
        .out_addr(disp_out_addr),
        .out_data(disp_out_data),
        .pclk(pclk),
        .prst(prst),
        .frame_start(frame_start),
        .rd_addr(rd_addr),
        .rd_in(rd_in),
        .rd_out(rd_out),
        .has_frame(has_frame),
        .disp_lo(disp_lo_p),
        .disp_hi(disp_hi_p),
        .disp_masked(disp_masked_p)
    );

ila_0 your_instance_name (
	.clk(clk), // input wire clk


	.probe0(dut_dataout), // input wire [7:0]  probe0
	.probe1(dut_output_valid), // input wire [0:0]  probe1
	.probe2(pixel_valid), // input wire [0:0]  probe2
	.probe3(stream_addr) // input wire [13:0]  probe3
);


endmodule

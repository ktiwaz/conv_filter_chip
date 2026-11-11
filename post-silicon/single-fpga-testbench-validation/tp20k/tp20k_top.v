// Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7, dock board) top level:
// UART -> AXI bridge (dbg_bridge) -> fpga_tb_core (input RAM, sequencer, conv_filter_top,
// capture RAM). No HDMI; the external-DUT link pins are not brought out.
//
// The PC talks to the bridge over the onboard debugger's USB UART
// (scripts/tb_host.py). LEDs (active low): led0 heartbeat (PLL running),
// led1 run done, led5..led2 filter preset index. Buttons (active low):
// rst_n resets the tester, btn_next_n / btn_prev_n step the filter preset.
module tp20k_top #(
    parameter CLK_HZ       = 48_000_000,
    parameter BAUD         = 1_000_000,
    parameter INIT_FILE    = "../input_image_w32.hex",   // relative to tp20k/
    parameter SIM          = 0      // 1: clk27 is used directly, no rPLL
) (
    input  wire       clk27,
    input  wire       rst_n,
    input  wire       btn_next_n,
    input  wire       btn_prev_n,
    input  wire       uart_rx,      // from the debugger (PC -> FPGA)
    output wire       uart_tx,      // to the debugger   (FPGA -> PC)
    output wire [5:0] led_n
);

    wire       busy, done;
    wire [3:0] kernel_index;

    //==================================================
    // Clock: 27 MHz -> 48 MHz (27 * 16 / 9; PFD 3 MHz, VCO 768 MHz)
    //==================================================
    wire clk, locked;

    generate
        if (SIM) begin : g_sim_clk
            assign clk    = clk27;
            assign locked = 1'b1;
        end else begin : g_pll
            rPLL #(
                .FCLKIN("27.0"),
                .IDIV_SEL(8),
                .FBDIV_SEL(15),
                .ODIV_SEL(16)
            ) pll (
                .CLKIN(clk27), .CLKOUT(clk), .LOCK(locked),
                .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
                .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
                .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
                .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
            );
        end
    endgenerate

    //==================================================
    // Reset: asserted while the button is pressed or the PLL is unlocked,
    // released synchronously
    //==================================================
    reg [3:0] rst_sync = 4'b0000;
    always @(posedge clk or negedge locked) begin
        if (!locked)
            rst_sync <= 4'b0000;
        else
            rst_sync <= {rst_sync[2:0], rst_n};
    end
    wire aresetn = rst_sync[3];

    //==================================================
    // UART -> AXI: ultraembedded dbg_bridge (third_party/core_dbg_bridge).
    // Single-beat 32-bit accesses; awsize/arsize are fixed at 4 bytes.
    //==================================================
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire [7:0]  awlen, arlen;
    wire [1:0]  awburst, arburst, bresp, rresp;
    wire [3:0]  wstrb;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rlast, rvalid, rready;
    wire        bid, rid;

    dbg_bridge #(
        .CLK_FREQ(CLK_HZ),
        .UART_SPEED(BAUD)
    ) bridge (
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
        .gpio_inputs_i({28'd0, kernel_index}), .gpio_outputs_o()
    );

    //==================================================
    // Tester core with the internal DUT
    //==================================================
    fpga_tb_core #(
        .INIT_FILE(INIT_FILE),
        .ID_WIDTH(1),
        .HDMI(0),
        .CAP_AXI_WR(0)
    ) core (
        .clk(clk),
        .aresetn(aresetn),
        .start_sw(1'b0),
        .btn_next(!btn_next_n),
        .btn_prev(!btn_prev_n),
        .rx_clk(clk), .rx_locked(1'b0), .rx_data(24'd0), .rx_de(1'b0),
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
        .kernel_index(kernel_index), .live_on(),
        .st_bypass(), .st_ext(), .st_custom(), .st_name(), .st_fps(),
        .disp_start(), .disp_done(), .disp_in_we(), .disp_in_addr(), .disp_in_data(),
        .disp_out_we(), .disp_out_addr(), .disp_out_data(), .disp_masked(),
        .disp_lo(), .disp_hi(), .video_pattern(),
        .chip_clk(), .chip_reset_n(), .chip_kernel_valid(), .chip_normalization_valid(),
        .chip_pixel_valid(), .chip_test_mode(), .chip_datain(),
        .chip_dataout(8'd0), .chip_output_valid(1'b0), .chip_status(2'd0)
    );

    //==================================================
    // LEDs (active low)
    //==================================================
    reg [24:0] heartbeat = 25'd0;
    always @(posedge clk) heartbeat <= heartbeat + 25'd1;

    assign led_n = ~{kernel_index, done, heartbeat[24]};

endmodule

// I/O timing lab top level (role "iolab"): JTAG-AXI + iolab_board.
// See rtl/iolab_core.v for the experiments and register map, and
// tcl/iolab_pins.tcl for the wirings.
module iolab #(
    parameter DIV    = 40,
    parameter LANES  = 8,
    parameter WIRING = 0
) (
    input  wire       refclk_125,
    input  wire [1:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led,

    output wire [7:0] lane_out,
    input  wire [7:0] lane_in,
    output wire       fclk_out,
    input  wire       fclk_in,
    output wire       ret_out,
    input  wire       ret_in
);

    wire clk, aresetn, locked, rclk_alive;

    wire [0:0]  awid, bid, arid, rid;
    wire [31:0] awaddr, araddr, wdata, rdata;
    wire [7:0]  awlen, arlen;
    wire [2:0]  awsize, arsize;
    wire [1:0]  awburst, arburst, bresp, rresp;
    wire [3:0]  wstrb;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rlast, rvalid, rready;

    jtag_axi_0 jtag_axi (
        .aclk(clk), .aresetn(aresetn),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(),
        .m_axi_awqos(), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
        .m_axi_arqos(), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    iolab_board #(
        .DIV(DIV), .LANES(LANES), .WIRING(WIRING)
    ) board (
        .refclk_125(refclk_125), .rst(sw[0]),
        .clk_ctl(clk), .aresetn(aresetn), .locked(locked), .rclk_alive(rclk_alive),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awsize(awsize),
        .s_axi_awburst(awburst), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize),
        .s_axi_arburst(arburst), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .lane_out(lane_out), .lane_in(lane_in),
        .fclk_out(fclk_out), .fclk_in(fclk_in), .ret_out(ret_out), .ret_in(ret_in)
    );

    // led0: MMCM locked, led1: control clock heartbeat, led2: looped-back clock running
    reg [25:0] hb = 26'd0;
    always @(posedge clk) hb <= hb + 26'd1;
    assign led = {1'b0, rclk_alive, hb[25], locked};

endmodule

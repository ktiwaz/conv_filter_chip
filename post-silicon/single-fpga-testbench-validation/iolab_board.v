// I/O lab board level (everything except JTAG-AXI, so it can be simulated):
// MMCM, clock forwarding, looped-back clock buffer, reset, iolab_core.
//
// The MMCM VCO is fixed at 1000 MHz (125 MHz x 8), so one fine phase-shift
// step is always 1 ns / 56 = 17.86 ps. clk_ref and clk_ps run at 1000 / DIV MHz:
// DIV 40, 20, 16, 12, 10 -> 25, 50, 62.5, 83.3, 100 MHz.
module iolab_board #(
    parameter DIV    = 40,
    parameter LANES  = 8,
    parameter WIRING = 0
) (
    input  wire       refclk_125,
    input  wire       rst,              // async, active high

    output wire       clk_ctl,          // 50 MHz control / AXI clock
    output wire       aresetn,
    output wire       locked,
    output wire       rclk_alive,       // toggles at rclk / 2^24

    // AXI4 slave
    input  wire [0:0]  s_axi_awid,
    input  wire [31:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,
    input  wire [2:0]  s_axi_awsize,
    input  wire [1:0]  s_axi_awburst,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wlast,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [0:0]  s_axi_bid,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [0:0]  s_axi_arid,
    input  wire [31:0] s_axi_araddr,
    input  wire [7:0]  s_axi_arlen,
    input  wire [2:0]  s_axi_arsize,
    input  wire [1:0]  s_axi_arburst,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [0:0]  s_axi_rid,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rlast,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // Loopback pins
    output wire [7:0] lane_out,
    input  wire [7:0] lane_in,
    output wire       fclk_out,         // forwarded clock (from clk_ref)
    input  wire       fclk_in,          // ... after its loopback wire
    output wire       ret_out,          // B2 return line, launched on rclk
    input  wire       ret_in
);

    //==================================================
    // MMCM: clk_ref (fixed), clk_ps (fine phase shift), clk_ctl (50 MHz)
    //==================================================
    wire clkfb, ref_u, ps_u, ctl_u;
    wire clk_ref, clk_ps;
    wire psen, psincdec, psdone;

    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(8.0),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(8.0),
        .CLKOUT0_DIVIDE_F(DIV),
        .CLKOUT1_DIVIDE(DIV),
        .CLKOUT1_USE_FINE_PS("TRUE"),
        .CLKOUT2_DIVIDE(20),
        .COMPENSATION("INTERNAL")
    ) mmcm (
        .CLKIN1(refclk_125), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .CLKFBIN(clkfb), .CLKFBOUT(clkfb), .CLKFBOUTB(),
        .CLKOUT0(ref_u), .CLKOUT0B(), .CLKOUT1(ps_u), .CLKOUT1B(),
        .CLKOUT2(ctl_u), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .PSCLK(clk_ctl), .PSEN(psen), .PSINCDEC(psincdec), .PSDONE(psdone),
        .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DO(), .DRDY(), .DWE(1'b0),
        .LOCKED(locked), .CLKINSTOPPED(), .CLKFBSTOPPED(),
        .PWRDWN(1'b0), .RST(rst)
    );

    BUFG ref_buf (.I(ref_u), .O(clk_ref));
    BUFG ps_buf  (.I(ps_u),  .O(clk_ps));
    BUFG ctl_buf (.I(ctl_u), .O(clk_ctl));

    // Control-domain reset: released once the MMCM is locked
    reg [2:0] rst_sync = 3'b000;
    always @(posedge clk_ctl or negedge locked) begin
        if (!locked) rst_sync <= 3'b000;
        else         rst_sync <= {rst_sync[1:0], 1'b1};
    end
    assign aresetn = rst_sync[2];

    //==================================================
    // Forwarded clock out, looped-back clock in (as on the DUT board: pin ->
    // BUFG -> fabric)
    //==================================================
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE")
    ) fwd (
        .Q(fclk_out), .C(clk_ref), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
    );

    wire rclk;
    BUFG rclk_buf (.I(fclk_in), .O(rclk));

    reg [23:0] rclk_count = 24'd0;
    always @(posedge rclk) rclk_count <= rclk_count + 24'd1;
    assign rclk_alive = rclk_count[23];

    //==================================================
    // Core
    //==================================================
    iolab_core #(
        .DIV(DIV), .LANES(LANES), .WIRING(WIRING), .VCO_MHZ(1000), .ID_WIDTH(1)
    ) core (
        .clk(clk_ctl), .aresetn(aresetn),
        .clk_ref(clk_ref), .clk_ps(clk_ps), .rclk(rclk),
        .psen(psen), .psincdec(psincdec), .psdone(psdone),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize), .s_axi_awburst(s_axi_awburst),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize), .s_axi_arburst(s_axi_arburst),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .lane_out(lane_out), .lane_in(lane_in), .ret_out(ret_out), .ret_in(ret_in)
    );

endmodule

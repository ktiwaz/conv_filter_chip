module testbench #(
    parameter INIT_FILE = "input_image_w32.hex"
) (
    input  wire refclk_125,
    input  wire [1:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led
);

    wire clk;
    wire rst;
    wire locked;
    assign rst = sw[0];
    assign led[0] = locked;

    clk_wiz_0 clk_gen
    (
        // Clock out ports
        .clk_out1(clk),     // output clk_out1
        // Status and control signals
        .reset(rst), // input reset
        .locked(locked),       // output locked
        // Clock in ports
        .clk_in1(refclk_125)      // input clk_in1
    );

    reg [25:0] counter = 0;
    reg led_reg;
    assign led[1] = led_reg;

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

    // Input RAM -> stream -> capture RAM, with AXI access to both RAMs
    wire        busy, done, start_pulse;
    wire [13:0] stream_addr;
    wire [7:0]  stream_data;
    wire        stream_valid;

    assign led[2] = done;
    assign led[3] = busy;

    fpga_tb_core #(
        .INIT_FILE(INIT_FILE),
        .ID_WIDTH(1)
    ) core (
        .clk(clk),
        .aresetn(aresetn),
        .start_sw(sw[1]),
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
        .stream_data(stream_data),
        .stream_valid(stream_valid)
    );


ila_0 your_instance_name (
	.clk(clk), // input wire clk


	.probe0(stream_data), // input wire [7:0]  probe0
	.probe1(start_pulse), // input wire [0:0]  probe1
	.probe2(busy), // input wire [0:0]  probe2
	.probe3(stream_addr) // input wire [13:0]  probe3
);


endmodule

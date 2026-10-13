// FPGA testbench core: JTAG/AXI-accessible input RAM, stream source,
// capture sink, and capture RAM. Everything except vendor IP lives here
// so it can be simulated directly.
//
// AXI address map (byte addresses):
//   0x0000_0000 - 0x0000_3FFF  input RAM   (16384 x 8, packed 4 px/word, little-endian)
//   0x0001_0000 - 0x0001_3FFF  capture RAM (16384 x 8, same packing)
//   0x0002_0000  CTRL      W   bit0: start stream (self-clearing)
//   0x0002_0004  STATUS    R   bit0: busy, bit1: done (sticky, cleared on start)
//   0x0002_0008  CAP_COUNT R   valid beats captured since last start (0..16384)
//   0x0002_000C  ID        R   0xC0F1_0001
module fpga_tb_core #(
    parameter INIT_FILE = "input_image_w32.hex",
    parameter ID_WIDTH  = 1
) (
    input  wire                  clk,
    input  wire                  aresetn,     // synchronous, active low
    input  wire                  start_sw,    // asynchronous switch; rising edge starts a stream

    // AXI4 slave (from jtag_axi)
    input  wire [ID_WIDTH-1:0]   s_axi_awid,
    input  wire [31:0]           s_axi_awaddr,
    input  wire [7:0]            s_axi_awlen,
    input  wire [2:0]            s_axi_awsize,
    input  wire [1:0]            s_axi_awburst,
    input  wire                  s_axi_awvalid,
    output wire                  s_axi_awready,
    input  wire [31:0]           s_axi_wdata,
    input  wire [3:0]            s_axi_wstrb,
    input  wire                  s_axi_wlast,
    input  wire                  s_axi_wvalid,
    output wire                  s_axi_wready,
    output wire [ID_WIDTH-1:0]   s_axi_bid,
    output wire [1:0]            s_axi_bresp,
    output wire                  s_axi_bvalid,
    input  wire                  s_axi_bready,
    input  wire [ID_WIDTH-1:0]   s_axi_arid,
    input  wire [31:0]           s_axi_araddr,
    input  wire [7:0]            s_axi_arlen,
    input  wire [2:0]            s_axi_arsize,
    input  wire [1:0]            s_axi_arburst,
    input  wire                  s_axi_arvalid,
    output wire                  s_axi_arready,
    output wire [ID_WIDTH-1:0]   s_axi_rid,
    output wire [31:0]           s_axi_rdata,
    output wire [1:0]            s_axi_rresp,
    output wire                  s_axi_rlast,
    output wire                  s_axi_rvalid,
    input  wire                  s_axi_rready,

    // Status / debug
    output wire                  busy,
    output reg                   done,
    output wire                  start_pulse,
    output reg  [13:0]           stream_addr,
    output reg  [7:0]            stream_data,
    output reg                   stream_valid
);

    localparam [31:0] ID_VALUE = 32'hC0F1_0001;
    localparam [14:0] NUM_PIXELS = 15'd16384;

    //==================================================
    // AXI -> native bus
    //==================================================
    wire        m_en;
    wire [3:0]  m_we;
    wire [17:0] m_addr;
    wire [31:0] m_wdata;
    reg  [31:0] m_rdata;
    reg         m_rvalid;

    axi4_slave_native #(
        .ADDR_WIDTH(18),
        .ID_WIDTH(ID_WIDTH)
    ) axi_slave (
        .aclk(clk),
        .aresetn(aresetn),
        .s_axi_awid(s_axi_awid),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .m_en(m_en),
        .m_we(m_we),
        .m_addr(m_addr),
        .m_wdata(m_wdata),
        .m_rdata(m_rdata),
        .m_rvalid(m_rvalid)
    );

    //==================================================
    // Address decode
    //==================================================
    localparam SEL_IN   = 2'd0,
               SEL_CAP  = 2'd1,
               SEL_REGS = 2'd2;

    wire [1:0]  sel     = m_addr[17:16];
    wire [11:0] word    = m_addr[13:2];
    wire        in_en   = m_en && (sel == SEL_IN);
    wire        cap_en  = m_en && (sel == SEL_CAP);
    wire        reg_en  = m_en && (sel == SEL_REGS);
    wire        ctrl_start = reg_en && m_addr[3:2] == 2'd0 && m_we[0] && m_wdata[0];

    wire [31:0] in_a_dout, cap_a_dout;

    reg [14:0]  cap_count;
    reg [31:0]  reg_rdata;
    reg [1:0]   rd_sel_q;
    reg         rd_pend_q;

    // Read return: RAM output is valid one cycle after m_en, then registered.
    always @(posedge clk) begin
        if (!aresetn) begin
            rd_pend_q <= 1'b0;
            m_rvalid  <= 1'b0;
        end else begin
            rd_pend_q <= m_en && (m_we == 4'b0000);
            m_rvalid  <= rd_pend_q;
        end

        if (m_en) begin
            rd_sel_q <= sel;
            case (m_addr[3:2])
                2'd0: reg_rdata <= 32'd0;
                2'd1: reg_rdata <= {30'd0, done, busy};
                2'd2: reg_rdata <= {17'd0, cap_count};
                2'd3: reg_rdata <= ID_VALUE;
            endcase
        end

        case (rd_sel_q)
            SEL_IN:   m_rdata <= in_a_dout;
            SEL_CAP:  m_rdata <= cap_a_dout;
            SEL_REGS: m_rdata <= reg_rdata;
            default:  m_rdata <= 32'd0;
        endcase
    end

    //==================================================
    // Start: synchronized rising edge of the switch, or CTRL.start
    //==================================================
    reg [2:0] sw_sync;
    always @(posedge clk) begin
        if (!aresetn)
            sw_sync <= 3'b111;  // a switch already high at reset doesn't start a stream
        else
            sw_sync <= {sw_sync[1:0], start_sw};
    end

    assign start_pulse = (sw_sync[1] && !sw_sync[2]) || ctrl_start;

    // Starts are ignored while a stream is still in flight.
    wire start_go = start_pulse && !busy;

    //==================================================
    // Stream source: input RAM port B, one pixel per cycle
    //==================================================
    localparam IDLE   = 1'd0,
               STREAM = 1'd1;

    reg        state;
    reg        rd_valid_q;
    reg [1:0]  lane_q;
    wire [31:0] in_b_dout;

    always @(posedge clk) begin
        if (!aresetn) begin
            state       <= IDLE;
            stream_addr <= 14'd0;
        end else begin
            case (state)
                IDLE: begin
                    stream_addr <= 14'd0;
                    if (start_go)
                        state <= STREAM;
                end
                STREAM: begin
                    stream_addr <= stream_addr + 14'd1;
                    if (stream_addr == 14'd16383)
                        state <= IDLE;
                end
            endcase
        end
    end

    // Stage 1: BRAM read. Stage 2: byte select into a registered output.
    always @(posedge clk) begin
        if (!aresetn) begin
            rd_valid_q   <= 1'b0;
            stream_valid <= 1'b0;
            stream_data  <= 8'd0;
        end else begin
            rd_valid_q   <= (state == STREAM);
            lane_q       <= stream_addr[1:0];
            stream_valid <= rd_valid_q;
            stream_data  <= in_b_dout[lane_q*8 +: 8];
        end
    end

    assign busy = (state == STREAM) || rd_valid_q || stream_valid;

    always @(posedge clk) begin
        if (!aresetn)
            done <= 1'b0;
        else if (start_go)
            done <= 1'b0;
        else if (stream_valid && !rd_valid_q && state == IDLE)
            done <= 1'b1;
    end

    //==================================================
    // DUT insertion point: replace this loopback with the chip / model.
    //==================================================
    wire       cap_valid = stream_valid;
    wire [7:0] cap_data  = stream_data;

    //==================================================
    // Capture sink: capture RAM port B, byte writes at an incrementing address
    //==================================================
    wire cap_wr = cap_valid && (cap_count < NUM_PIXELS);

    always @(posedge clk) begin
        if (!aresetn)
            cap_count <= 15'd0;
        else if (start_go)
            cap_count <= 15'd0;
        else if (cap_wr)
            cap_count <= cap_count + 15'd1;
    end

    //==================================================
    // RAMs (4096 x 32 each)
    //==================================================
    bram_dp_be #(
        .ADDR_WIDTH(12),
        .NUM_BYTES(4),
        .INIT_FILE(INIT_FILE)
    ) input_ram (
        .clk(clk),
        .a_en(in_en),
        .a_we(m_we),
        .a_addr(word),
        .a_din(m_wdata),
        .a_dout(in_a_dout),
        .b_en(state == STREAM),
        .b_we(4'b0000),
        .b_addr(stream_addr[13:2]),
        .b_din(32'd0),
        .b_dout(in_b_dout)
    );

    bram_dp_be #(
        .ADDR_WIDTH(12),
        .NUM_BYTES(4),
        .INIT_FILE("")
    ) capture_ram (
        .clk(clk),
        .a_en(cap_en),
        .a_we(m_we),
        .a_addr(word),
        .a_din(m_wdata),
        .a_dout(cap_a_dout),
        .b_en(cap_wr),
        .b_we(4'b0001 << cap_count[1:0]),
        .b_addr(cap_count[13:2]),
        .b_din({4{cap_data}}),
        .b_dout()
    );

endmodule

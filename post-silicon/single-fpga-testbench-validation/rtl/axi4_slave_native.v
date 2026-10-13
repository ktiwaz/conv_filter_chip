// AXI4 (full) slave -> simple native memory bus.
//
// - One transaction in flight at a time; reads and writes are serialized
//   (writes win when AW and AR arrive together). Plenty for jtag_axi.
// - INCR and FIXED bursts up to 256 beats. WRAP is treated as INCR.
// - Native bus: m_en pulses for one cycle per beat. m_we != 0 is a write
//   (byte strobes), m_we == 0 is a read; read data is returned on m_rdata
//   with m_rvalid at any later cycle.
// - Responses are always OKAY.
module axi4_slave_native #(
    parameter ADDR_WIDTH = 18,
    parameter ID_WIDTH   = 1
) (
    input  wire                  aclk,
    input  wire                  aresetn,

    // Write address
    input  wire [ID_WIDTH-1:0]   s_axi_awid,
    input  wire [31:0]           s_axi_awaddr,
    input  wire [7:0]            s_axi_awlen,
    input  wire [2:0]            s_axi_awsize,
    input  wire [1:0]            s_axi_awburst,
    input  wire                  s_axi_awvalid,
    output wire                  s_axi_awready,
    // Write data
    input  wire [31:0]           s_axi_wdata,
    input  wire [3:0]            s_axi_wstrb,
    input  wire                  s_axi_wlast,
    input  wire                  s_axi_wvalid,
    output wire                  s_axi_wready,
    // Write response
    output reg  [ID_WIDTH-1:0]   s_axi_bid,
    output wire [1:0]            s_axi_bresp,
    output wire                  s_axi_bvalid,
    input  wire                  s_axi_bready,
    // Read address
    input  wire [ID_WIDTH-1:0]   s_axi_arid,
    input  wire [31:0]           s_axi_araddr,
    input  wire [7:0]            s_axi_arlen,
    input  wire [2:0]            s_axi_arsize,
    input  wire [1:0]            s_axi_arburst,
    input  wire                  s_axi_arvalid,
    output wire                  s_axi_arready,
    // Read data
    output reg  [ID_WIDTH-1:0]   s_axi_rid,
    output reg  [31:0]           s_axi_rdata,
    output wire [1:0]            s_axi_rresp,
    output wire                  s_axi_rlast,
    output wire                  s_axi_rvalid,
    input  wire                  s_axi_rready,

    // Native bus
    output wire                  m_en,
    output wire [3:0]            m_we,
    output wire [ADDR_WIDTH-1:0] m_addr,
    output wire [31:0]           m_wdata,
    input  wire [31:0]           m_rdata,
    input  wire                  m_rvalid
);

    localparam BURST_FIXED = 2'b00;

    localparam S_IDLE   = 3'd0,
               S_WDATA  = 3'd1,
               S_WRESP  = 3'd2,
               S_RISSUE = 3'd3,
               S_RWAIT  = 3'd4,
               S_RDATA  = 3'd5;

    reg [2:0]            state;
    reg [ADDR_WIDTH-1:0] addr;
    reg [7:0]            len;
    reg [7:0]            beat;
    reg [2:0]            size;
    reg                  fixed;

    wire [ADDR_WIDTH-1:0] addr_next = fixed ? addr : addr + ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << size);

    assign s_axi_awready = (state == S_IDLE);
    assign s_axi_arready = (state == S_IDLE) && !s_axi_awvalid;
    assign s_axi_wready  = (state == S_WDATA);
    assign s_axi_bvalid  = (state == S_WRESP);
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rvalid  = (state == S_RDATA);
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rlast   = (state == S_RDATA) && (beat == len);

    wire wbeat = s_axi_wvalid && s_axi_wready;

    assign m_en    = wbeat || (state == S_RISSUE);
    assign m_we    = wbeat ? s_axi_wstrb : 4'b0000;
    assign m_addr  = addr;
    assign m_wdata = s_axi_wdata;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state       <= S_IDLE;
            addr        <= {ADDR_WIDTH{1'b0}};
            len         <= 8'd0;
            beat        <= 8'd0;
            size        <= 3'd2;
            fixed       <= 1'b0;
            s_axi_bid   <= {ID_WIDTH{1'b0}};
            s_axi_rid   <= {ID_WIDTH{1'b0}};
            s_axi_rdata <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    beat <= 8'd0;
                    if (s_axi_awvalid) begin
                        addr      <= s_axi_awaddr[ADDR_WIDTH-1:0];
                        len       <= s_axi_awlen;
                        size      <= s_axi_awsize;
                        fixed     <= (s_axi_awburst == BURST_FIXED);
                        s_axi_bid <= s_axi_awid;
                        state     <= S_WDATA;
                    end else if (s_axi_arvalid) begin
                        addr      <= s_axi_araddr[ADDR_WIDTH-1:0];
                        len       <= s_axi_arlen;
                        size      <= s_axi_arsize;
                        fixed     <= (s_axi_arburst == BURST_FIXED);
                        s_axi_rid <= s_axi_arid;
                        state     <= S_RISSUE;
                    end
                end

                S_WDATA: begin
                    if (wbeat) begin
                        addr <= addr_next;
                        beat <= beat + 8'd1;
                        if (s_axi_wlast || beat == len)
                            state <= S_WRESP;
                    end
                end

                S_WRESP: begin
                    if (s_axi_bready)
                        state <= S_IDLE;
                end

                S_RISSUE: begin
                    state <= S_RWAIT;
                end

                S_RWAIT: begin
                    if (m_rvalid) begin
                        s_axi_rdata <= m_rdata;
                        state       <= S_RDATA;
                    end
                end

                S_RDATA: begin
                    if (s_axi_rready) begin
                        if (beat == len) begin
                            state <= S_IDLE;
                        end else begin
                            addr  <= addr_next;
                            beat  <= beat + 8'd1;
                            state <= S_RISSUE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

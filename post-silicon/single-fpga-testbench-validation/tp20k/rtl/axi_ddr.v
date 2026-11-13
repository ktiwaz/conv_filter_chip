// AXI4 slave (fabric clock) onto one ddr_arb port (DDR clock): the DDR3
// window of the debug bridge. One DDR3 access per 32-bit beat, crossed with a
// request/acknowledge toggle pair; plenty for a UART-driven bridge.
//
// Byte address bits [AW-1:0] select the DDR3 byte; a write beat becomes a
// burst write with only its strobed bytes enabled, a read beat a burst read
// returning the 32 bits at its address. INCR and FIXED bursts, responses OKAY.
module axi_ddr #(
    parameter AW = 27,                   // 128 MB
    parameter ID_WIDTH = 1
) (
    input  wire                clk,
    input  wire                aresetn,

    input  wire [ID_WIDTH-1:0] s_axi_awid,
    input  wire [31:0]         s_axi_awaddr,
    input  wire [7:0]          s_axi_awlen,
    input  wire [1:0]          s_axi_awburst,
    input  wire                s_axi_awvalid,
    output wire                s_axi_awready,
    input  wire [31:0]         s_axi_wdata,
    input  wire [3:0]          s_axi_wstrb,
    input  wire                s_axi_wlast,
    input  wire                s_axi_wvalid,
    output wire                s_axi_wready,
    output reg  [ID_WIDTH-1:0] s_axi_bid,
    output wire [1:0]          s_axi_bresp,
    output wire                s_axi_bvalid,
    input  wire                s_axi_bready,
    input  wire [ID_WIDTH-1:0] s_axi_arid,
    input  wire [31:0]         s_axi_araddr,
    input  wire [7:0]          s_axi_arlen,
    input  wire [1:0]          s_axi_arburst,
    input  wire                s_axi_arvalid,
    output wire                s_axi_arready,
    output reg  [ID_WIDTH-1:0] s_axi_rid,
    output reg  [31:0]         s_axi_rdata,
    output wire [1:0]          s_axi_rresp,
    output wire                s_axi_rlast,
    output wire                s_axi_rvalid,
    input  wire                s_axi_rready,

    // ddr_arb port (DDR clock)
    input  wire                dclk,
    input  wire                drst,
    output reg                 d_req,
    output reg                 d_we,
    output reg  [AW-5:0]       d_baddr,
    output wire [127:0]        d_wdata,         // from DDR-clock registers, stable while d_req
    output wire [15:0]         d_wbe,
    input  wire                d_gnt,
    input  wire                d_rvalid,
    input  wire [127:0]        d_rdata,
    output reg                 d_timeout        // sticky (DDR clock): a request was abandoned
);

    localparam S_IDLE = 3'd0, S_WDATA = 3'd1, S_WWAIT = 3'd2, S_WRESP = 3'd3,
               S_RREQ = 3'd4, S_RWAIT = 3'd5, S_RDATA = 3'd6;

    reg [2:0]    state;
    reg [AW-1:0] addr;
    reg [7:0]    len, beat;
    reg          fixed;

    // request held stable while the toggle is out
    reg          q_we;
    reg [AW-1:0] q_addr;
    reg [31:0]   q_data;
    reg [3:0]    q_strb;
    reg          req_t = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] ack_s = 3'b000;
    wire         acked = ack_s[2] != ack_s[1];
    reg  [31:0]  ack_data;               // from the DDR side, stable at the ack
    reg          ack_t = 1'b0;           // DDR side: flips when a request is done

    assign s_axi_awready = state == S_IDLE;
    assign s_axi_arready = state == S_IDLE && !s_axi_awvalid;
    assign s_axi_wready  = state == S_WDATA;
    assign s_axi_bvalid  = state == S_WRESP;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rvalid  = state == S_RDATA;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rlast   = s_axi_rvalid && beat == len;

    wire [AW-1:0] addr_next = fixed ? addr : addr + 4;

    always @(posedge clk) begin
        ack_s <= {ack_s[1:0], ack_t};
        if (!aresetn) begin
            state <= S_IDLE;            // the toggles are never reset: a reset
            beat  <= 8'd0;              // in one domain must not look like a request
        end else case (state)
            S_IDLE: begin
                beat <= 8'd0;
                if (s_axi_awvalid) begin
                    addr  <= s_axi_awaddr[AW-1:0];
                    len   <= s_axi_awlen;
                    fixed <= s_axi_awburst == 2'b00;
                    s_axi_bid <= s_axi_awid;
                    state <= S_WDATA;
                end else if (s_axi_arvalid) begin
                    addr  <= s_axi_araddr[AW-1:0];
                    len   <= s_axi_arlen;
                    fixed <= s_axi_arburst == 2'b00;
                    s_axi_rid <= s_axi_arid;
                    state <= S_RREQ;
                end
            end
            S_WDATA: if (s_axi_wvalid) begin
                q_we   <= 1'b1;
                q_addr <= addr;
                q_data <= s_axi_wdata;
                q_strb <= s_axi_wstrb;
                req_t  <= !req_t;
                state  <= S_WWAIT;
            end
            S_WWAIT: if (acked) begin
                addr <= addr_next;
                beat <= beat + 8'd1;
                state <= beat == len ? S_WRESP : S_WDATA;
            end
            S_WRESP: if (s_axi_bready) state <= S_IDLE;
            S_RREQ: begin
                q_we   <= 1'b0;
                q_addr <= addr;
                req_t  <= !req_t;
                state  <= S_RWAIT;
            end
            S_RWAIT: if (acked) begin
                s_axi_rdata <= ack_data;
                state <= S_RDATA;
            end
            S_RDATA: if (s_axi_rready) begin
                if (beat == len)
                    state <= S_IDLE;
                else begin
                    addr  <= addr_next;
                    beat  <= beat + 8'd1;
                    state <= S_RREQ;
                end
            end
            default: state <= S_IDLE;
        endcase
    end

    //==================================================
    // DDR clock side
    //
    // A write beat is a read-modify-write of its whole burst: read it, merge
    // the strobed bytes, write all 16 bytes back. Masked partial writes (DM)
    // are avoided: on the board, about one in 8000 of them put the next
    // beat's byte 0 into the low byte lane while other ports were writing
    // (not reproducible in simulation, so a DRAM-side timing effect); the
    // full-burst writes the video ports use have shown no errors.
    //==================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] req_s = 3'b000;
    wire new_req = req_s[2] != req_s[1];
    reg  busy, rmw_rd;                   // rmw_rd: the read half of a write beat
    reg  [20:0] wait_cnt;                // DDR cycles the current request has waited
    wire [3:0] lane = {q_addr[3:2], 2'b00};          // byte offset of the beat in the burst
    reg  [127:0] buf_w;                  // the burst being written
    assign d_wdata = buf_w;
    assign d_wbe   = 16'hFFFF;

    integer i;
    always @(posedge dclk) begin
        req_s <= {req_s[1:0], req_t};
        if (drst) begin
            d_req  <= 1'b0;
            busy   <= 1'b0;
            rmw_rd <= 1'b0;
            d_timeout <= 1'b0;
        end else begin
            // a request not served within 2^21 cycles (~22 ms) is abandoned,
            // so the bridge can't hang; d_timeout records it
            wait_cnt <= busy ? wait_cnt + 21'd1 : 21'd0;
            if (busy && d_req && wait_cnt == 21'h1FFFFF) begin
                d_req     <= 1'b0;
                d_timeout <= 1'b1;
                ack_data  <= 32'hDEADDEAD;
                ack_t     <= !ack_t;
                busy      <= 1'b0;
                rmw_rd    <= 1'b0;
            end
            if (new_req && !busy) begin
                // first a read in both cases (q_* are fabric-clock registers,
                // stable since the toggle)
                d_req   <= 1'b1;
                d_we    <= 1'b0;
                d_baddr <= q_addr[AW-1:4];
                rmw_rd  <= q_we;
                busy    <= 1'b1;
            end
            if (d_gnt) begin
                d_req <= 1'b0;
                if (d_we) begin              // the write half: done
                    ack_t <= !ack_t;
                    busy  <= 1'b0;
                end
            end
            if (d_rvalid) begin
                if (rmw_rd) begin
                    // merge the strobed bytes, then write the whole burst
                    for (i = 0; i < 16; i = i + 1)
                        buf_w[8 * i +: 8] <= (i >= lane && i < lane + 4 && q_strb[i - lane])
                                             ? q_data[8 * (i - lane) +: 8] : d_rdata[8 * i +: 8];
                    rmw_rd <= 1'b0;
                    d_we   <= 1'b1;
                    d_req  <= 1'b1;
                end else begin
                    ack_data <= d_rdata >> (8 * lane);
                    ack_t    <= !ack_t;
                    busy     <= 1'b0;
                end
            end
        end
    end

endmodule

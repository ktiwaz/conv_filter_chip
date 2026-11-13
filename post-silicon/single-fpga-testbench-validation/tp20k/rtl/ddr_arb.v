// DDR3 arbiter in front of gowin-ddr3's ddr3_ctrl (with the BL8 write patch),
// on the controller clock. Every access is one whole aligned burst: 8 words
// of 16 bits = 128 bits, addressed by its burst index (word address / 8).
//
// Ports 0..NP-1, fixed priority (port 0 first). A port holds req (and we,
// baddr, wdata, wbe) until gnt pulses; gnt comes in the cycle the access is
// issued, so the port drops req in the next cycle. A read then gets one
// rvalid pulse with the burst on rdata. Refresh comes before every port: one
// every REFRESH_CYC cycles (7.8 us), issued as soon as the controller is free.
//
// The controller takes a request whenever busy is low, and busy rises in the
// cycle after it (ddr3_ctrl), so one cycle after each issue is skipped.
// Write data and byte enables come straight from the issued port: it holds
// them until it has seen gnt, and the controller latches them with wr.
module ddr_arb #(
    parameter NP          = 4,
    parameter BA_W        = 23,          // burst address bits (26-bit word address)
    parameter REFRESH_CYC = 842          // 7.8 us at 108 MHz
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               ready,         // controller calibrated

    // ports
    input  wire [NP-1:0]      req,
    input  wire [NP-1:0]      we,
    input  wire [NP*BA_W-1:0] baddr,
    input  wire [NP*128-1:0]  wdata,
    input  wire [NP*16-1:0]   wbe,
    output reg  [NP-1:0]      gnt,
    output reg  [NP-1:0]      rvalid,
    output wire [127:0]       rdata,         // the controller's dout_burst (stable until the next read)

    // ddr3_ctrl user side
    output reg                c_rd,
    output reg                c_wr,
    output reg                c_refresh,
    output reg  [BA_W+2:0]    c_addr,
    output wire [127:0]       c_din_burst,   // from the issued port (held until its gnt)
    output wire [15:0]        c_be_burst,
    input  wire               c_busy,
    input  wire               c_data_ready,
    input  wire [127:0]       c_dout_burst,

    output reg  [31:0]        accesses       // issued reads and writes (debug)
);

    // Refresh timer
    reg [15:0] rtime;
    reg        rdue;
    always @(posedge clk) begin
        if (rst) begin
            rtime <= 16'd0;
            rdue  <= 1'b0;
        end else begin
            if (rtime == REFRESH_CYC - 1) begin
                rtime <= 16'd0;
                rdue  <= 1'b1;
            end else
                rtime <= rtime + 16'd1;
            if (c_refresh) rdue <= 1'b0;
        end
    end

    // Lowest requesting port
    reg [NP-1:0]  pick;
    reg           any;
    integer i;
    always @(*) begin
        pick = {NP{1'b0}};
        any  = 1'b0;
        for (i = NP - 1; i >= 0; i = i - 1)
            if (req[i]) begin
                pick = {NP{1'b0}};
                pick[i] = 1'b1;
                any = 1'b1;
            end
    end

    integer k;
    reg [BA_W-1:0] p_baddr;
    reg            p_we;
    always @(*) begin
        p_baddr = {BA_W{1'b0}};
        p_we    = 1'b0;
        for (k = 0; k < NP; k = k + 1)
            if (pick[k]) begin
                p_baddr = baddr[k*BA_W +: BA_W];
                p_we    = we[k];
            end
    end

    // dout_burst is a register in ddr3_ctrl that only changes when the next
    // read completes, at least ~20 cycles later: rdata needs no copy
    assign rdata = c_dout_burst;

    wire idle = ready && !c_busy && !c_rd && !c_wr && !c_refresh;
    reg [NP-1:0] owner;                  // port of the read in flight
    reg [NP-1:0] issued;                 // port of the access being issued

    reg [127:0] i_wdata;
    reg [15:0]  i_wbe;
    integer j;
    always @(*) begin
        i_wdata = 128'd0;
        i_wbe   = 16'd0;
        for (j = 0; j < NP; j = j + 1)
            if (issued[j]) begin
                i_wdata = wdata[j*128 +: 128];
                i_wbe   = wbe[j*16 +: 16];
            end
    end
    assign c_din_burst = i_wdata;
    assign c_be_burst  = i_wbe;

    always @(posedge clk) begin
        c_rd      <= 1'b0;
        c_wr      <= 1'b0;
        c_refresh <= 1'b0;
        gnt       <= {NP{1'b0}};
        rvalid    <= {NP{1'b0}};
        if (rst) begin
            owner    <= {NP{1'b0}};
            issued   <= {NP{1'b0}};
            accesses <= 32'd0;
        end else begin
            if (idle) begin
                if (rdue)
                    c_refresh <= 1'b1;
                else if (any) begin
                    c_rd        <= !p_we;
                    c_wr        <= p_we;
                    c_addr      <= {p_baddr, 3'b000};
                    issued      <= pick;
                    gnt         <= pick;
                    accesses    <= accesses + 32'd1;
                    if (!p_we) owner <= pick;
                end
            end
            if (c_data_ready)
                rvalid <= owner;
        end
    end

endmodule

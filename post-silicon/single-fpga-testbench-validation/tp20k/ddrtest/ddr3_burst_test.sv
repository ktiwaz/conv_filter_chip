`ifndef module_ddr3_burst_test
`define module_ddr3_burst_test

`include "uart_tx.sv"

// DDR3 burst memory test and throughput measurement, for ddr3_ctrl with the
// BL8 burst-write patch (tp20k/ddr3/ddr3_ctrl.patch). After the
// calibration, forever: write BURSTS whole bursts (8 words each) from address
// 0, read them back as bursts and compare all 8 words. Refreshes every 7.8 us
// in between, as a real client would. uart_tx (8N1, BAUD) reports:
//   calib ok   delays 1b 1b
//   pass 0001 errors 00000000 wr 0003a2f1 rd 0003b0c4
// wr / rd are the clock cycles each phase took (hex), so the throughput is
// BURSTS * 8 * DQ_W/8 bytes / (cycles / SYS_FREQ).
module ddr3_burst_test #(
    parameter DQ_W     = 16,
    parameter ADDR_W   = 26,
    parameter DW       = 3,
    parameter SYS_FREQ = 108_000_000,
    parameter BURSTS   = 1 << 17,       // 2 MB with DQ_W = 16
    parameter BAUD     = 115_200,
    parameter MASKED   = 0              // 1: write each burst as 4 masked writes of one word pair
) (
    input                      clk,
    input                      rst,
    input                      calib_done,
    input                      calib_fail,
    input  [DQ_W/8*DW-1:0]     rd_delay,

    output reg                 rd,
    output reg                 wr,
    output reg                 refresh,
    output reg    [ADDR_W-1:0] addr,
    output reg   [8*DQ_W-1:0]  din_burst,
    output reg   [8*DQ_W/8-1:0] be_burst,
    input        [8*DQ_W-1:0]  dout_burst,
    input                      data_ready,
    input                      busy,

    output                     led,
    output                     uart_tx
);

localparam LANES = DQ_W / 8;

initial begin
    rd = 0; wr = 0; refresh = 0; addr = 0; din_burst = 0; be_burst = '1;
end

function automatic [DQ_W-1:0] pattern(input [ADDR_W-1:0] a, input [15:0] p);
    logic [31:0] x;
    x = 32'(a) ^ {p, 16'h0};
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    pattern = DQ_W'(x);
endfunction

reg [15:0] pass;
// the 8 words of the burst at addr, a cycle late (moved holds back meanwhile)
reg [8*DQ_W-1:0] want;
reg moved;
always @(posedge clk)
    for (int j = 0; j < 8; j++) want[DQ_W*j +: DQ_W] <= pattern(addr + ADDR_W'(j), pass);

// a refresh every 7.8 us
localparam REFRESH_COUNT = SYS_FREQ / 1000 * 78 / 10000;
reg [15:0] refresh_time;
reg refresh_due;
initial begin refresh_time = 0; refresh_due = 0; end
always @(posedge clk) begin
    if (refresh_time == 16'(REFRESH_COUNT - 1)) begin
        refresh_time <= 0;
        refresh_due <= 1;
    end else
        refresh_time <= refresh_time + 1'd1;
    if (refresh) refresh_due <= 0;
end

localparam [2:0] S_CALIB = 0, S_WRITE = 1, S_WRITE_NEXT = 2, S_READ = 3, S_READ_WAIT = 4, S_FAILED = 5;
localparam [ADDR_W-1:0] LAST = ADDR_W'((BURSTS - 1) * 8);
reg [2:0] state;
reg [1:0] pair;                          // MASKED: word pair being written
reg error, toggle;
reg [31:0] errors, wr_cyc, rd_cyc;
reg [15:0] rep_pass;
reg [31:0] rep_errors, rep_wr, rep_rd;
reg say_calib, say_pass;
reg chk, chk_bad, chk_last;
initial begin
    state = S_CALIB; pass = 0; error = 0; toggle = 0; moved = 0;
    errors = 0; wr_cyc = 0; rd_cyc = 0;
    rep_pass = 0; rep_errors = 0; rep_wr = 0; rep_rd = 0;
    say_calib = 0; say_pass = 0; chk = 0; chk_bad = 0; chk_last = 0;
    want = 0;
end

assign led = error || calib_fail || toggle;
wire idle = !busy && !rd && !wr && !refresh;

always @(posedge clk) begin
    rd <= 0;
    wr <= 0;
    refresh <= 0;
    moved <= 0;
    chk <= 0;
    say_calib <= 0;
    if (rst) begin
        state <= S_CALIB;
    end else begin
        if (state == S_WRITE || state == S_WRITE_NEXT) wr_cyc <= wr_cyc + 1'd1;
        if (state == S_READ || state == S_READ_WAIT) rd_cyc <= rd_cyc + 1'd1;
        case (state)
            S_CALIB: if (calib_done) begin
                addr <= 0;
                pair <= 0;
                moved <= 1;
                say_calib <= 1;
                wr_cyc <= 0;
                state <= calib_fail ? S_FAILED : S_WRITE;
            end
            S_WRITE: if (idle && !moved) begin
                if (refresh_due) refresh <= 1;
                else begin
                    wr <= 1;
                    // MASKED: the other words carry garbage that must not land
                    din_burst <= MASKED ? (want ^ ~({{(8*DQ_W-2*DQ_W){1'b0}}, {(2*DQ_W){1'b1}}} << (2*DQ_W*pair))) : want;
                    be_burst  <= MASKED ? {{(8*DQ_W/8-4){1'b0}}, 4'hF} << (4*pair) : '1;
                    state <= S_WRITE_NEXT;
                end
            end
            S_WRITE_NEXT: begin
                moved <= 1;
                state <= S_WRITE;
                pair  <= pair + 1'd1;
                if (MASKED && pair != 2'd3) begin
                    // same burst, next word pair
                end else if (addr != LAST)
                    addr <= addr + ADDR_W'(8);
                if ((!MASKED || pair == 2'd3) && addr == LAST) begin
                    addr <= 0;
                    rd_cyc <= 0;
                    state <= S_READ;
                end
            end
            S_READ: if (idle && !moved) begin
                if (refresh_due) refresh <= 1;
                else begin
                    rd <= 1;
                    state <= S_READ_WAIT;
                end
            end
            S_READ_WAIT: if (data_ready) begin
                chk <= 1;
                chk_bad <= dout_burst != want;
                chk_last <= addr == LAST;
                addr <= addr + ADDR_W'(8);
                moved <= 1;
                state <= S_READ;
                if (addr == LAST) begin
                    addr <= 0;
                    pass <= pass + 1'd1;
                    toggle <= !toggle;
                    rep_wr <= wr_cyc;
                    rep_rd <= rd_cyc;
                    wr_cyc <= 0;
                    state <= S_WRITE;
                end
            end
            S_FAILED: ;
            default: state <= S_CALIB;
        endcase
    end
end

always @(posedge clk) begin
    say_pass <= 0;
    if (rst) begin
        error <= 0;
        errors <= 0;
    end else if (chk) begin
        if (chk_bad) begin
            error <= 1;
        end
        if (chk_last) begin
            rep_pass <= pass;
            rep_errors <= errors + 32'(chk_bad);
            errors <= 0;
            say_pass <= 1;
        end else if (chk_bad)
            errors <= errors + 1'd1;
    end
end

// report lines
function automatic [7:0] hexc(input [3:0] n);
    hexc = n < 4'd10 ? 8'd48 + 8'(n) : 8'd87 + 8'(n);
endfunction
function automatic [63:0] hex32(input [31:0] v);
    for (int i = 0; i < 8; i++) hex32[8*i +: 8] = hexc(v[4*i +: 4]);
endfunction

localparam CALIB_LEN = 17 + 3 * LANES + 2, PASS_LEN = 5 + 4 + 8 + 8 + 4 + 8 + 4 + 8 + 2;
localparam LINE_MAX = CALIB_LEN > PASS_LEN ? CALIB_LEN : PASS_LEN;
localparam [15:0] CRLF = 16'h0d0a;

wire [24*LANES-1:0] delays;
for (genvar l = 0; l < LANES; l++) begin : g_delay
    wire [63:0] h = hex32(32'(rd_delay[l*DW +: DW]));
    assign delays[24*(LANES-1-l) +: 24] = {" ", h[15:0]};
end
wire [8*CALIB_LEN-1:0] calib_line = {calib_fail ? "calib FAIL delays" : "calib ok   delays", delays, CRLF};
wire [63:0] h_pass = hex32(32'(rep_pass));
wire [8*PASS_LEN-1:0] pass_line = {"pass ", h_pass[31:0], " errors ", hex32(rep_errors),
                                   " wr ", hex32(rep_wr), " rd ", hex32(rep_rd), CRLF};

reg [8*LINE_MAX-1:0] line;
reg [$clog2(LINE_MAX+1)-1:0] line_len;
initial begin line = 0; line_len = 0; end
wire tx_ready;

always @(posedge clk) begin
    if (say_calib && line_len == 0) begin
        line <= (8*LINE_MAX)'(calib_line) << 8 * (LINE_MAX - CALIB_LEN);
        line_len <= CALIB_LEN[$bits(line_len)-1:0];
    end else if (say_pass && line_len == 0) begin
        line <= (8*LINE_MAX)'(pass_line) << 8 * (LINE_MAX - PASS_LEN);
        line_len <= PASS_LEN[$bits(line_len)-1:0];
    end else if (line_len != 0 && tx_ready) begin
        line <= line << 8;
        line_len <= line_len - 1'd1;
    end
end

uart_tx #(.CLK_FREQ(SYS_FREQ), .BAUD(BAUD)) uart(
    .clk(clk), .data(line[8*LINE_MAX-1 -: 8]), .valid(line_len != 0), .ready(tx_ready), .tx(uart_tx)
);

endmodule

`endif /* module_ddr3_burst_test */

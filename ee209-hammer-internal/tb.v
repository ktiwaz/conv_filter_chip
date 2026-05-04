module tb;

reg  [3:0] A, B;
reg clk, rst;
wire [7:0] out;

top top1 (
    .clk(clk),
    .rst(rst),
    .a(A),
    .b(B),
    .out(out)
);

// simple free-running clock
initial begin
    clk = 0;
    forever #5 clk = ~clk;
end

initial begin
    // initialize
    rst = 1'b1;
    A   = 4'd0;
    B   = 4'd0;

    // hold reset through one rising edge
    @(posedge clk);
    @(posedge clk);
    rst = 1'b0;

    // test 1: 3 * 2
    A = 4'd3;
    B = 4'd2;
    @(posedge clk);  // inputs captured into a_buf, b_buf
    @(posedge clk);  // product captured into out_buf
    $display("time=%0t A=%0d B=%0d out=%0d", $time, A, B, out);

    // test 2: 5 * 4
    A = 4'd5;
    B = 4'd4;
    @(posedge clk);
    @(posedge clk);
    $display("time=%0t A=%0d B=%0d out=%0d", $time, A, B, out);

    $finish;
end

endmodule

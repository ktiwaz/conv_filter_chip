module top (
    input clk,
    input rst,
    input [3:0] a, 
    input [3:0] b,
    output [7:0] out
);

reg [3:0] a_buf, b_buf;
reg [7:0] out_buf;
assign out = out_buf;

always @(posedge clk) begin
    if (rst) begin
        a_buf <= '0;
        b_buf <= '0;
        out_buf <= '0;
    end else begin
        a_buf <= a;
        b_buf <= b;
        out_buf <= a_buf * b_buf;
    end

end

endmodule

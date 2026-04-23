module window_dot_product #(
    parameter int NUMBER_OF_LINES = 3,
    parameter int DATA_WIDTH      = 8,
    parameter int KERNEL_WIDTH    = 8,
    parameter ACC_WIDTH = DATA_WIDTH + KERNEL_WIDTH + $clog2(NUMBER_OF_LINES * NUMBER_OF_LINES) + 1
)(
    input  logic clk,
    input  logic rst_n,
    input  logic input_valid,

    input  logic [DATA_WIDTH-1:0]          window [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1],
    input  logic signed [KERNEL_WIDTH-1:0] kernel [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1],

    output logic output_valid,
    output logic signed [ACC_WIDTH-1:0] dot_product
);

generate
    if (NUMBER_OF_LINES == 5) begin : GEN_5x5
        window_dot_product_5x5 #(
            .DATA_WIDTH(DATA_WIDTH),
            .KERNEL_WIDTH(KERNEL_WIDTH)
        ) u_dot (
            .clk(clk),
            .rst_n(rst_n),
            .input_valid(input_valid),
            .window(window),
            .kernel(kernel),
            .output_valid(output_valid),
            .dot_product(dot_product)
        );
    end else begin : GEN_GENERIC
        window_dot_product_generic #(
            .NUMBER_OF_LINES(NUMBER_OF_LINES),
            .DATA_WIDTH(DATA_WIDTH),
            .KERNEL_WIDTH(KERNEL_WIDTH)
        ) u_dot (
            .clk(clk),
            .rst_n(rst_n),
            .input_valid(input_valid),
            .window(window),
            .kernel(kernel),
            .output_valid(output_valid),
            .dot_product(dot_product)
        );
    end
endgenerate

endmodule
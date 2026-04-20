//==============================================================================
// Module Name : window_dot_product
// Author      : Kushagra Tiwari
// Date        : 2026-04-06
//
// Description :
//   This module performs the dot product between the kernel and the sliding window data output. 
//   Currently, the multiplication and addition in this module is intentionally left unpipelined. 
//   This was done to allow us to run a test synthesis and P&R quickly
//   Pipelining can be added easily in the future to improve performance. 
//
// Parameters :
//   NUMBER_OF_LINES : Window dimension (N for an NxN window)
//   LINE_WIDTH      : Number of values in one line
//   DATA_WIDTH      : Bit width of one data element
//   KERNEL_WIDTH    : Bit width of one kernel element
//
// Revision History :
//   2026-04-12 : Create module
//
// TODO: Add pipelining first to the reduction add operation, and then to the parallel multiplies (as needed by timing)
//
////==============================================================================

module window_dot_product #(
    parameter int NUMBER_OF_LINES = 3,
    parameter int DATA_WIDTH      = 8,
    parameter int KERNEL_WIDTH    = 8,
       // Width of accumulator
    parameter ACC_WIDTH = DATA_WIDTH + KERNEL_WIDTH + $clog2(NUMBER_OF_LINES * NUMBER_OF_LINES)
)(
    input  logic clk,
    input  logic rst_n,
    input  logic input_valid,
    input  logic [DATA_WIDTH-1:0]          window [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1],
    input  logic signed [KERNEL_WIDTH-1:0] kernel [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1],

    output logic output_valid,
    output logic signed [ACC_WIDTH-1:0] dot_product
);

    integer row, col;
    logic signed [ACC_WIDTH-1:0] sum;

    always_comb begin
        sum = '0;
        for (row = 0; row < NUMBER_OF_LINES; row = row + 1) begin
            for (col = 0; col < NUMBER_OF_LINES; col = col + 1) begin
                sum = sum + (window[row][col] * kernel[row][col]);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dot_product <= '0;
            output_valid <= 0;
        end else begin
            dot_product <= sum;
            output_valid <= input_valid;
        end
    end

endmodule
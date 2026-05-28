//==============================================================================
// Module Name : convolution_core
// Author      : Kushagra Tiwari
// Date        : 2026-04-13
//
// Description :
//   Top-level convolution core that performs the following stages:
//     1. Builds an NxN sliding window from a streamed input
//     2. Computes the dot product of the window and kernel
//     3. Applies absolute value, normalization, and output clamping
//
//   The sliding window output becomes valid once the internal history has been
//   filled. The dot product stage is registered. The normalization/clamp stage
//   is also registered.
//
//   Overall latency after the sliding window saturates:
//     - 1 cycle through window_dot_product
//     - 1 cycle through normalize_clamp
//
// Parameters :
//   NUMBER_OF_LINES     : Window dimension (N for an NxN convolution)
//   LINE_WIDTH          : Number of pixels in one image row
//   PIXEL_WIDTH         : Bit width of one input/output pixel
//   NORMALIZATION_WIDTH : Bit width of normalization factor, Q1.(W-1)
//
// Revision History :
//   2026-04-13 : Create module
//
//==============================================================================
module convolution_core #(
    parameter int NUMBER_OF_LINES     = 3,
    parameter int LINE_WIDTH          = 128,
    parameter int PIXEL_WIDTH         = 8,
    parameter int NORMALIZATION_WIDTH = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic input_valid,
    input  logic [PIXEL_WIDTH-1:0] datain,
    input logic test_mode,

    input  logic signed [PIXEL_WIDTH-1:0] kernel [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1],
    input  logic [NORMALIZATION_WIDTH-1:0] normalization_factor,

    output logic output_valid,
    output logic [PIXEL_WIDTH-1:0] dataout
);

    localparam int ACC_WIDTH = PIXEL_WIDTH + PIXEL_WIDTH + $clog2(NUMBER_OF_LINES * NUMBER_OF_LINES) + 1;

    //--------------------------------------------------------------------------
    // Internal signals
    //--------------------------------------------------------------------------

    logic [PIXEL_WIDTH-1:0] window [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1];
    logic window_output_valid;

    logic signed [ACC_WIDTH-1:0] dot_product;
    logic dot_product_output_valid;

    logic [PIXEL_WIDTH-1:0] dataout_test;
    assign dataout_test = window[NUMBER_OF_LINES-1][NUMBER_OF_LINES-1];
    logic dataout_test_valid;
    assign dataout_test_valid = window_output_valid;

    logic [PIXEL_WIDTH-1:0] dataout_final;
    logic dataout_final_valid;

    assign dataout = test_mode ? dataout_test : dataout_final;
    assign output_valid = test_mode ? dataout_test_valid : dataout_final_valid;

    //--------------------------------------------------------------------------
    // Sliding window stage
    //--------------------------------------------------------------------------

    sliding_window #(
        .NUMBER_OF_LINES(NUMBER_OF_LINES),
        .LINE_WIDTH(LINE_WIDTH),
        .DATA_DEPTH(PIXEL_WIDTH)
    ) sliding_window_inst (
        .clk(clk),
        .rst_n(rst_n),
        .input_valid(input_valid),
        .datain(datain),
        .dataout(window),
        .output_valid(window_output_valid)
    );

    //--------------------------------------------------------------------------
    // Dot product stage
    //--------------------------------------------------------------------------

    window_dot_product #(
        .NUMBER_OF_LINES(NUMBER_OF_LINES),
        .DATA_WIDTH(PIXEL_WIDTH),
        .KERNEL_WIDTH(PIXEL_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) window_dot_product_inst (
        .clk(clk),
        .rst_n(rst_n),
        .input_valid(window_output_valid),
        .window(window),
        .kernel(kernel),
        .output_valid(dot_product_output_valid),
        .dot_product(dot_product)
    );

    //--------------------------------------------------------------------------
    // Normalize / clamp stage
    //--------------------------------------------------------------------------

    normalize_clamp #(
        .INPUT_WIDTH(ACC_WIDTH),
        .NORMALIZATION_WIDTH(NORMALIZATION_WIDTH),
        .OUTPUT_WIDTH(PIXEL_WIDTH)
    ) normalize_clamp_inst (
        .clk(clk),
        .rst_n(rst_n),
        .input_valid(dot_product_output_valid),
        .datain(dot_product),
        .normalization_factor(normalization_factor),
        .output_valid(dataout_final_valid),
        .dataout(dataout_final)
    );

endmodule
//==============================================================================
// Module Name : normalize_clamp
// Author      : Kushagra Tiwari
// Date        : 2026-04-12
//
// Description :
//   This module accepts a wide dot product input, and performs the following steps:
//      - Takes the absolute value (i.e. converts negative to positive)
//      - Multiplies by a normalization factor represented as Q1.X where X is (NORMALIZATION_WIDTH - 1)
//      - Shifts right by NORMALIZATION_WIDTH - 1 to get the final normalized value
//      - Truncates the output (no rounding implemented)
//      - Clamps the output to fit in the output data width. This is done to support non-normalized kernels like edge-detect
//
//   All these operations are currently performed in one cycle. However, it is simple to pipeline this module in the future by performing
//   one step per clock cycle. 
//
// Parameters :
//   INPUT_WIDTH         : Bit width of dot product
//   NORMALIZATION_WIDTH : Bit width of normalization factor, represented as Q1.(NORMALIZATION_WIDTH - 1)
//   OUTPUT_WIDTH        : Bit width of output
//
// Revision History :
//   2026-04-12 : Create module
//
// TODO: Add pipelining if needed by timing. Add rounding if we want extra precision (not very useful)
//
////==============================================================================
module normalize_clamp #(
    parameter int INPUT_WIDTH         = 20,
    parameter int NORMALIZATION_WIDTH = 8,
    parameter int OUTPUT_WIDTH        = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic input_valid,

    input  logic signed [INPUT_WIDTH-1:0] datain,
    input  logic [NORMALIZATION_WIDTH-1:0] normalization_factor,

    output logic output_valid,
    output logic [OUTPUT_WIDTH-1:0] dataout
);

    localparam int NORMALIZATION_SHIFT = NORMALIZATION_WIDTH - 1;
    localparam int MULT_WIDTH          = INPUT_WIDTH + NORMALIZATION_WIDTH;

    // Max output for clamp
    localparam logic [OUTPUT_WIDTH-1:0] OUTPUT_MAX = {OUTPUT_WIDTH{1'b1}};

    logic [INPUT_WIDTH-1:0]  abs_value;      // unsigned from this point
    logic [MULT_WIDTH-1:0]   normalized_mult;
    logic [MULT_WIDTH-1:0]   normalized_shifted;
    logic [OUTPUT_WIDTH-1:0] clamped_output;

    always_comb begin
        // Absolute value as unsigned magnitude (2's complement)
        if (datain[INPUT_WIDTH-1]) begin
            abs_value = ~datain + 1'b1;
        end else begin
            abs_value = datain;
        end

        // Fixed-point normalization multiply
        normalized_mult = abs_value * normalization_factor;

        // Convert back from Q1.(NORMALIZATION_WIDTH-1)
        normalized_shifted = normalized_mult >> NORMALIZATION_SHIFT;

        // Clamp on input valid
        if (normalized_shifted > MULT_WIDTH'(OUTPUT_MAX)) begin
            clamped_output = OUTPUT_MAX;
        end else begin
            clamped_output = normalized_shifted[OUTPUT_WIDTH-1:0];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dataout       <= '0;
            output_valid  <= 1'b0;
        end else begin
            dataout      <= clamped_output;
            output_valid <= input_valid;
        end
    end

endmodule
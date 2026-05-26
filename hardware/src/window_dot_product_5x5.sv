//==============================================================================
// Module Name : window_dot_product_5x5
// Author      : Kushagra Tiwari
//
// Description :
//   Pipelined 5x5 dot product.
//   Stage 0: 25 parallel multiplies
//   Stage 1: 13 partial sums
//   Stage 2: 7 partial sums
//   Stage 3: 4 partial sums
//   Stage 4: 2 partial sums
//   Stage 5: 1 final sum
//
//   Total latency: 6 cycles from input_valid to output_valid
//
//==============================================================================

module window_dot_product_5x5 #(
    parameter int DATA_WIDTH   = 8,
    parameter int KERNEL_WIDTH = 8,
    parameter int ACC_WIDTH    = DATA_WIDTH + KERNEL_WIDTH + $clog2(25) + 1
)(
    input  logic clk,
    input  logic rst_n,
    input  logic input_valid,

    input  logic [DATA_WIDTH-1:0]          window [0:4][0:4],
    input  logic signed [KERNEL_WIDTH-1:0] kernel [0:4][0:4],

    output logic output_valid,
    output logic signed [ACC_WIDTH-1:0] dot_product
);

    localparam int NUM_TAPS = 25;

    //--------------------------------------------------------------------------
    // Pipeline storage
    //--------------------------------------------------------------------------

    logic signed [ACC_WIDTH-1:0] prod [0:24];
    logic signed [ACC_WIDTH-1:0] sum1 [0:12];
    logic signed [ACC_WIDTH-1:0] sum2 [0:6];
    logic signed [ACC_WIDTH-1:0] sum3 [0:3];
    logic signed [ACC_WIDTH-1:0] sum4 [0:1];
    logic signed [ACC_WIDTH-1:0] sum5 [0:0];

    logic valid_pipe [0:5];

    integer i;
    integer row, col;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            //------------------------------------------------------------------
            // Reset data pipeline
            //------------------------------------------------------------------
            for (i = 0; i < 25; i = i + 1) begin
                prod[i] <= '0;
            end

            for (i = 0; i < 13; i = i + 1) begin
                sum1[i] <= '0;
            end

            for (i = 0; i < 7; i = i + 1) begin
                sum2[i] <= '0;
            end

            for (i = 0; i < 4; i = i + 1) begin
                sum3[i] <= '0;
            end

            for (i = 0; i < 2; i = i + 1) begin
                sum4[i] <= '0;
            end

            sum5[0] <= '0;

            //------------------------------------------------------------------
            // Reset valid pipeline
            //------------------------------------------------------------------
            for (i = 0; i < 6; i = i + 1) begin
                valid_pipe[i] <= 1'b0;
            end

            //------------------------------------------------------------------
            // Reset outputs
            //------------------------------------------------------------------
            dot_product  <= '0;
            output_valid <= 1'b0;
        end else begin
            //------------------------------------------------------------------
            // Valid pipeline
            //------------------------------------------------------------------
            valid_pipe[0] <= input_valid;
            for (i = 1; i < 6; i = i + 1) begin
                valid_pipe[i] <= valid_pipe[i-1];
            end

            //------------------------------------------------------------------
            // Stage 0: 25 multiplies
            //------------------------------------------------------------------
            for (row = 0; row < 5; row = row + 1) begin
                for (col = 0; col < 5; col = col + 1) begin
                    prod[row*5 + col] <=
                        $signed({1'b0, window[row][col]}) * $signed(kernel[row][col]);
                end
            end

            //------------------------------------------------------------------
            // Stage 1: 25 -> 13
            //------------------------------------------------------------------
            for (i = 0; i < 12; i = i + 1) begin
                sum1[i] <= prod[2*i] + prod[2*i + 1];
            end
            sum1[12] <= prod[24];

            //------------------------------------------------------------------
            // Stage 2: 13 -> 7
            //------------------------------------------------------------------
            for (i = 0; i < 6; i = i + 1) begin
                sum2[i] <= sum1[2*i] + sum1[2*i + 1];
            end
            sum2[6] <= sum1[12];

            //------------------------------------------------------------------
            // Stage 3: 7 -> 4
            //------------------------------------------------------------------
            for (i = 0; i < 3; i = i + 1) begin
                sum3[i] <= sum2[2*i] + sum2[2*i + 1];
            end
            sum3[3] <= sum2[6];

            //------------------------------------------------------------------
            // Stage 4: 4 -> 2
            //------------------------------------------------------------------
            for (i = 0; i < 2; i = i + 1) begin
                sum4[i] <= sum3[2*i] + sum3[2*i + 1];
            end

            //------------------------------------------------------------------
            // Stage 5: 2 -> 1
            //------------------------------------------------------------------
            sum5[0] <= sum4[0] + sum4[1];

            //------------------------------------------------------------------
            // Outputs
            //------------------------------------------------------------------
            dot_product  <= sum5[0];
            output_valid <= valid_pipe[5];
        end
    end

endmodule
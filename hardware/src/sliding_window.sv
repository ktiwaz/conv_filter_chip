//==============================================================================
// Module Name : sliding_window
// Author      : Kushagra Tiwari
// Date        : 2026-04-06
//
// Description :
//   This module accepts a datain value on every clock cycle (if input_valid is high).
//   Once enough data has been received, it can output a
//   NUMBER_OF_LINES x NUMBER_OF_LINES sliding window. The output_valid signal will be high.
//   On reset, the internal counter for the output_valid will be set to 0, requiring the
//   buffer to be filled again for the output to become valid. 
//
//   Storage used:
//     (NUMBER_OF_LINES - 1) * LINE_WIDTH + NUMBER_OF_LINES
//
//   This corresponds to:
//     - NUMBER_OF_LINES-1 full previous lines
//     - NUMBER_OF_LINES samples from the current line
//
// Parameters :
//   NUMBER_OF_LINES : Window dimension (N for an NxN window)
//   LINE_WIDTH      : Number of values in one line
//   DATA_DEPTH      : Bit width of one data element
//
// Revision History :
//   2026-04-06 : Create module (reused from previous project)
//   2026-04-07 : Add description, improve comments, rename some signals to be more descriptive
//   2026-04-12 : Optimize buffer size
//   2026-04-20 : Stall output_valid when input_valid stalls
//
////==============================================================================

module sliding_window #(
    parameter int NUMBER_OF_LINES = 3,
    parameter int LINE_WIDTH      = 640,
    parameter int DATA_DEPTH      = 25
)(
    input  logic clk,
    input  logic rst_n,
    input  logic input_valid,
    input  logic [DATA_DEPTH-1:0] datain,

    // dataout[row][col]
    // row 0 = top row of window
    // col 0 = left column of window
    output logic [DATA_DEPTH-1:0] dataout [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1],
    output logic output_valid
);

    // Minimum required storage:
    //   (N-1) full previous lines + N current-line samples
    localparam int BUFFER_SIZE = (NUMBER_OF_LINES - 1) * LINE_WIDTH + NUMBER_OF_LINES;

    // Counter size for valid values
    localparam int COUNTER_WIDTH = $clog2(BUFFER_SIZE + 1);

    // Newest sample is stored at line_buffer[0]
    logic [DATA_DEPTH-1:0] line_buffer [0:BUFFER_SIZE-1];

    // Counter for valid values
    logic [COUNTER_WIDTH-1:0] valid_count;

    // Parameter checks
    initial begin
        if (NUMBER_OF_LINES < 1) $error("NUMBER_OF_LINES must be >= 1");
        if (LINE_WIDTH < NUMBER_OF_LINES) $error("LINE_WIDTH must be >= NUMBER_OF_LINES");
        if (DATA_DEPTH < 1) $error("DATA_DEPTH must be >= 1");
    end

    integer i;

    // Shift register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_count <= '0;
        end else begin
            if (input_valid) begin

                // Shift existing data
                for (i = BUFFER_SIZE-1; i > 0; i = i - 1) begin
                    line_buffer[i] <= line_buffer[i-1];
                end
                
                // Add new data to beginning
                line_buffer[0] <= datain;

                if (valid_count < COUNTER_WIDTH'(BUFFER_SIZE)) begin
                    valid_count <= valid_count + 1'b1;
                end
            end
        end
    end


    // Window extraction
    //
    // With newest sample at line_buffer[0]:
    //   bottom-right of window = line_buffer[0]
    //   bottom-left            = line_buffer[NUMBER_OF_LINES-1]
    //   top-right              = line_buffer[(NUMBER_OF_LINES-1)*LINE_WIDTH]
    //   top-left               = line_buffer[(NUMBER_OF_LINES-1)*LINE_WIDTH + (NUMBER_OF_LINES-1)]
    //
    // Mapping:
    //   dataout[row][col] = sample at:
    //     ((NUMBER_OF_LINES-1 - row) * LINE_WIDTH) + (NUMBER_OF_LINES-1 - col)
    //
    integer row, col;

    always_comb begin
        for (row = 0; row < NUMBER_OF_LINES; row = row + 1) begin
            for (col = 0; col < NUMBER_OF_LINES; col = col + 1) begin
                dataout[row][col] =
                    line_buffer[((NUMBER_OF_LINES - 1 - row) * LINE_WIDTH) +
                                (NUMBER_OF_LINES - 1 - col)];
            end
        end
    end

    // Output valid -> Stall when input stalls
    assign output_valid = input_valid && (valid_count == COUNTER_WIDTH'(BUFFER_SIZE));

endmodule

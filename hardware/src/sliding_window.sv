//==============================================================================
// Module Name : sliding_window
// Author      : Kushagra Tiwari
// Date        : 2026-04-06
//
// Description :
//   This module accepts a datain value on every clock cycle (if enable is high).
//   When the line buffer of size NUMBER_OF_LINES is full, it outputs a NUMBER_OF_LINESxNUMBER_OF_LINES
//   sliding window of values every clock cycle. 
//
//
// Parameters :
//   NUMBER_OF_LINES : Number of lines to buffer. This should be the same as the dimension of the convolutional kernel.
//   LINE_WIDTH      : How many values are in a line. For example, a line in an image may be 640 pixels wide. 
//   DATA_DEPTH      : How many bits are in a single element of the data. For example. a pixel may be 8 bits deep. 
//
// Revision History :
//   2026-04-06 : Create module (reused from previous project)
//   2026-04-07 : Add description, improve comments, rename some signals to be more descriptive
//
//==============================================================================

module sliding_window #(parameter NUMBER_OF_LINES = 3, 
                        parameter LINE_WIDTH = 640, 
                        parameter DATA_DEPTH = 25)
(
    input clk,
    input enable,
    input [DATA_DEPTH-1:0] datain,

    // Note: this is a 3D Array, only supported as a port in SystemVerilog
    output reg [DATA_DEPTH-1:0] dataout [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1]  // NxN 
);

// Total number of elements in the buffer
localparam BUFFER_SIZE = NUMBER_OF_LINES * LINE_WIDTH;

// shift register
reg [DATA_DEPTH-1:0] line_buffer [0:BUFFER_SIZE-1];

integer i, j; // For indexing in the always blocks

always @(posedge clk) begin
    if (enable) begin
        // Shift all elements in the register
        for (i = 1; i < BUFFER_SIZE; i = i + 1) begin
            line_buffer[i] <= line_buffer[i-1];
        end
        line_buffer[0] <= datain; // Store input data at the first position
    end
    // Nothing else required; the data is retained when enable is low, due to the nature of non-blocking assignments
end

// Generate assignments for the output 3D array (lines x lines x bus_width)
always @(*) begin
    for (i = 0; i < NUMBER_OF_LINES; i = i + 1) begin
        for (j = 0; j < NUMBER_OF_LINES; j = j + 1) begin
            dataout[i][j] = line_buffer[BUFFER_SIZE - j*LINE_WIDTH - i - 1];
        end
    end
end

endmodule

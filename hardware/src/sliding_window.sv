module sliding_window #(parameter NUMBER_OF_LINES = 3, 
                        parameter WIDTH = 640, 
                        parameter BUS_SIZE = 25)
(
    input clock,
    input EN,
    input [BUS_SIZE-1:0] data,
    output reg [BUS_SIZE-1:0] dataout [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1] // 3D array output
);

// Total number of elements in the buffer
localparam BUFFER_SIZE = NUMBER_OF_LINES * WIDTH;

// shift register (using a single 2D array for delayed data)
reg [BUS_SIZE-1:0] fp_delay [0:BUFFER_SIZE-1];

integer i, j; // For indexing in the always block

always @(posedge clock) begin
    if (EN) begin
        // Shift all elements in the register
        for (i = 1; i < BUFFER_SIZE; i = i + 1) begin
            fp_delay[i] <= fp_delay[i-1];
        end
        fp_delay[0] <= data; // Store input data at the first position
    end
    // No else required; the data is retained when EN is low, due to the nature of non-blocking assignments
end

// Generate assignments for the 3D array (lines x lines x bus_width)
always @(*) begin
    for (i = 0; i < NUMBER_OF_LINES; i = i + 1) begin
        for (j = 0; j < NUMBER_OF_LINES; j = j + 1) begin
            dataout[i][j] = fp_delay[BUFFER_SIZE - j*WIDTH - i - 1];
        end
    end
end
 
endmodule

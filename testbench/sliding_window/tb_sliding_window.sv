
// This is just a sanity check (non-exhaustive).
// I stream values in sequentially (1, 2, 3, etc), checking for the correct pattern on the output. 
// This module will be testbenched more extensively when integrated into the entire filter core. 


module tb_sliding_window;

// Parameters
localparam int NUMBER_OF_LINES = 3;
localparam int LINE_WIDTH = 128;
localparam int DATA_DEPTH = 8;

//Ports
reg clk = 1'b0;
reg rst_n = 1'b1;
reg input_valid = 1'b0;
reg [DATA_DEPTH-1:0] datain = '0;
wire [DATA_DEPTH-1:0] dataout [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1];
wire output_valid;

sliding_window # (
  .NUMBER_OF_LINES(NUMBER_OF_LINES),
  .LINE_WIDTH(LINE_WIDTH),
  .DATA_DEPTH(DATA_DEPTH)
)
dut (
  .clk(clk),
  .rst_n(rst_n),
  .input_valid(input_valid),
  .datain(datain),
  .dataout(dataout),
  .output_valid(output_valid)
);

// Clock driver
always #5  clk = ! clk ;

// Test Pattern Generator
integer i;
initial begin
    
    #57;

    // Reset generator
    @(posedge clk) rst_n = 1'b0;
    #20;
    @(posedge clk) rst_n = 1'b1;

    // Set enable
    @(posedge clk) input_valid = 1'b1;
    
    // Inject 3 times the buffer size worth of data. 
    for(i = 0; i < 3*NUMBER_OF_LINES*LINE_WIDTH; i = i + 1) begin

        datain = i % 256;
        @(posedge clk);
    end

    @(posedge clk) input_valid = 1'b0;

    $finish();

end

always @(posedge clk) begin
    if (output_valid) begin
        $display("window @ t=%0t", $time);
        $display("%0d %0d %0d",
            dut.line_buffer[2*LINE_WIDTH+2],
            dut.line_buffer[2*LINE_WIDTH+1],
            dut.line_buffer[2*LINE_WIDTH+0]);
        $display("%0d %0d %0d",
            dut.line_buffer[LINE_WIDTH+2],
            dut.line_buffer[LINE_WIDTH+1],
            dut.line_buffer[LINE_WIDTH+0]);
        $display("%0d %0d %0d",
            dut.line_buffer[2],
            dut.line_buffer[1],
            dut.line_buffer[0]);
        $display("");
    end
end



endmodule

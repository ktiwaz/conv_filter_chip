// This can now be turned into a more exhaustive testbench for per-frame checkinng
// I stream values in sequentially (1, 2, 3, etc), checking for the correct pattern on the output. 
// This module will be testbenched more extensively when integrated into the entire filter core. 

module tb_convolution_core;

// Parameters
localparam int NUMBER_OF_LINES = 3;
localparam int LINE_WIDTH = 128;
localparam int DATA_DEPTH = 8;
localparam int ACC_WIDTH = DATA_DEPTH + DATA_DEPTH + $clog2(NUMBER_OF_LINES * NUMBER_OF_LINES) + 1;
localparam int NORMALIZATION_WIDTH = 8;

//Ports
reg clk = 1'b0;
reg rst_n = 1'b1;
reg input_valid;
reg [DATA_DEPTH-1:0] datain;
wire output_valid;
wire [DATA_DEPTH-1:0] dataout;

reg signed [DATA_DEPTH-1:0] kernel [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1];

reg [NORMALIZATION_WIDTH-1:0] normalization_factor;

initial begin
    kernel[0][0] = -2; kernel[0][1] = -1; kernel[0][2] = 0;
    kernel[1][0] = -1; kernel[1][1] =  1; kernel[1][2] = 1;
    kernel[2][0] = 0; kernel[2][1] = 1; kernel[2][2] = 2;

    normalization_factor = 8'd128;  // Approximately 0.11
end

image_loader # (
    .WIDTH(128),
    .HEIGHT(128),
    .DATA_WIDTH(8),
    .HEX_FILE("../../../testbench/convolution_core/conv_test_input.hex")  // Might need to change this
  )
  image_loader_inst (
    .clk(clk),
    .reset_n(rst_n),
    .pixel(datain),
    .valid(input_valid)
  );

convolution_core # (
    .NUMBER_OF_LINES(NUMBER_OF_LINES),
    .LINE_WIDTH(LINE_WIDTH),
    .PIXEL_WIDTH(DATA_DEPTH),
    .NORMALIZATION_WIDTH(NORMALIZATION_WIDTH)
  )
  convolution_core_inst (
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(input_valid),
    .datain(datain),
    .kernel(kernel),
    .normalization_factor(normalization_factor),
    .output_valid(output_valid),
    .dataout(dataout)
  );

  image_dumper # (
    .WIDTH(128),
    .HEIGHT(128),
    .DATA_WIDTH(8),
    .KERNEL_SIZE(3),
    .OUT_FILE("output_image.hex")
  )
  image_dumper_inst (
    .clk(clk),
    .reset_n(rst_n),
    .pixel(dataout),
    .valid(output_valid)
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

    #400000; // Finish is called by the image dumper

end

endmodule

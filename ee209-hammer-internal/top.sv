module top (
    input  logic clk,
    input  logic rst_n,
    input  logic input_valid,
    input  logic [3:0]  datain,
    input  logic  signed [3:0] kernel [0:2][0:2],
    input  logic [3:0] normalization_factor,
    output logic [3:0] dataout,
    output logic output_valid
    
);

localparam NUMBER_OF_LINES = 3;
localparam LINE_WIDTH = 128;
localparam PIXEL_WIDTH = 4;
localparam NORMALIZATION_WIDTH = 4;

convolution_core # (
    .NUMBER_OF_LINES(NUMBER_OF_LINES),
    .LINE_WIDTH(LINE_WIDTH),
    .PIXEL_WIDTH(PIXEL_WIDTH),
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

endmodule
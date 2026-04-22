module top_3x3 #(
    parameter int DATA_WIDTH  = 8,
    parameter int KERNEL_SIZE = 3,
    parameter int LINE_WIDTH  = 128,
    parameter int NORM_WIDTH  = 8
) (
    //==================================================
    // Clock / Reset
    //==================================================
    input  logic                     clk,
    input  logic                     reset_n,

    //==================================================
    // Control Inputs (mutually exclusive)
    //==================================================
    input  logic                     kernel_valid,
    input  logic                     normalization_valid,
    input  logic                     pixel_valid,
    input  logic                     test_mode,         // TODO: implement functionality

    //==================================================
    // Input Data Bus
    //==================================================
    input  logic [DATA_WIDTH-1:0]    datain,

    //==================================================
    // Output Data Bus
    //==================================================
    output logic [DATA_WIDTH-1:0]    dataout,
    output logic                     output_valid,

    //==================================================
    // Status / Debug
    //==================================================
    output logic [1:0]               status
);

conv_filter_top # (
    .DATA_WIDTH(DATA_WIDTH),
    .KERNEL_SIZE(KERNEL_SIZE),
    .LINE_WIDTH(LINE_WIDTH),
    .NORM_WIDTH(NORM_WIDTH)
  )
  conv_filter_top_inst (
    .clk(clk),
    .reset_n(reset_n),
    .kernel_valid(kernel_valid),
    .normalization_valid(normalization_valid),
    .pixel_valid(pixel_valid),
    .test_mode(test_mode),
    .datain(datain),
    .dataout(dataout),
    .output_valid(output_valid),
    .status(status)
  );

endmodule
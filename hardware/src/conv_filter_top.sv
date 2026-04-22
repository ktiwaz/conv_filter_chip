module conv_filter_top #(
    parameter int DATA_WIDTH  = 8,
    parameter int KERNEL_SIZE = 5,
    parameter int LINE_WIDTH  = 128,
    parameter int NORM_WIDTH  = 16
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

    localparam KERNEL_ADDR_W = $clog2(KERNEL_SIZE * KERNEL_SIZE);
    localparam NORM_COUNT_W = $clog2((NORM_WIDTH + DATA_WIDTH - 1) / DATA_WIDTH);

    wire shiftreg_input_valid;
    wire [DATA_WIDTH-1:0] shiftreg_pixel_data;

    wire kernel_we;
    wire [DATA_WIDTH-1:0] kernel_wdata;
    wire [KERNEL_ADDR_W-1:0] kernel_waddr;

    wire norm_we;
    wire [DATA_WIDTH-1:0] norm_wdata;
    wire [NORM_COUNT_W-1:0] norm_byte_index;

    io_control_fsm # (
        .DATA_WIDTH(DATA_WIDTH),
        .KERNEL_SIZE(KERNEL_SIZE),
        .NORM_WIDTH(NORM_WIDTH)
    ) io_control_fsm_inst (
        .clk(clk),
        .reset_n(reset_n),
        .kernel_valid(kernel_valid),
        .normalization_valid(normalization_valid),
        .pixel_valid(pixel_valid),
        .test_mode(test_mode),
        .datain(datain),
        .shiftreg_input_valid(shiftreg_input_valid),
        .shiftreg_pixel_data(shiftreg_pixel_data),
        .kernel_we(kernel_we),
        .kernel_wdata(kernel_wdata),
        .kernel_waddr(kernel_waddr),
        .norm_we(norm_we),
        .norm_wdata(norm_wdata),
        .norm_byte_index(norm_byte_index),
        .status(status)
    );

    logic signed [DATA_WIDTH-1:0] kernel [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];

    kernel_register_array # (
        .DATA_WIDTH(DATA_WIDTH),
        .KERNEL_SIZE(KERNEL_SIZE)
    ) kernel_register_array_inst (
        .clk(clk),
        .reset_n(reset_n),
        .we(kernel_we),
        .waddr(kernel_waddr),
        .wdata(kernel_wdata),
        .kernel(kernel)
    );

    logic [NORM_WIDTH-1:0] normalization_value;

    normalization_register # (
        .DATA_WIDTH(DATA_WIDTH),
        .NORM_WIDTH(NORM_WIDTH)
    )
    normalization_register_inst (
        .clk(clk),
        .reset_n(reset_n),
        .we(norm_we),
        .byte_index(norm_byte_index),
        .wdata(norm_wdata),
        .normalization_value(normalization_value)
    );

    convolution_core # (
        .NUMBER_OF_LINES(KERNEL_SIZE),
        .LINE_WIDTH(LINE_WIDTH),
        .PIXEL_WIDTH(DATA_WIDTH),
        .NORMALIZATION_WIDTH(NORM_WIDTH)
    )
    convolution_core_inst (
        .clk(clk),
        .rst_n(reset_n),
        .input_valid(shiftreg_input_valid),
        .datain(shiftreg_pixel_data),
        .kernel(kernel),
        .normalization_factor(normalization_value),
        .output_valid(output_valid),
        .dataout(dataout)
    );


endmodule
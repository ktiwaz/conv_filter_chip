// Top level for the DUT board: the second PYNQ-Z2 standing in for the chip.
module dut_board (
    input  wire       refclk_125,
    input  wire [1:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led,

    input  wire       chip_clk,
    input  wire       chip_reset_n,
    input  wire       chip_kernel_valid,
    input  wire       chip_normalization_valid,
    input  wire       chip_pixel_valid,
    input  wire       chip_test_mode,
    input  wire [7:0] chip_datain,
    output wire [7:0] chip_dataout,
    output wire       chip_output_valid,
    output wire [1:0] chip_status
);

    dut_board_core core (
        .refclk(refclk_125),
        .chip_clk(chip_clk),
        .chip_reset_n(chip_reset_n),
        .chip_kernel_valid(chip_kernel_valid),
        .chip_normalization_valid(chip_normalization_valid),
        .chip_pixel_valid(chip_pixel_valid),
        .chip_test_mode(chip_test_mode),
        .chip_datain(chip_datain),
        .chip_dataout(chip_dataout),
        .chip_output_valid(chip_output_valid),
        .chip_status(chip_status),
        .led(led)
    );

    // Oversample every link pin at 125 MHz to debug the wiring
    ila_dut pin_ila (
        .clk(refclk_125),
        .probe0({chip_datain, chip_test_mode, chip_pixel_valid, chip_normalization_valid,
                 chip_kernel_valid, chip_reset_n, chip_clk}),   // [13:0]
        .probe1({chip_status, chip_output_valid, chip_dataout})  // [10:0]
    );

endmodule

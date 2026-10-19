// DUT board fabric: conv_filter_top wired 1:1 to the chip_* pins, clocked by
// the forwarded chip_clk, the same way the fabricated chip will be driven.
// Kept free of vendor IP so the tester simulation can instantiate it.
module dut_board_core (
    input  wire       refclk,            // board clock, heartbeat only
    input  wire       chip_clk,
    input  wire       chip_reset_n,
    input  wire       chip_kernel_valid,
    input  wire       chip_normalization_valid,
    input  wire       chip_pixel_valid,
    input  wire       chip_test_mode,
    input  wire [7:0] chip_datain,
    output wire [7:0] chip_dataout,
    output wire       chip_output_valid,
    output wire [1:0] chip_status,
    output wire [3:0] led
);

    conv_filter_top #(
        .DATA_WIDTH(8),
        .KERNEL_SIZE(5),
        .LINE_WIDTH(128),
        .NORM_WIDTH(16)
    ) dut (
        .clk(chip_clk),
        .reset_n(chip_reset_n),
        .kernel_valid(chip_kernel_valid),
        .normalization_valid(chip_normalization_valid),
        .pixel_valid(chip_pixel_valid),
        .test_mode(chip_test_mode),
        .datain(chip_datain),
        .dataout(chip_dataout),
        .output_valid(chip_output_valid),
        .status(chip_status)
    );

    // led0: blinks while chip_clk is running (~1 Hz at 8.33 MHz)
    reg [22:0] link_count = 0;
    always @(posedge chip_clk) link_count <= link_count + 1'b1;

    // led1: blinks at ~1 Hz from the 125 MHz board clock, so the board is identifiable
    reg [26:0] ref_count = 0;
    always @(posedge refclk) ref_count <= ref_count + 1'b1;

    assign led = {chip_status, ref_count[26], link_count[22]};

endmodule

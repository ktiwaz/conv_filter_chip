// Tester-side board-to-board link to an external DUT (second FPGA or the chip).
//
// Everything runs in the 50 MHz fabric clock. With H = half-period in fabric
// cycles, a phase counter p runs 0..2H-1 and the forwarded clock is
// chip_clk = (p < H), i.e. 25/H MHz: it rises entering p = 0 and falls entering
// p = H.
//
//   - DUT inputs are launched from IOB flops entering p = H (the falling edge),
//     so they are centered on the DUT's rising edge.
//   - DUT outputs are registered by IOB flops every fabric cycle; the value
//     registered at the edge entering p = S (the sample phase) is presented
//     with out_strobe. S must land after the next beat's inputs have reached
//     the DUT and propagated back (paths combinational from DUT inputs, e.g.
//     test_mode: output_valid = pixel_valid && window full), but before the
//     DUT's registered outputs change after its next rising edge. Measured on
//     two PYNQ-Z2s with ~15 cm jumper wires (2026-10-14), with the DUT-board
//     IO constraints in tcl/link_pins.tcl:
//       - registered outputs change ~40 ns after the tester's rising edge
//         (sampling at S = 2 fails at every link speed)
//       - the combinational test_mode path (pixel_valid -> output_valid,
//         11.9 ns pin-to-pin on the DUT board) is back within 40 ns of the
//         input launch at p = H
//     Every testcase passes, with and without pixel_valid gaps, at S = 0 for
//     H >= 3 and S = 1 for H <= 2 (the jtb_link defaults). Use
//     jtb_sweep_sample to re-measure after changing the wiring or the DUT.
//   - ce pulses once per link cycle (p = H-1); the sequencer advances on it, so
//     each link cycle carries one beat. The pins lag the sequencer by one link
//     cycle, which is the same for every signal.
//
// When !enable the link idles (clock low, chip_reset_n low, valids low) and ce
// is held high so internal mode runs one beat per fabric cycle.
module link_phy (
    input  wire       clk,
    input  wire       aresetn,
    input  wire       enable,
    input  wire [7:0] half,          // H (0 is treated as 1)
    input  wire [7:0] sample,        // S (clamped to 2H-1)

    output wire       ce,

    // From the sequencer
    input  wire       dut_reset_n,
    input  wire       kernel_valid,
    input  wire       normalization_valid,
    input  wire       pixel_valid,
    input  wire       test_mode,
    input  wire [7:0] datain,

    // Sampled DUT outputs
    output reg        out_strobe,
    output reg  [7:0] out_dataout,
    output reg        out_output_valid,
    output reg  [1:0] out_status,

    // Pins
    (* IOB = "TRUE" *) output reg       chip_clk,
    (* IOB = "TRUE" *) output reg       chip_reset_n,
    (* IOB = "TRUE" *) output reg       chip_kernel_valid,
    (* IOB = "TRUE" *) output reg       chip_normalization_valid,
    (* IOB = "TRUE" *) output reg       chip_pixel_valid,
    (* IOB = "TRUE" *) output reg       chip_test_mode,
    (* IOB = "TRUE" *) output reg [7:0] chip_datain,
    input  wire [7:0] chip_dataout,
    input  wire       chip_output_valid,
    input  wire [1:0] chip_status
);

    wire [8:0] h      = (half == 8'd0) ? 9'd1 : {1'b0, half};
    wire [8:0] period = h << 1;
    wire [8:0] s      = ({1'b0, sample} >= period) ? period - 9'd1 : {1'b0, sample};

    reg  [8:0] p;
    wire [8:0] p_next = (p == period - 9'd1) ? 9'd0 : p + 9'd1;

    assign ce = enable ? (p == h - 9'd1) : 1'b1;

    always @(posedge clk) begin
        if (!aresetn || !enable)
            p <= 9'd0;
        else
            p <= p_next;
    end

    // Forwarded clock and DUT inputs
    always @(posedge clk) begin
        if (!aresetn || !enable) begin
            chip_clk                 <= 1'b0;
            chip_reset_n             <= 1'b0;
            chip_kernel_valid        <= 1'b0;
            chip_normalization_valid <= 1'b0;
            chip_pixel_valid         <= 1'b0;
            chip_test_mode           <= 1'b0;
            chip_datain              <= 8'd0;
        end else begin
            chip_clk <= (p_next < h);
            if (p_next == h) begin
                chip_reset_n             <= dut_reset_n;
                chip_kernel_valid        <= kernel_valid;
                chip_normalization_valid <= normalization_valid;
                chip_pixel_valid         <= pixel_valid;
                chip_test_mode           <= test_mode;
                chip_datain              <= datain;
            end
        end
    end

    // DUT outputs: IOB input flops every cycle, then pick the sample phase
    (* IOB = "TRUE" *) reg [7:0] in_dataout;
    (* IOB = "TRUE" *) reg       in_output_valid;
    (* IOB = "TRUE" *) reg [1:0] in_status;

    always @(posedge clk) begin
        in_dataout      <= chip_dataout;
        in_output_valid <= chip_output_valid;
        in_status       <= chip_status;
    end

    // in_* hold the pins as registered at the edge entering the current p
    always @(posedge clk) begin
        if (!aresetn || !enable) begin
            out_strobe       <= 1'b0;
            out_dataout      <= 8'd0;
            out_output_valid <= 1'b0;
            out_status       <= 2'd0;
        end else begin
            out_strobe <= (p == s);
            if (p == s) begin
                out_dataout      <= in_dataout;
                out_output_valid <= in_output_valid;
                out_status       <= in_status;
            end
        end
    end

endmodule

//==================================================
// Defaults (can be overridden by +define+...)
//==================================================
`timescale 1ns/1ps
module tb_top_3x3;

    localparam string TESTCASE_DIR = `TESTCASE_DIR;
    localparam int KERNEL_SIZE     = `KERNEL_SIZE;
    localparam int NORM_WIDTH      = `NORM_WIDTH;
    localparam int DATA_WIDTH      = `DATA_WIDTH;
    localparam int LINE_WIDTH      = `LINE_WIDTH;
    localparam int IMAGE_HEIGHT    = `IMAGE_HEIGHT;

    `ifdef TEST_MODE
    localparam logic TEST_MODE_EN = 1'b1;
    `else
    localparam logic TEST_MODE_EN = 1'b0;
    `endif

    localparam logic [NORM_WIDTH-1:0] NORMALIZATION_VALUE = `NORMALIZATION_VALUE;

    localparam int KERNEL_WORDS  = KERNEL_SIZE * KERNEL_SIZE;
    localparam int NORM_WORDS    = (NORM_WIDTH + DATA_WIDTH - 1) / DATA_WIDTH;
    localparam int STATUS_WIDTH  = 2;

    localparam string KERNEL_FILE = {TESTCASE_DIR, "/kernel.hex"};
    localparam string INPUT_FILE  = {TESTCASE_DIR, "/input_image.hex"};
    localparam string OUTPUT_FILE = {TESTCASE_DIR, "/output_image.hex"};

    // ==================================================
    // DUT interface
    // ==================================================
    logic clk = 1'b0;
    logic reset_n = 1'b0;

    logic kernel_valid;
    logic normalization_valid;
    logic pixel_valid;
    logic test_mode;
    assign test_mode = TEST_MODE_EN;
    logic [DATA_WIDTH-1:0] datain;

    logic [DATA_WIDTH-1:0] dataout;
    logic                  output_valid;
    logic [STATUS_WIDTH-1:0] status;

    // ==================================================
    // Loader / Dumper interface
    // ==================================================
    logic loader_reset_n;
    logic [DATA_WIDTH-1:0] loader_pixel;
    logic                  loader_valid;

    // ==================================================
    // Kernel storage for TB programming
    // ==================================================
    logic [DATA_WIDTH-1:0] kernel_mem [0:KERNEL_WORDS-1];

    integer i;
    integer row;
    integer col;

    // ==================================================
    // Clock
    // ==================================================
    always #5ns clk = ~clk;

    // ==================================================
    // DUT
    // ==================================================
    top_3x3 #(
        .DATA_WIDTH (DATA_WIDTH),
        .KERNEL_SIZE(KERNEL_SIZE),
        .LINE_WIDTH (LINE_WIDTH),
        .NORM_WIDTH (NORM_WIDTH)
    ) dut (
        .clk                (clk),
        .reset_n            (reset_n),
        .kernel_valid       (kernel_valid),
        .normalization_valid(normalization_valid),
        .pixel_valid        (pixel_valid),
        .test_mode          (test_mode),
        .datain             (datain),
        .dataout            (dataout),
        .output_valid       (output_valid),
        .status             (status)
    );

    // ==================================================
    // Image loader
    // Held in reset until kernel/norm programming completes
    // ==================================================
    image_loader #(
        .WIDTH     (LINE_WIDTH),
        .HEIGHT    (IMAGE_HEIGHT),
        .DATA_WIDTH(DATA_WIDTH),
        .HEX_FILE  (INPUT_FILE)
    ) image_loader_inst (
        .clk    (clk),
        .reset_n(loader_reset_n),
        .pixel  (loader_pixel),
        .valid  (loader_valid)
    );

    // ==================================================
    // Image dumper
    // ==================================================
    image_dumper #(
        .WIDTH      (LINE_WIDTH),
        .HEIGHT     (IMAGE_HEIGHT),
        .DATA_WIDTH (DATA_WIDTH),
        .KERNEL_SIZE(KERNEL_SIZE),
        .OUT_FILE   (OUTPUT_FILE)
    ) image_dumper_inst (
        .clk    (clk),
        .reset_n(reset_n),
        .pixel  (dataout),
        .valid  (output_valid)
    );

    // ==================================================
    // Pixel stream routing
    // TB only drives pixel_valid/datain from loader
    // after programming is complete.
    // ==================================================
    task automatic stream_pixels_from_loader();
        begin
            $display("[%0t] Starting pixel stream from %s", $time, INPUT_FILE);
            loader_reset_n = 1'b1;

            forever begin
                @(posedge clk);
                pixel_valid <= #1ns loader_valid;
                datain      <= #1ns loader_pixel;
            end
        end
    endtask

    initial begin
        $fsdbDumpfile("waveform.fsdb");
        $fsdbDumpvars(0, tb_conv_filter_top);
    end

    // ==================================================
    // Program kernel: row-major, one byte per cycle
    // ==================================================
    task automatic program_kernel();
        begin
            $display("[%0t] Programming kernel from %s", $time, KERNEL_FILE);

            for (i = 0; i < KERNEL_WORDS; i = i + 1) begin
                @(posedge clk);
                kernel_valid        <= #1ns 1'b1;
                normalization_valid <= #1ns 1'b0;
                pixel_valid         <= #1ns 1'b0;
                datain              <= #1ns kernel_mem[i];

                row = i / KERNEL_SIZE;
                col = i % KERNEL_SIZE;

                $display("[%0t] kernel[%0d][%0d] <= #0.2 0x%02h (%0d)",
                         $time, row, col, kernel_mem[i], $signed(kernel_mem[i]));
            end

            @(posedge clk);
            kernel_valid        <= #1ns 1'b0;
            normalization_valid <= #1ns 1'b0;
            pixel_valid         <= #1ns 1'b0;
            datain              <= #1ns '0;
        end
    endtask

    // ==================================================
    // Program normalization: MSB to LSB
    // ==================================================
    task automatic program_normalization();
        logic [NORM_WIDTH-1:0] norm_tmp;
        logic [DATA_WIDTH-1:0] norm_byte;
        begin
            norm_tmp = NORMALIZATION_VALUE;

            $display("[%0t] Programming normalization value = 0x%0h (%0d)",
                     $time, NORMALIZATION_VALUE, NORMALIZATION_VALUE);

            for (i = 0; i < NORM_WORDS; i = i + 1) begin
                norm_byte = norm_tmp[NORM_WIDTH-1 - i*DATA_WIDTH -: DATA_WIDTH];

                @(posedge clk);
                kernel_valid        <= #1ns 1'b0;
                normalization_valid <= #1ns 1'b1;
                pixel_valid         <= #1ns 1'b0;
                datain              <= #1ns norm_byte;

                $display("[%0t] normalization byte %0d <= #0.2 0x%02h",
                         $time, i, norm_byte);
            end

            @(posedge clk);
            kernel_valid        <= #1ns 1'b0;
            normalization_valid <= #1ns 1'b0;
            pixel_valid         <= #1ns 1'b0;
            datain              <= #1ns '0;

            $display("[%0t] Final normalization programmed = 0x%0h",
                     $time, NORMALIZATION_VALUE);
        end
    endtask

    // ==================================================
    // Optional status monitor
    // ==================================================
    always @(posedge clk) begin
        if (reset_n) begin
            case (status)
                3'b000: ;
                3'b001: $display("[%0t] STATUS = LOAD_KERNEL", $time);
                3'b010: $display("[%0t] STATUS = LOAD_NORM",   $time);
                3'b011: $display("[%0t] STATUS = ERROR",       $time);
                default: ;
            endcase
        end
    end

    // ==================================================
    // Main stimulus
    // ==================================================
    initial begin
        // Defaults
        kernel_valid        = 1'b0;
        normalization_valid = 1'b0;
        pixel_valid         = 1'b0;
        datain              = '0;

        reset_n             = 1'b0;
        loader_reset_n      = 1'b0;

        // Read kernel coefficients
        $display("[%0t] Loading kernel file %s", $time, KERNEL_FILE);
        $readmemh(KERNEL_FILE, kernel_mem);

        // Hold reset for a few cycles
        repeat (4) @(posedge clk);

        @(posedge clk);
        reset_n = 1'b1;
        $display("[%0t] DUT reset released", $time);
        repeat (5) @(posedge clk);

        // Program kernel
        program_kernel();

        // Program normalization
        program_normalization();

        // Start streaming pixels
        fork
            stream_pixels_from_loader();
        join_none

        // Timeout protection
        #4000000ns;
        $fatal(1, "[%0t] ERROR: Testbench timeout", $time);
    end

endmodule
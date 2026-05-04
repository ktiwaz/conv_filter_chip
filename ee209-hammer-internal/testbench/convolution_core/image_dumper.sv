`timescale 1ns/1ps
module image_dumper #(
    parameter int WIDTH        = 640,
    parameter int HEIGHT       = 480,
    parameter int DATA_WIDTH   = 8,
    parameter int KERNEL_SIZE  = 3,
    parameter int TIMEOUT_CYCLES = 2 * WIDTH * HEIGHT,
    parameter string OUT_FILE  = "output_image.hex"
) (
    input  logic clk,
    input  logic reset_n,
    input  logic [DATA_WIDTH-1:0] pixel,
    input  logic valid
);

    localparam int TOTAL_PIXELS      = WIDTH * HEIGHT;
    localparam int FIRST_VALID_INDEX = (KERNEL_SIZE - 1) * WIDTH + (KERNEL_SIZE - 1);
    localparam int VALID_PIXELS      = TOTAL_PIXELS - FIRST_VALID_INDEX - 1; // -1 because we don't add input_valid after the last pixel
    localparam int MEM_DEPTH         = (VALID_PIXELS > 0) ? VALID_PIXELS : 1;
    localparam int INDEX_WIDTH       = (MEM_DEPTH > 1) ? $clog2(MEM_DEPTH) : 1;
    localparam int HEX_DIGITS        = (DATA_WIDTH + 3) / 4;
    localparam int TIMEOUT_WIDTH     = (TIMEOUT_CYCLES > 1) ? $clog2(TIMEOUT_CYCLES + 1) : 1;

    reg [DATA_WIDTH-1:0] image_mem [0:MEM_DEPTH-1];

    logic dump;
    logic dumped;
    logic [INDEX_WIDTH-1:0] index;
    logic [TIMEOUT_WIDTH-1:0] timeout_count;

    integer j;
    integer out_file;

    // Capture valid output pixels only, and track timeout
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            dump          <= #1ns 1'b0;
            index         <= #1ns '0;
            timeout_count <= #1ns '0;
        end else begin
            if (!dump && !dumped) begin
                // Count cycles while waiting for all expected valids
                if (timeout_count < TIMEOUT_CYCLES)
                    timeout_count <= #1ns timeout_count + 1'b1;

                if (valid) begin
                    image_mem[index] <= #1ns 
                    pixel;

                    if (index == MEM_DEPTH - 1) begin
                        dump <= #1ns 1'b1;
                    end else begin
                        index <= #1ns index + 1'b1;
                    end
                end

                // Timeout check
                if (timeout_count == TIMEOUT_CYCLES) begin
                    $display("Error: image_dumper timeout.");
                    $display("I only got %0d valids when I expected %0d.",
                             index, VALID_PIXELS);
                    $display("WIDTH=%0d HEIGHT=%0d KERNEL_SIZE=%0d TIMEOUT_CYCLES=%0d",
                             WIDTH, HEIGHT, KERNEL_SIZE, TIMEOUT_CYCLES);
                    $finish;
                end
            end
        end
    end

    // Dump to file once all valid outputs are captured
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            dumped        <= #1ns 1'b0;
        end else if (dump && !dumped) begin
            out_file = $fopen(OUT_FILE, "w");
            if (out_file == 0) begin
                $display("Error: Could not open output file %s", OUT_FILE);
                $finish;
            end

            for (j = 0; j < MEM_DEPTH; j = j + 1) begin
                case (HEX_DIGITS)
                    1: $fdisplay(out_file, "%01X", image_mem[j]);
                    2: $fdisplay(out_file, "%02X", image_mem[j]);
                    3: $fdisplay(out_file, "%03X", image_mem[j]);
                    4: $fdisplay(out_file, "%04X", image_mem[j]);
                    5: $fdisplay(out_file, "%05X", image_mem[j]);
                    6: $fdisplay(out_file, "%06X", image_mem[j]);
                    7: $fdisplay(out_file, "%07X", image_mem[j]);
                    8: $fdisplay(out_file, "%08X", image_mem[j]);
                    default: $fdisplay(out_file, "%0X", image_mem[j]);
                endcase
            end

            $fclose(out_file);
            dumped <= #1ns 1'b1;
            $display("Image dumped to %s", OUT_FILE);
            $display("Dumped %0d valid pixels (WIDTH=%0d HEIGHT=%0d KERNEL_SIZE=%0d)",
                     VALID_PIXELS, WIDTH, HEIGHT, KERNEL_SIZE);
            $finish;
        end
    end

endmodule
//==============================================================================
// Module Name : image_dumper
// Author      : Kushagra Tiwari
// Date        : 2026-04-13
//
// Description :
//   Captures a grayscale pixel stream and dumps exactly WIDTH*HEIGHT pixels
//   to a hex text file, one pixel per line.
//
//   Intended for simulation use.
//
//   Expected output format:
//     - One hex pixel value per line
//     - Zero-padded to the minimum number of hex digits required by DATA_WIDTH
//
//   Behavior:
//     - Captures pixels only when valid is high
//     - Stores exactly WIDTH*HEIGHT pixels
//     - Writes output file once full
//     - Calls $finish() after dumping
//
// Parameters :
//   WIDTH       : Image width in pixels
//   HEIGHT      : Image height in pixels
//   DATA_WIDTH  : Bit width of grayscale pixel
//   INDEX_WIDTH : Width of capture index counter; must be wide enough for WIDTH*HEIGHT
//   OUT_FILE    : Output hex filename
//
//==============================================================================
module image_dumper #(
    parameter int WIDTH       = 640,
    parameter int HEIGHT      = 480,
    parameter int DATA_WIDTH  = 8,
    parameter string OUT_FILE = "output_image.hex"
) (
    input  logic clk,
    input  logic reset_n,
    input  logic [DATA_WIDTH-1:0] pixel,
    input  logic valid
);

    localparam int MEM_DEPTH = WIDTH * HEIGHT;
    localparam int INDEX_WIDTH = $clog2(MEM_DEPTH);
    localparam int HEX_DIGITS = (DATA_WIDTH + 3) / 4;

    reg [DATA_WIDTH-1:0] image_mem [0:MEM_DEPTH-1];

    logic dump;
    logic dumped;
    logic [INDEX_WIDTH-1:0] index;

    integer j;
    integer out_file;

    // Capture incoming pixels
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            dump   <= 1'b0;
            index  <= '0;
        end else begin
            if (valid && !dump && !dumped) begin
                image_mem[index] <= pixel;

                if (index == MEM_DEPTH - 1) begin
                    dump <= 1'b1;
                end else begin
                    index <= index + 1'b1;
                end
            end
        end
    end

    // Dump to file once full
    always_ff @(posedge clk) begin

        if (!reset_n) begin
            dumped <= 1'b0;
        end

        if (dump && !dumped) begin
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
            dumped <= 1'b1;
            $display("Image dumped to %s", OUT_FILE);
            $finish;
        end
    end

endmodule
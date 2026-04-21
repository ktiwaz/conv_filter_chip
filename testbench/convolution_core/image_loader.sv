//==============================================================================
// Module Name : image_loader
// Author      : Kushagra Tiwari
// Date        : 2026-04-13
//
// Description :
//   Loads a grayscale image from a hex file using $readmemh and streams out
//   one pixel per clock cycle in raster order.
//
//   Expected file format:
//     - One hexadecimal pixel value per line
//     - Row-major order: arr[0,0], arr[0,1], ..., arr[0,WIDTH-1],
//                        arr[1,0], ...
//
//   This matches the Python function:
//
//     def dump_array_hex(arr, bit_depth, filename):
//         ...
//         f.write(f"{val:0{hex_width}X}\n")
//
// Parameters :
//   WIDTH       : Image width in pixels
//   HEIGHT      : Image height in pixels
//   DATA_WIDTH  : Pixel bit width
//   INDEX_WIDTH : Width of index counter; must be wide enough for WIDTH*HEIGHT
//   HEX_FILE    : Input hex filename
//
// Notes :
//   - Output valid goes high after reset is released
//   - The image repeats continuously
//   - This is intended for simulation/testbench use
//
//==============================================================================
module image_loader #(
    parameter int WIDTH       = 640,
    parameter int HEIGHT      = 480,
    parameter int DATA_WIDTH  = 8,
    parameter string HEX_FILE = "image.hex"
)(
    input  logic clk,
    input  logic reset_n,

    output logic [DATA_WIDTH-1:0] pixel,
    output logic valid
);

    localparam int MEM_DEPTH = WIDTH * HEIGHT;
    localparam int INDEX_WIDTH = $clog2(MEM_DEPTH);

    // One grayscale pixel per memory entry
    reg [DATA_WIDTH-1:0] image_mem [0:MEM_DEPTH-1];

    logic [INDEX_WIDTH-1:0] index;
    logic loaded;

    // Load image at simulation start
    initial begin
        $display("Loading grayscale image from %s", HEX_FILE);
        $readmemh(HEX_FILE, image_mem);
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            index  <= '0;
            pixel  <= '0;
            valid  <= 1'b0;
            loaded <= 1'b0;
        end else begin
            if (!loaded) begin
                pixel <= image_mem[index];
                valid <= 1'b1;

                if (index == MEM_DEPTH-1) begin
                    loaded <= 1'b1;
                end else begin
                    index <= index + 1'b1;
                end
            end else begin
                valid <= 1'b0;
            end
        end
    end

endmodule
// True dual-port block RAM with per-byte write enables on both ports.
// Read-first, 1-cycle registered read. Follows the Vivado byte-write TDP
// inference template so it maps onto RAMB36 primitives.
module bram_dp_be #(
    parameter ADDR_WIDTH = 12,
    parameter NUM_BYTES  = 4,
    parameter INIT_FILE  = ""
) (
    input  wire                     clk,

    input  wire                     a_en,
    input  wire [NUM_BYTES-1:0]     a_we,
    input  wire [ADDR_WIDTH-1:0]    a_addr,
    input  wire [NUM_BYTES*8-1:0]   a_din,
    output reg  [NUM_BYTES*8-1:0]   a_dout,

    input  wire                     b_en,
    input  wire [NUM_BYTES-1:0]     b_we,
    input  wire [ADDR_WIDTH-1:0]    b_addr,
    input  wire [NUM_BYTES*8-1:0]   b_din,
    output reg  [NUM_BYTES*8-1:0]   b_dout
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    (* ram_style = "block" *)
    reg [NUM_BYTES*8-1:0] ram [0:DEPTH-1];

    integer k;
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, ram);
        end else begin
            for (k = 0; k < DEPTH; k = k + 1)
                ram[k] = {NUM_BYTES*8{1'b0}};
        end
    end

    genvar i;
    generate
        for (i = 0; i < NUM_BYTES; i = i + 1) begin : g_byte
            always @(posedge clk) begin
                if (a_en && a_we[i])
                    ram[a_addr][i*8 +: 8] <= a_din[i*8 +: 8];
            end
            always @(posedge clk) begin
                if (b_en && b_we[i])
                    ram[b_addr][i*8 +: 8] <= b_din[i*8 +: 8];
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (a_en)
            a_dout <= ram[a_addr];
    end

    always @(posedge clk) begin
        if (b_en)
            b_dout <= ram[b_addr];
    end

endmodule

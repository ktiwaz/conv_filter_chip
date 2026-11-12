// True dual-port block RAM with per-byte write enables on both ports.
// 1-cycle registered read on cycles without a write; dout holds during a
// write ("no change"). Nothing here reads during a write, and GW2A block RAM
// doesn't support read-first on true dual-port RAM (Gowin's tools reject
// WRITE_MODE read-before-write). Follows the Vivado byte-write TDP template.
module bram_dp_be #(
    parameter ADDR_WIDTH = 12,
    parameter NUM_BYTES  = 4,
    parameter INIT_FILE  = "",
    // 0: port A writes whole words whenever any byte strobe is set. GW2A
    // block RAM can't take byte enables on a port that also reads (Gowin's
    // tools infer an unsupported write mode); only use 0 where every port-A
    // write has all strobes set.
    parameter A_BYTE_WE  = 1
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

    // no_rw_check: no defined result is needed when one port reads a word the
    // other writes in the same cycle; without it yosys doubles the RAM on
    // Gowin to emulate one (Vivado ignores the attribute)
    (* ram_style = "block", no_rw_check *)
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

    // One always block per port: write the enabled bytes, or read when no
    // byte is written ("no change" byte-write TDP template, UG901
    // bytewrite_tdp_ram_nc; also inferred by GowinSynthesis and yosys)
    integer i, j;
    always @(posedge clk) begin
        if (a_en) begin
            if (a_we != {NUM_BYTES{1'b0}}) begin
                if (A_BYTE_WE == 0)
                    ram[a_addr] <= a_din;
                else
                    for (i = 0; i < NUM_BYTES; i = i + 1)
                        if (a_we[i])
                            ram[a_addr][i*8 +: 8] <= a_din[i*8 +: 8];
            end else begin
                a_dout <= ram[a_addr];
            end
        end
    end

    always @(posedge clk) begin
        if (b_en) begin
            if (b_we != {NUM_BYTES{1'b0}}) begin
                for (j = 0; j < NUM_BYTES; j = j + 1)
                    if (b_we[j])
                        ram[b_addr][j*8 +: 8] <= b_din[j*8 +: 8];
            end else begin
                b_dout <= ram[b_addr];
            end
        end
    end

endmodule

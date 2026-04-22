module normalization_register #(
    parameter int DATA_WIDTH = 8,
    parameter int NORM_WIDTH = 16,
    localparam int NORM_WORDS   = (NORM_WIDTH + DATA_WIDTH - 1) / DATA_WIDTH,
    localparam int NORM_COUNT_W = (NORM_WORDS > 1) ? $clog2(NORM_WORDS) : 1
) (
    input  logic                           clk,
    input  logic                           reset_n,

    input  logic                           we,
    input  logic [NORM_COUNT_W-1:0]        byte_index,
    input  logic [DATA_WIDTH-1:0]          wdata,

    output logic [NORM_WIDTH-1:0]          normalization_value
);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            normalization_value <= '0;
        end else begin
            if (we) begin
                normalization_value[NORM_WIDTH - 1 - (byte_index * DATA_WIDTH) -: DATA_WIDTH] <= wdata;
            end
        end
    end

endmodule
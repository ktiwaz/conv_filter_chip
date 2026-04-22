module kernel_register_array #(
    parameter int DATA_WIDTH   = 8,
    parameter int KERNEL_SIZE  = 5,
    localparam int KERNEL_WORDS  = KERNEL_SIZE * KERNEL_SIZE,
    localparam int KERNEL_ADDR_W = (KERNEL_WORDS > 1) ? $clog2(KERNEL_WORDS) : 1
) (
    input  logic                               clk,
    input  logic                               reset_n,

    input  logic                               we,
    input  logic [KERNEL_ADDR_W-1:0]           waddr,
    input  logic signed [DATA_WIDTH-1:0]       wdata,

    output logic signed [DATA_WIDTH-1:0]       kernel [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1]
);

    logic signed [DATA_WIDTH-1:0] kernel_flat_q [0:KERNEL_WORDS-1];

    integer i;
    integer row, col;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (i = 0; i < KERNEL_WORDS; i = i + 1) begin
                kernel_flat_q[i] <= '0;
            end
        end else begin
            if (we) begin
                kernel_flat_q[waddr] <= wdata;
            end
        end
    end

    always_comb begin
        for (row = 0; row < KERNEL_SIZE; row = row + 1) begin
            for (col = 0; col < KERNEL_SIZE; col = col + 1) begin
                kernel[row][col] = kernel_flat_q[row * KERNEL_SIZE + col];
            end
        end
    end

endmodule
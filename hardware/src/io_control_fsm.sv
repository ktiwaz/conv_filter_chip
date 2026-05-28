module io_control_fsm #(
    parameter int DATA_WIDTH   = 8,
    parameter int KERNEL_SIZE  = 3,
    parameter int NORM_WIDTH   = 16,
    localparam int KERNEL_WORDS = KERNEL_SIZE * KERNEL_SIZE,
    localparam int NORM_WORDS   = (NORM_WIDTH + DATA_WIDTH - 1) / DATA_WIDTH,
    localparam int KERNEL_ADDR_W = $clog2(KERNEL_WORDS),
    localparam int NORM_COUNT_W  = (NORM_WORDS > 1) ? $clog2(NORM_WORDS) : 1
) (
    input  logic                  clk,
    input  logic                  reset_n,

    input  logic                  kernel_valid,
    input  logic                  normalization_valid,
    input  logic                  pixel_valid,
    input  logic [DATA_WIDTH-1:0] datain,

    output logic                  shiftreg_input_valid,
    output logic [DATA_WIDTH-1:0] shiftreg_pixel_data,

    output logic                  kernel_we,
    output logic [DATA_WIDTH-1:0] kernel_wdata,
    output logic [KERNEL_ADDR_W-1:0] kernel_waddr,

    output logic                  norm_we,
    output logic [DATA_WIDTH-1:0] norm_wdata,
    output logic [NORM_COUNT_W-1:0] norm_byte_index,

    output logic [1:0]            status
);

logic [KERNEL_ADDR_W-1:0] kernel_count_q, kernel_count_d;
logic [NORM_COUNT_W-1:0]  norm_count_q,   norm_count_d;

logic multiple_valid;
assign multiple_valid = (kernel_valid && normalization_valid) || 
                        (kernel_valid && pixel_valid) || 
                        (normalization_valid && pixel_valid);

typedef enum logic [1:0] {
    S_IDLE        = 2'd0,
    S_LOAD_KERNEL = 2'd1,
    S_LOAD_NORM   = 2'd2,
    S_ERROR       = 2'd3
} state_t;

state_t state_q, state_d;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state_q       <= S_IDLE;
        kernel_count_q <= '0;
        norm_count_q   <= '0;
    end else begin
        state_q       <= state_d;
        kernel_count_q <= kernel_count_d;
        norm_count_q   <= norm_count_d;
    end
end

always_comb begin
    state_d = state_q;
    kernel_count_d = kernel_count_q;
    norm_count_d   = norm_count_q;

    shiftreg_input_valid = 1'b0;
    shiftreg_pixel_data  = datain;

    kernel_we    = 1'b0;
    kernel_wdata = datain;
    kernel_waddr = kernel_count_q;

    norm_we         = 1'b0;
    norm_wdata      = datain;
    norm_byte_index = norm_count_q;

    unique case (state_q)

        S_IDLE: begin
            if (multiple_valid) begin
                state_d = S_ERROR;
            end
            else if (kernel_valid) begin
                kernel_we    = 1'b1;
                kernel_waddr = '0;
                kernel_count_d = 1;

                if (KERNEL_WORDS == 1) begin
                    state_d = S_IDLE;
                    kernel_count_d = '0;
                end else begin
                    state_d = S_LOAD_KERNEL;
                end
            end
            else if (normalization_valid) begin
                norm_we         = 1'b1;
                norm_byte_index = '0;
                norm_count_d    = 1;

                if (NORM_WORDS == 1) begin
                    state_d = S_IDLE;
                    norm_count_d = '0;
                end else begin
                    state_d = S_LOAD_NORM;
                end
            end
            else if (pixel_valid) begin
                shiftreg_input_valid = 1'b1;
            end
        end

        S_LOAD_KERNEL: begin
            if (!kernel_valid || normalization_valid || pixel_valid) begin
                state_d = S_ERROR;
            end else begin
                kernel_we    = 1'b1;
                kernel_waddr = kernel_count_q;

                if (kernel_count_q == KERNEL_WORDS-1) begin
                    state_d = S_IDLE;
                    kernel_count_d = '0;
                end else begin
                    kernel_count_d = kernel_count_q + 1'b1;
                end
            end
        end

        S_LOAD_NORM: begin
            if (!normalization_valid || kernel_valid || pixel_valid) begin
                state_d = S_ERROR;
            end else begin
                norm_we         = 1'b1;
                norm_byte_index = norm_count_q;

                if (norm_count_q == NORM_WORDS-1) begin
                    state_d = S_IDLE;
                    norm_count_d = '0;
                end else begin
                    norm_count_d = norm_count_q + 1'b1;
                end
            end
        end

        S_ERROR: begin
            state_d = S_ERROR;
        end

        default: begin
            state_d = S_ERROR;
        end
    endcase
end

endmodule
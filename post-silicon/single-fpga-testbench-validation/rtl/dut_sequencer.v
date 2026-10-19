// DUT stimulus sequencer for conv_filter_top.
//
// On start: reset the DUT, program the kernel (25 consecutive kernel_valid
// cycles, row-major), program the normalization value (2 consecutive
// normalization_valid cycles, MSB first), then stream the input RAM as pixels,
// optionally inserting idle gaps. A drain period after the last pixel lets the
// DUT pipeline empty before done is raised.
//
// All DUT inputs are driven from posedge registers, matching the chip RTL
// testbenches (tb_conv_filter_top.sv). Everything after the start advances
// only on ce: tied high for the internal DUT (one beat per cycle), or pulsed
// once per link cycle by link_phy for an external DUT.
module dut_sequencer #(
    parameter KERNEL_WORDS = 25,
    parameter NUM_PIXELS   = 16384,
    parameter RESET_CYCLES = 8,
    parameter DRAIN_CYCLES = 64
) (
    input  wire                      clk,
    input  wire                      aresetn,
    input  wire                      start,
    input  wire                      ce,

    // Configuration (stable while busy)
    input  wire [KERNEL_WORDS*8-1:0] kernel,       // byte k = kernel[8k +: 8]
    input  wire [15:0]               norm,
    input  wire [15:0]               gap_every,    // insert a gap after every N pixels (0 = never)
    input  wire [15:0]               gap_cycles,   // length of each gap in cycles

    // Input RAM read port (1-cycle latency)
    output wire                      ram_en,
    output wire [11:0]               ram_addr,
    input  wire [31:0]               ram_dout,

    // DUT inputs
    output reg                       dut_reset_n,
    output reg                       kernel_valid,
    output reg                       normalization_valid,
    output reg                       pixel_valid,
    output reg  [7:0]                datain,

    // Status / debug
    output reg  [13:0]               stream_addr,
    output wire                      busy,
    output reg                       done
);

    localparam S_IDLE   = 3'd0,
               S_RST_LO = 3'd1,
               S_RST_HI = 3'd2,
               S_KERNEL = 3'd3,
               S_NORM   = 3'd4,
               S_STREAM = 3'd5,
               S_DRAIN  = 3'd6;

    reg [2:0]  state;
    reg [15:0] cnt;
    reg [15:0] gap_left;
    reg [15:0] since_gap;

    // Stage 1 (aligned with the BRAM read)
    reg        kv_q, nv_q, rd_q;
    reg [7:0]  cfg_q;
    reg [1:0]  lane_q;

    wire start_go  = start && !busy;
    wire in_gap    = (gap_left != 16'd0);
    wire issue     = (state == S_STREAM) && !in_gap && ce;
    wire last_pix  = (stream_addr == NUM_PIXELS - 1);

    assign ram_en   = issue;
    assign ram_addr = stream_addr[13:2];

    always @(posedge clk) begin
        if (!aresetn) begin
            state       <= S_IDLE;
            cnt         <= 16'd0;
            gap_left    <= 16'd0;
            since_gap   <= 16'd0;
            stream_addr <= 14'd0;
            dut_reset_n <= 1'b0;
            done        <= 1'b0;
        end else if (state == S_IDLE) begin
            // Starts are accepted on any cycle; later states wait for ce
            dut_reset_n <= 1'b1;
            if (start_go) begin
                done        <= 1'b0;
                cnt         <= 16'd0;
                dut_reset_n <= 1'b0;
                state       <= S_RST_LO;
            end
        end else if (ce) begin
            case (state)
                S_RST_LO: begin
                    cnt <= cnt + 16'd1;
                    if (cnt == RESET_CYCLES - 1) begin
                        cnt         <= 16'd0;
                        dut_reset_n <= 1'b1;
                        state       <= S_RST_HI;
                    end
                end

                // Wait out the DUT's internal reset synchronizer
                S_RST_HI: begin
                    cnt <= cnt + 16'd1;
                    if (cnt == RESET_CYCLES - 1) begin
                        cnt   <= 16'd0;
                        state <= S_KERNEL;
                    end
                end

                // cnt 0..KERNEL_WORDS-1 drive bytes, one idle cycle after
                S_KERNEL: begin
                    cnt <= cnt + 16'd1;
                    if (cnt == KERNEL_WORDS) begin
                        cnt   <= 16'd0;
                        state <= S_NORM;
                    end
                end

                // cnt 0..1 drive bytes, one idle cycle after
                S_NORM: begin
                    cnt <= cnt + 16'd1;
                    if (cnt == 16'd2) begin
                        cnt         <= 16'd0;
                        stream_addr <= 14'd0;
                        gap_left    <= 16'd0;
                        since_gap   <= 16'd0;
                        state       <= S_STREAM;
                    end
                end

                S_STREAM: begin
                    if (in_gap) begin
                        gap_left <= gap_left - 16'd1;
                    end else begin
                        stream_addr <= stream_addr + 14'd1;
                        if (gap_every != 16'd0 && since_gap == gap_every - 16'd1) begin
                            since_gap <= 16'd0;
                            gap_left  <= gap_cycles;
                        end else begin
                            since_gap <= since_gap + 16'd1;
                        end
                        if (last_pix) begin
                            cnt   <= 16'd0;
                            state <= S_DRAIN;
                        end
                    end
                end

                S_DRAIN: begin
                    cnt <= cnt + 16'd1;
                    if (cnt == DRAIN_CYCLES - 1) begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Stage 1: phase valids and config byte, delayed to line up with the RAM read
    always @(posedge clk) begin
        if (!aresetn) begin
            kv_q   <= 1'b0;
            nv_q   <= 1'b0;
            rd_q   <= 1'b0;
            cfg_q  <= 8'd0;
            lane_q <= 2'd0;
        end else if (ce) begin
            kv_q   <= (state == S_KERNEL) && (cnt < KERNEL_WORDS);
            nv_q   <= (state == S_NORM)   && (cnt < 16'd2);
            rd_q   <= issue;
            lane_q <= stream_addr[1:0];
            if (state == S_KERNEL)
                cfg_q <= kernel[cnt[4:0]*8 +: 8];
            else
                cfg_q <= (cnt == 16'd0) ? norm[15:8] : norm[7:0];
        end
    end

    // Stage 2: registered DUT inputs
    always @(posedge clk) begin
        if (!aresetn) begin
            kernel_valid        <= 1'b0;
            normalization_valid <= 1'b0;
            pixel_valid         <= 1'b0;
            datain              <= 8'd0;
        end else if (ce) begin
            kernel_valid        <= kv_q;
            normalization_valid <= nv_q;
            pixel_valid         <= rd_q;
            datain              <= rd_q ? ram_dout[lane_q*8 +: 8] : cfg_q;
        end
    end

    assign busy = (state != S_IDLE) || kv_q || nv_q || rd_q ||
                  kernel_valid || normalization_valid || pixel_valid;

endmodule

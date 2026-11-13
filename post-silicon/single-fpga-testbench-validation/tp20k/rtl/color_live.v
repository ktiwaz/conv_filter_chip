// Live mode for the colour camera pipeline (fabric clock): for every frame
// rgb_grab completes, while live mode is on and the DUT is idle, run the DUT
// once per channel (colour: R, G, B; gray: Y). Each run: plane_dma copies
// the channel from DDR3 into the DUT input RAM, then fpga_tb_core starts a
// live run on it (ext_start), and its output goes to color_frame's planes
// selected by ch_we (one channel, or all three for gray).
// A frame that arrives while the previous one is still being processed is
// skipped (ext_drop).
module color_live (
    input  wire       clk,
    input  wire       aresetn,

    // rgb_grab (DDR clock): a frame is complete in frame_bank when the toggle flips
    input  wire       frame_toggle,
    input  wire       frame_bank,

    input  wire       live,             // fpga_tb_core live_on
    input  wire       color,            // this frame: three colour runs (else one gray run)
    input  wire       busy,             // fpga_tb_core busy
    input  wire       run_done,         // fpga_tb_core disp_done (pulse at the end of a run)

    // plane_dma
    output reg        dma_bank,
    output reg  [1:0] dma_ch,
    output reg        dma_req_t,
    input  wire       dma_done_t,

    // fpga_tb_core / color_frame
    output reg        ext_frame,        // pulse: frame taken
    output reg        ext_drop,         // pulse: frame skipped
    output reg        ext_start,        // pulse: start the run
    output reg  [2:0] ch_we,
    output reg        frame_color       // the frame being shown is colour (overlay)
);

    (* ASYNC_REG = "TRUE" *) reg [2:0] ft_s = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] dd_s = 3'b000;
    wire new_frame = ft_s[2] != ft_s[1];
    wire dma_done  = dd_s[2] != dd_s[1];

    localparam S_IDLE = 3'd0, S_DMA = 3'd1, S_DMA_WAIT = 3'd2, S_START = 3'd3, S_RUN = 3'd4;
    reg [2:0] state;
    reg [1:0] c;                         // channel index of the current run
    reg       col;                       // colour frame (latched)

    always @(posedge clk) begin
        ft_s <= {ft_s[1:0], frame_toggle};
        dd_s <= {dd_s[1:0], dma_done_t};
        ext_frame <= 1'b0;
        ext_drop  <= 1'b0;
        ext_start <= 1'b0;
        if (!aresetn) begin
            state <= S_IDLE;
            ch_we <= 3'b111;
            frame_color <= 1'b0;
        end else case (state)
            S_IDLE: if (new_frame && live) begin
                if (busy) ext_drop <= 1'b1;      // e.g. a JTAG run in progress
                else begin
                    ext_frame <= 1'b1;
                    dma_bank  <= frame_bank;     // stable since the toggle
                    col       <= color;
                    c         <= 2'd0;
                    state     <= S_DMA;
                end
            end
            S_DMA: begin
                dma_ch    <= col ? c : 2'd3;
                dma_req_t <= !dma_req_t;
                state     <= S_DMA_WAIT;
            end
            S_DMA_WAIT: if (dma_done) state <= S_START;
            S_START: if (!live) state <= S_IDLE;   // live mode switched off meanwhile
            else if (!busy) begin
                ch_we       <= col ? (3'b001 << c) : 3'b111;
                frame_color <= col;
                ext_start   <= 1'b1;
                state       <= S_RUN;
            end
            S_RUN: if (run_done) begin
                if (col && c != 2'd2) begin
                    c     <= c + 2'd1;
                    state <= S_DMA;
                end else
                    state <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end

    initial dma_req_t = 1'b0;

endmodule

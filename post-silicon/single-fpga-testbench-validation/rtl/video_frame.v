// Display frame buffers between a DUT run (fabric clock) and the HDMI output
// (pixel clock).
//
// Two 128x128 8-bit images are kept per run: the image that was streamed
// into the DUT (in) and the DUT's output, already aligned to input pixel
// positions (out). Each is triple buffered, so the output never shows a
// half-written run and a new run never has to wait for the display:
//   - wr_bank:    written by the current run
//   - ready_bank: the most recent complete run
//   - disp_bank:  the bank the output is reading; it switches to ready_bank
//                 at the start of an output frame
// A run picks a write bank that is neither ready nor displayed.
module video_frame (
    // Fabric clock side (writes)
    input  wire        clk,
    input  wire        aresetn,
    input  wire        run_start,       // pulse: a DUT run begins
    input  wire        run_done,        // pulse: the run finished, its frame is complete
    input  wire [14:0] run_lo,          // output pixels written by the run: [run_lo, run_hi)
    input  wire [14:0] run_hi,
    input  wire        run_masked,      // hide the output's 2-pixel wrap-around border
    input  wire        in_we,
    input  wire [13:0] in_addr,
    input  wire [7:0]  in_data,
    input  wire        out_we,
    input  wire [13:0] out_addr,
    input  wire [7:0]  out_data,

    // Pixel clock side (reads, 1-cycle latency)
    input  wire        pclk,
    input  wire        prst,
    input  wire        frame_start,
    input  wire [13:0] rd_addr,
    output wire [7:0]  rd_in,
    output wire [7:0]  rd_out,
    output reg         has_frame,       // a run has completed since reset
    output reg  [14:0] disp_lo,         // valid output range / mask of the displayed bank
    output reg  [14:0] disp_hi,
    output reg         disp_masked
);

    //==================================================
    // Fabric side: bank bookkeeping
    //==================================================
    reg  [1:0] wr_bank, ready_bank;
    reg [14:0] ready_lo, ready_hi;
    reg        ready_masked;
    reg        ready_toggle;            // flips once ready_bank is stable
    reg        publish;
    (* ASYNC_REG = "TRUE" *) reg [1:0] disp_bank_c1, disp_bank_c2;
    reg  [1:0] disp_bank;               // pixel clock domain, below

    always @(posedge clk) begin
        disp_bank_c1 <= disp_bank;
        disp_bank_c2 <= disp_bank_c1;
    end

    // First bank that is neither ready nor (possibly) being displayed
    wire [1:0] free_bank = (ready_bank != 2'd0 && disp_bank_c2 != 2'd0) ? 2'd0 :
                           (ready_bank != 2'd1 && disp_bank_c2 != 2'd1) ? 2'd1 : 2'd2;

    always @(posedge clk) begin
        if (!aresetn) begin
            wr_bank      <= 2'd1;
            ready_bank   <= 2'd0;
            ready_toggle <= 1'b0;
            publish      <= 1'b0;
        end else begin
            publish <= 1'b0;
            if (run_start)
                wr_bank <= free_bank;
            if (run_done) begin
                ready_bank   <= wr_bank;
                ready_lo     <= run_lo;
                ready_hi     <= run_hi;
                ready_masked <= run_masked;
                publish      <= 1'b1;
            end
            // ready_bank settled last cycle; tell the pixel side to take it
            if (publish)
                ready_toggle <= ~ready_toggle;
        end
    end

    //==================================================
    // Pixel side: take the newest complete bank at each frame start
    //==================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] toggle_s;
    reg       seen_toggle;
    reg [1:0] ready_bank_p;
    reg [14:0] ready_lo_p, ready_hi_p;
    reg        ready_masked_p;

    always @(posedge pclk) begin
        if (prst) begin
            toggle_s     <= 3'd0;
            seen_toggle  <= 1'b0;
            ready_bank_p <= 2'd0;
            disp_bank    <= 2'd0;
            has_frame    <= 1'b0;
            disp_lo      <= 15'd0;
            disp_hi      <= 15'd0;
            disp_masked  <= 1'b0;
        end else begin
            toggle_s <= {toggle_s[1:0], ready_toggle};
            // ready_bank is stable whenever the synchronized toggle differs
            if (toggle_s[2] != seen_toggle) begin
                seen_toggle  <= toggle_s[2];
                ready_bank_p   <= ready_bank;
                ready_lo_p     <= ready_lo;
                ready_hi_p     <= ready_hi;
                ready_masked_p <= ready_masked;
                has_frame      <= 1'b1;
            end
            if (frame_start) begin
                disp_bank   <= ready_bank_p;
                disp_lo     <= ready_lo_p;
                disp_hi     <= ready_hi_p;
                disp_masked <= ready_masked_p;
            end
        end
    end

    //==================================================
    // Memories: 3 banks x 16384 bytes each
    //==================================================
    disp_ram in_ram (
        .clk_a(clk), .we(in_we), .waddr({wr_bank, in_addr}), .din(in_data),
        .clk_b(pclk), .raddr({disp_bank, rd_addr}), .dout(rd_in)
    );

    disp_ram out_ram (
        .clk_a(clk), .we(out_we), .waddr({wr_bank, out_addr}), .din(out_data),
        .clk_b(pclk), .raddr({disp_bank, rd_addr}), .dout(rd_out)
    );

endmodule

// Simple dual-port, dual-clock 8-bit block RAM (write on A, read on B)
module disp_ram #(
    parameter DEPTH = 3 * 16384
) (
    input  wire        clk_a,
    input  wire        we,
    input  wire [15:0] waddr,
    input  wire [7:0]  din,
    input  wire        clk_b,
    input  wire [15:0] raddr,
    output reg  [7:0]  dout
);

    (* ram_style = "block" *)
    reg [7:0] mem [0:DEPTH-1];

    integer k;
    initial begin
        for (k = 0; k < DEPTH; k = k + 1)
            mem[k] = 8'd0;
    end

    always @(posedge clk_a)
        if (we) mem[waddr] <= din;

    always @(posedge clk_b)
        dout <= mem[raddr];

endmodule

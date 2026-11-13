// Camera preview out of DDR3 for the display: source lines are fetched into a
// 4-line buffer (block RAM, written on the DDR clock, read on the pixel
// clock) ahead of the scan-out.
//
// Pixel clock side: the compositor reports at every display line which
// source line it is showing (need_s) and pulses frame_start once per frame;
// it reads pixels at {need_s[1:0], sx} (1-cycle latency). Line n lives in
// slot n % 4.
//
// DDR clock side: on a new frame the display bank becomes the writer's
// ready_bank (disp_bank, back to preview_wr so it's never overwritten) and
// fetching restarts at line 0; line n is fetched once need_s + 3 >= n, so a
// slot is only refilled after the display has moved past its line. need_s
// reaches the DDR side through a request/acknowledge toggle pair and is at
// worst a little old, which only delays fetches.
module preview_rd #(
    parameter BA_W        = 23,
    parameter [BA_W-1:0] BASE        = 0,
    parameter [BA_W-1:0] BANK_STRIDE = 23'h8000,
    parameter [BA_W-1:0] LINE_STRIDE = 64,
    parameter WIDTH       = 384,
    parameter HEIGHT      = 384
) (
    // pixel clock side
    input  wire            pclk,
    input  wire            prst,
    input  wire            frame_start,
    input  wire [8:0]      need_s,
    input  wire [10:0]     rd_addr,         // {slot, sx}
    output reg  [15:0]     rd_data,

    // DDR side
    input  wire            dclk,
    input  wire            drst,
    output reg             req,
    output reg  [BA_W-1:0] baddr,
    input  wire            gnt,
    input  wire            rvalid,
    input  wire [127:0]    rdata,
    input  wire [1:0]      ready_bank,
    output reg  [1:0]      disp_bank,
    output reg  [15:0]     lines_fetched     // debug
);

    localparam BX = WIDTH / 8;

    //==================================================
    // Line buffer: 4 slots x 512 pixels (2 block RAMs)
    //==================================================
    (* ram_style = "block" *)
    reg [15:0] lbuf [0:2047];
    reg        lb_we;
    reg [10:0] lb_wa;
    reg [15:0] lb_wd;
    always @(posedge dclk)
        if (lb_we) lbuf[lb_wa] <= lb_wd;
    always @(posedge pclk)
        rd_data <= lbuf[rd_addr];

    //==================================================
    // need_s / frame start: pixel clock -> DDR clock
    //==================================================
    reg        p_req_t = 1'b0, p_frame_t = 1'b0, p_pend_frame = 1'b0;
    reg [8:0]  p_s = 9'd0, p_sent = 9'd0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] p_ack_s = 3'b000;
    reg        d_ack_t = 1'b0;
    wire       p_idle = p_ack_s[2] == p_req_t;

    always @(posedge pclk) begin
        p_ack_s <= {p_ack_s[1:0], d_ack_t};
        if (frame_start) p_pend_frame <= 1'b1;
        if (p_idle && (p_pend_frame || frame_start || need_s != p_sent)) begin
            p_s     <= (p_pend_frame || frame_start) ? 9'd0 : need_s;
            p_sent  <= (p_pend_frame || frame_start) ? 9'd0 : need_s;
            if (p_pend_frame || frame_start) p_frame_t <= !p_frame_t;
            p_pend_frame <= 1'b0;
            p_req_t <= !p_req_t;
        end
    end

    reg        restart;                  // new frame, waiting for the reads to drain
    wire       frame_taken;              // the fetch engine picks a frame start up
    (* ASYNC_REG = "TRUE" *) reg [2:0] d_req_s = 3'b000;
    reg        d_frame_q = 1'b0;
    reg        d_frame_new = 1'b0;           // a frame start arrived, for the fetch engine
    reg [8:0]  d_need = 9'd0;
    wire d_new = d_req_s[2] != d_req_s[1];
    // Every request is acknowledged, also while drst is high: a request lost
    // during reset would leave the pixel clock side waiting forever (the DDR
    // PLL can lock after the video PLL)
    always @(posedge dclk) begin
        d_req_s <= {d_req_s[1:0], p_req_t};
        if (d_new) begin
            d_ack_t <= !d_ack_t;
            d_need  <= p_s;
            if (p_frame_t != d_frame_q) begin
                d_frame_q   <= p_frame_t;
                d_frame_new <= 1'b1;
            end
        end else if (frame_taken)
            d_frame_new <= 1'b0;
    end

    //==================================================
    // Fetch engine (DDR clock)
    //==================================================
    reg [8:0]  n;                        // line being fetched
    reg [5:0]  sub;                      // next burst of line n to request
    reg [5:0]  got;                      // bursts of line n received
    reg        active;                   // line n is being fetched
    reg [1:0]  inflight;                 // granted reads not yet returned
    assign     frame_taken = d_frame_new && !drst && !restart;
    reg [9:0]  lim;                      // d_need + 3: the last line that may be fetched
    reg        may_start;                // n may be fetched (registered: n < HEIGHT, n <= lim)
    reg        settle;                   // n / lim just changed, may_start is stale
    reg [3:0]  wcnt;                     // words of hold still to write
    reg [5:0]  hold_bx;
    reg [8:0]  hold_n;

    always @(posedge dclk) begin
        lb_we <= 1'b0;
        if (drst) begin
            req <= 1'b0;
            n <= 9'd0; sub <= 6'd0; got <= 6'd0; active <= 1'b0;
            inflight <= 2'd0; restart <= 1'b0;
            lim <= {1'b0, d_need} + 10'd3; may_start <= 1'b0; settle <= 1'b1;
            wcnt <= 4'd0;
            disp_bank <= 2'd0;
            lines_fetched <= 16'd0;
        end else begin
            may_start <= n < HEIGHT && {1'b0, n} <= lim;
            settle    <= 1'b0;
            if (d_new) begin
                lim     <= {1'b0, p_s} + 10'd3;
                settle  <= 1'b1;
            end
            if (d_frame_new && !restart)
                restart <= 1'b1;

            // grants and returns, always
            if (gnt) begin
                req <= 1'b0;
                sub <= sub + 6'd1;
            end
            inflight <= inflight + (gnt ? 2'd1 : 2'd0) - (rvalid ? 2'd1 : 2'd0);
            if (rvalid) begin
                hold_bx <= got;
                hold_n  <= n;
                wcnt    <= 4'd8;
                got     <= got + 6'd1;
                if (got == BX - 1) begin
                    active <= 1'b0;
                    settle <= 1'b1;
                    n <= n + 9'd1;
                    lines_fetched <= lines_fetched + 16'd1;
                end
            end

            if (restart) begin
                // new frame: once nothing is outstanding, show the newest
                // complete frame and fetch from line 0
                if (!req && !gnt && inflight == 2'd0 && !rvalid) begin
                    restart   <= 1'b0;
                    settle    <= 1'b1;
                    disp_bank <= ready_bank;
                    n <= 9'd0; sub <= 6'd0; got <= 6'd0; active <= 1'b0;
                end
            end else begin
                // start the next line when the display allows it
                if (!active && !rvalid && may_start && !settle) begin
                    active <= 1'b1;
                    sub    <= 6'd0;
                    got    <= 6'd0;
                end
                // keep one read queued behind the one in the controller
                // (sub - got = granted reads not yet returned)
                if (active && !req && !gnt && sub < BX && sub - got < 6'd2) begin
                    req   <= 1'b1;
                    baddr <= BASE + disp_bank * BANK_STRIDE + n * LINE_STRIDE + sub;
                end
            end

            // write the held burst into the line buffer, one pixel per cycle
            if (wcnt != 4'd0) begin
                lb_we <= 1'b1;
                lb_wa <= {hold_n[1:0], hold_bx, 3'd0} + (4'd8 - wcnt);
                lb_wd <= rdata[16 * (8 - wcnt) +: 16];   // stable until the next read completes
                wcnt  <= wcnt - 4'd1;
            end
        end
    end

endmodule

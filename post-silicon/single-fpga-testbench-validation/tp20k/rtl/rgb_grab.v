// Colour grabber: the 384x384 RGB565 camera frame (pix565 on PCLK) averaged
// 3x3 into 128x128 R, G, B and luminance Y = (54 R + 183 G + 18 B) >> 8
// (BT.709, as video_downscale), written to DDR3 for the DUT runs.
//
// Camera side: 3-pixel horizontal sums per channel, 128-entry column
// accumulators over 3 lines (LUT RAM), (sum * 7282 + 32768) >> 16 ~ sum / 9;
// one output pixel {Y, B, G, R} (32 bits) per 3x3 block into an async FIFO.
// DDR side: 4 pixels per burst, pixel n of a frame at burst BASE + bank *
// BANK_STRIDE + n / 4, word pair n % 4: byte 4k + c is channel c (0 R, 1 G,
// 2 B, 3 Y) of the k-th pixel of the burst. Two banks alternate; when a
// frame's last burst has been written, frame_bank (DDR clock) becomes its
// bank and frame_toggle flips. The fabric side samples frame_bank after
// seeing the toggle (stable for a whole frame by then).
module rgb_grab #(
    parameter BA_W = 23,
    parameter [BA_W-1:0] BASE        = 23'h020000,
    parameter [BA_W-1:0] BANK_STRIDE = 23'h001000     // 16384 pixels x 4 bytes
) (
    // camera side
    input  wire            rx_clk,
    input  wire            rx_rst,
    input  wire            ce,
    input  wire            px_de,
    input  wire            px_sol,
    input  wire            px_sof,
    input  wire [15:0]     px,
    output reg  [11:0]     h_active,        // measured pixels per line / lines per frame
    output reg  [11:0]     v_active,

    // DDR side
    input  wire            dclk,
    input  wire            drst,
    output reg             req,
    output reg  [BA_W-1:0] baddr,
    output reg  [127:0]    wdata,           // collected in place, held until gnt
    input  wire            gnt,
    output reg             frame_toggle,
    output reg             frame_bank,
    output reg  [15:0]     frames           // debug
);

    //==================================================
    // Camera side: position, channels
    //==================================================
    wire [4:0] r5 = px[15:11];
    wire [5:0] g6 = px[10:5];
    wire [4:0] b5 = px[4:0];
    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    reg        started;
    reg [8:0]  x, y;                     // position of the next pixel / current line
    reg [1:0]  xs, ys;                   // pixel / line within the 3x3 block
    reg [6:0]  xc, yr;                   // block column / row
    wire       v = ce && px_de;
    wire       new_line = px_sof || px_sol;
    // position of the pixel in this cycle
    wire [8:0] y_e  = px_sof ? 9'd0 : px_sol ? y + 9'd1 : y;
    wire [8:0] x_e  = new_line ? 9'd0 : x;
    wire [1:0] xs_e = new_line ? 2'd0 : xs;
    wire [6:0] xc_e = new_line ? 7'd0 : xc;
    wire [1:0] ys_e = px_sof ? 2'd0 : px_sol ? (ys == 2'd2 ? 2'd0 : ys + 2'd1) : ys;
    wire [6:0] yr_e = px_sof ? 7'd0 : (px_sol && ys == 2'd2) ? yr + 7'd1 : yr;

    // Column accumulators {B, G, R}, 12 bits each, in one block RAM. The
    // read is issued with the pixel (stage 0) and its data used in stage 1;
    // a column is written back at its block's last pixel and read again
    // three lines later, so there is no read-after-write hazard.
    (* ram_style = "block" *)
    reg [35:0] acc [0:127];
    reg [35:0] a_old;
    always @(posedge rx_clk)
        if (v) a_old <= acc[xc_e];

    // stage 1: registered pixel with its block position
    reg        s1_v;
    reg [1:0]  s1_xs, s1_ys;
    reg [6:0]  s1_col, s1_row;
    reg [7:0]  s1_r, s1_g, s1_b;
    always @(posedge rx_clk) begin
        s1_v <= 1'b0;
        if (rx_rst) begin
            started <= 1'b0;
            x <= 9'd0; y <= 9'd0; xs <= 2'd0; xc <= 7'd0; ys <= 2'd0; yr <= 7'd0;
        end else if (v) begin
            if (px_sof) started <= 1'b1;
            if (new_line) h_active <= {3'd0, x};
            if (px_sof)   v_active <= {3'd0, y} + 12'd1;
            x  <= x_e + 9'd1;
            y  <= y_e;
            xs <= xs_e == 2'd2 ? 2'd0 : xs_e + 2'd1;
            xc <= xs_e == 2'd2 ? xc_e + 7'd1 : xc_e;
            ys <= ys_e;
            yr <= yr_e;
            s1_v   <= (started || px_sof) && x_e < 9'd384 && y_e < 9'd384;
            s1_xs  <= xs_e;  s1_col <= xc_e;
            s1_ys  <= ys_e;  s1_row <= yr_e;
            s1_r <= r8; s1_g <= g8; s1_b <= b8;
        end
    end

    // stage 2: 3-pixel horizontal sums, added to the column accumulators
    reg  [9:0]  hs_r, hs_g, hs_b;        // sums of the block's first pixels in this line
    wire [9:0]  tr = (s1_xs == 2'd0 ? 10'd0 : hs_r) + s1_r;
    wire [9:0]  tg = (s1_xs == 2'd0 ? 10'd0 : hs_g) + s1_g;
    wire [9:0]  tb = (s1_xs == 2'd0 ? 10'd0 : hs_b) + s1_b;
    wire [11:0] ar = (s1_ys == 2'd0 ? 12'd0 : a_old[11:0])  + tr;
    wire [11:0] ag = (s1_ys == 2'd0 ? 12'd0 : a_old[23:12]) + tg;
    wire [11:0] ab = (s1_ys == 2'd0 ? 12'd0 : a_old[35:24]) + tb;

    reg        s2_v, s2_first;
    reg [11:0] s2_r, s2_g, s2_b;
    always @(posedge rx_clk) begin
        s2_v <= 1'b0;
        if (s1_v) begin
            if (s1_xs == 2'd2) begin
                acc[s1_col] <= {ab, ag, ar};
                if (s1_ys == 2'd2) begin
                    s2_v     <= 1'b1;
                    s2_first <= s1_row == 7'd0 && s1_col == 7'd0;
                    {s2_b, s2_g, s2_r} <= {ab, ag, ar};
                end
            end else begin
                hs_r <= tr; hs_g <= tg; hs_b <= tb;
            end
        end
    end

    // stage 3: / 9, then luminance of the averages (linear, so the same as
    // averaging the pixels' luminance, up to rounding)
    function [7:0] div9(input [11:0] s);
        reg [25:0] p;
        begin
            p = s * 26'd7282 + 26'd32768;
            div9 = p[23:16];
        end
    endfunction
    reg        s3_v, s3_first;
    reg [7:0]  s3_r, s3_g, s3_b;
    always @(posedge rx_clk) begin
        s3_v     <= s2_v;
        s3_first <= s2_first;
        s3_r <= div9(s2_r); s3_g <= div9(s2_g); s3_b <= div9(s2_b);
    end
    reg        s4_v, s4_first;
    reg [31:0] s4_pix;
    wire [15:0] lum = 16'd54 * s3_r + 16'd183 * s3_g + 16'd18 * s3_b;
    always @(posedge rx_clk) begin
        s4_v     <= s3_v;
        s4_first <= s3_first;
        s4_pix   <= {lum[15:8], s3_b, s3_g, s3_r};
    end

    //==================================================
    // FIFO to the DDR clock
    //==================================================
    wire        f_empty, f_rvalid, f_full;
    wire [32:0] f_rdata;
    reg         f_rd;
    async_fifo #(.DW(33), .AW(9)) fifo (
        .wclk(rx_clk), .wrst(1'b0), .wr(s4_v), .wdata({s4_first, s4_pix}), .full(f_full),
        .rclk(dclk), .rrst(drst), .rd(f_rd), .rdata(f_rdata), .rvalid(f_rvalid), .empty(f_empty)
    );

    //==================================================
    // DDR side: 4 pixels per burst, two banks
    //==================================================
    reg        d_started, wr_bank, last_pending;
    reg [13:0] n;                        // pixel index of the next pixel
    // the FIFO's block RAM output is registered first (timing)
    reg        q_valid;
    reg [32:0] q_data;
    always @(posedge dclk) begin
        q_valid <= f_rvalid;
        q_data  <= f_rdata;
    end
    wire       first = q_data[32];
    wire [13:0] n_e = first ? 14'd0 : n;

    always @(posedge dclk) begin
        f_rd <= 1'b0;
        if (drst) begin
            req <= 1'b0;
            d_started <= 1'b0;
            wr_bank <= 1'b0;
            frame_bank <= 1'b1;
            frame_toggle <= 1'b0;
            frames <= 16'd0;
            n <= 14'd0;
        end else begin
            // as preview_wr: no pop while a burst waits or right after the
            // pixel that completes one
            f_rd <= !req && !f_empty && !f_rd && !f_rvalid && !(q_valid && n_e[1:0] == 2'd3);
            if (gnt) begin
                req <= 1'b0;
                if (last_pending) begin
                    frame_bank   <= wr_bank;
                    frame_toggle <= !frame_toggle;
                    frames       <= frames + 16'd1;
                    wr_bank      <= !wr_bank;
                end
            end
            if (q_valid) begin
                if (first) d_started <= 1'b1;
                n <= n_e + 14'd1;
                wdata[32 * n_e[1:0] +: 32] <= q_data[31:0];
                if (n_e[1:0] == 2'd3 && (d_started || first)) begin
                    req   <= 1'b1;
                    baddr <= BASE + (wr_bank ? BANK_STRIDE : {BA_W{1'b0}}) + n_e[13:2];
                    last_pending <= n_e == 14'd16383;
                end
            end
        end
    end

endmodule

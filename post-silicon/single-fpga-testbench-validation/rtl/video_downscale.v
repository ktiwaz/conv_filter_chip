// HDMI-in frame grabber: 1280x720 RGB -> 128x128 grayscale for the DUT.
//
// In the recovered RX pixel clock domain:
//   1. frame/line detection from vde alone (a gap of more than two line
//      periods is the vertical blank), so sync polarity doesn't matter, plus
//      measurement of the active width/height
//   2. grayscale Y = (54 R + 183 G + 18 B) >> 8 (BT.709, as in the DE1
//      reference project's RGB_Process.v)
//   3. crop the centre 640x640 (x 320..959, y 40..679)
//   4. 5x5 box average: 5-pixel horizontal sums, a 128-entry column
//      accumulator over 5 rows, then (sum * 2621 + 32768) >> 16 ~= sum / 25
//   5. write into one bank of a 2-bank RAM; at the end of the crop window the
//      bank is published (frame_toggle flips, frame_bank is stable before it)
//
// The RAM is 32 bits wide (4 pixels per word, little-endian like the input
// RAM) so the DUT sequencer can read it exactly like the input RAM.
module video_downscale #(
    parameter CROP_X = 320,
    parameter CROP_Y = 40
) (
    input  wire        rx_clk,
    input  wire        rx_rst,          // synchronous to rx_clk
    input  wire [23:0] rx_data,         // {R, B, G} (Digilent dvi2rgb order)
    input  wire        rx_de,

    output reg         frame_toggle,    // flips when a 128x128 frame is complete
    output reg         frame_bank,      // bank holding that frame (stable before the flip)
    output reg  [11:0] h_active,        // measured active pixels per line
    output reg  [11:0] v_active,        // measured active lines per frame

    // Read port (fabric clock), 1-cycle latency
    input  wire        clk,
    input  wire        rd_en,
    input  wire        rd_bank,
    input  wire [11:0] rd_addr,         // 32-bit word address within the bank
    output reg  [31:0] rd_data
);

    //==================================================
    // 1. Line / frame position of the pixel on the bus
    //==================================================
    reg [11:0] x, y;                    // next x in this line; y of the current line
    reg [12:0] blank;                   // cycles since vde fell
    reg        de_q;
    reg        seen_frame;              // y is meaningful (a vertical blank was seen)

    wire        line_start = rx_de && !de_q;
    wire        new_frame  = line_start && (blank > 13'd4000);
    wire [11:0] cur_x      = de_q ? x : 12'd0;
    wire [11:0] cur_y      = new_frame ? 12'd0 : line_start ? y + 12'd1 : y;

    always @(posedge rx_clk) begin
        if (rx_rst) begin
            x <= 12'd0; y <= 12'd0; blank <= 13'd0; de_q <= 1'b0; seen_frame <= 1'b0;
            h_active <= 12'd0; v_active <= 12'd0;
        end else begin
            de_q <= rx_de;
            if (rx_de) begin
                x <= cur_x + 12'd1;
                y <= cur_y;
                if (new_frame) begin
                    if (seen_frame) v_active <= y + 12'd1;
                    seen_frame <= 1'b1;
                end
            end else if (de_q) begin
                h_active <= x;
                blank    <= 13'd0;
            end else if (blank != 13'h1FFF) begin
                blank <= blank + 13'd1;
            end
        end
    end

    reg [23:0] px_q;
    reg        px_de;
    reg [11:0] px_x, px_y;
    always @(posedge rx_clk) begin
        px_q  <= rx_data;
        px_de <= rx_de && (seen_frame || new_frame);
        px_x  <= cur_x;
        px_y  <= cur_y;
    end

    //==================================================
    // 2. Grayscale
    //==================================================
    wire [7:0] r = px_q[23:16];
    wire [7:0] bl = px_q[15:8];
    wire [7:0] g = px_q[7:0];

    reg [15:0] lum;
    reg        g_de;
    reg [11:0] g_x, g_y;
    always @(posedge rx_clk) begin
        lum  <= 16'd54 * r + 16'd183 * g + 16'd18 * bl;
        g_de <= px_de;
        g_x  <= px_x;
        g_y  <= px_y;
    end
    wire [7:0] gray = lum[15:8];

    //==================================================
    // 3 + 4. Crop and 5x5 box average
    //==================================================
    wire in_crop = g_de && (g_x >= CROP_X) && (g_x < CROP_X + 640) &&
                   (g_y >= CROP_Y) && (g_y < CROP_Y + 640);

    reg [2:0]  sub_x, sub_y;            // position inside the 5x5 block
    reg [6:0]  col, row;
    reg [10:0] hsum;
    reg [12:0] acc [0:127];             // column accumulators (LUT RAM)
    reg        crop_q;

    reg        wr_en;
    reg [13:0] wr_pix;
    reg [12:0] box_sum;
    reg        bank;
    reg        frame_end;

    always @(posedge rx_clk) begin
        wr_en     <= 1'b0;
        frame_end <= 1'b0;
        crop_q    <= in_crop;
        if (rx_rst) begin
            sub_x <= 3'd0; sub_y <= 3'd0; col <= 7'd0; row <= 7'd0; hsum <= 11'd0;
        end else if (in_crop) begin
            if (sub_x == 3'd4) begin
                sub_x <= 3'd0;
                hsum  <= 11'd0;
                col   <= col + 7'd1;
                if (sub_y == 3'd0)
                    acc[col] <= hsum + gray;
                else
                    acc[col] <= acc[col] + hsum + gray;
                if (sub_y == 3'd4) begin
                    wr_en   <= 1'b1;
                    wr_pix  <= {row, col};
                    box_sum <= acc[col] + hsum + gray;
                end
            end else begin
                sub_x <= sub_x + 3'd1;
                hsum  <= hsum + gray;
            end
        end else if (g_de && g_y < CROP_Y) begin
            // Above the crop window: start every frame at block row 0, so a
            // partial or irregular frame (e.g. the source restarting its
            // link) can't leave the row count out of step for good
            col <= 7'd0; sub_x <= 3'd0; hsum <= 11'd0;
            row <= 7'd0; sub_y <= 3'd0;
        end else if (crop_q) begin
            // Left the crop window at the end of a cropped line
            col   <= 7'd0;
            sub_x <= 3'd0;
            hsum  <= 11'd0;
            if (sub_y == 3'd4) begin
                sub_y <= 3'd0;
                if (row == 7'd127) begin
                    row       <= 7'd0;
                    frame_end <= 1'b1;
                end else begin
                    row <= row + 7'd1;
                end
            end else begin
                sub_y <= sub_y + 3'd1;
            end
        end
    end

    // ~ box_sum / 25, rounded
    wire [25:0] scaled = box_sum * 26'd2621 + 26'd32768;
    reg         w_en;
    reg  [13:0] w_pix;
    reg  [7:0]  w_val;
    always @(posedge rx_clk) begin
        w_en  <= wr_en;
        w_pix <= wr_pix;
        w_val <= scaled[23:16];
    end

    //==================================================
    // 5. Banked frame RAM and publication
    //==================================================
    // The toggle flips 3 cycles after frame_end: frame_bank has settled and
    // the last pixel (2 cycles behind frame_end in the w_* stage) is written
    reg [2:0] end_d;
    always @(posedge rx_clk) begin
        if (rx_rst) begin
            bank         <= 1'b0;
            frame_bank   <= 1'b0;
            frame_toggle <= 1'b0;
            end_d        <= 3'd0;
        end else begin
            end_d <= {end_d[1:0], frame_end};
            if (frame_end) begin
                frame_bank <= bank;
                bank       <= ~bank;
            end
            if (end_d[2])
                frame_toggle <= ~frame_toggle;
        end
    end

    (* ram_style = "block" *)
    reg [31:0] mem [0:8191];

    integer k;
    initial begin
        for (k = 0; k < 8192; k = k + 1)
            mem[k] = 32'd0;
    end

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            always @(posedge rx_clk)
                if (w_en && w_pix[1:0] == i)
                    mem[{bank, w_pix[13:2]}][i*8 +: 8] <= w_val;
        end
    endgenerate

    always @(posedge clk)
        if (rd_en)
            rd_data <= mem[{rd_bank, rd_addr}];

endmodule

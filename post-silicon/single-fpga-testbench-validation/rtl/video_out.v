// HDMI output: 720p60 timing -> compositor -> Digilent rgb2dvi (TMDS + OSERDES).
// Runs in the local TX pixel clock domain (pclk ~74.25 MHz, sclk = 5x pclk).
module video_out (
    input  wire        pclk,
    input  wire        sclk,
    input  wire        rst,           // async, high while the TX clocks are not locked

    // Display frame buffers (video_frame), 1-cycle read latency
    output wire        prst,
    output wire        frame_start,
    output wire [13:0] rd_addr,
    input  wire [7:0]  rd_in,
    input  wire [7:0]  rd_out,
    input  wire        has_frame,
    input  wire [14:0] out_lo,        // valid output range of the displayed bank
    input  wire [14:0] out_hi,
    input  wire        out_masked,    // hide the 2-pixel wrap-around border of the output
    input  wire        pattern,       // show the bring-up test pattern instead

    // Overlay text status (fabric clock domain, quasi-static; synchronized here)
    input  wire        st_live,
    input  wire        st_bypass,
    input  wire        st_ext,
    input  wire        st_custom,     // kernel/norm written over JTAG, not a preset
    input  wire [103:0] st_name,      // preset name, 13 ASCII chars
    input  wire [7:0]  st_fps,        // live runs per second, BCD

    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n
);

    // Reset synchronizer for the pixel clock domain
    reg [2:0] rst_sync = 3'b111;
    always @(posedge pclk or posedge rst) begin
        if (rst) rst_sync <= 3'b111;
        else     rst_sync <= {rst_sync[1:0], 1'b0};
    end
    assign prst = rst_sync[2];

    wire [7:0] r, g, b;
    wire       de, hs, vs;

    video_compositor comp (
        .pclk(pclk), .prst(prst),
        .frame_start(frame_start),
        .rd_addr(rd_addr), .rd_in(rd_in), .rd_out(rd_out),
        .has_frame(has_frame), .out_lo(out_lo), .out_hi(out_hi),
        .out_masked(out_masked), .pattern(pattern),
        .st_live(st_live), .st_bypass(st_bypass), .st_ext(st_ext), .st_custom(st_custom),
        .st_name(st_name), .st_fps(st_fps),
        .r(r), .g(g), .b(b), .de(de), .hs(hs), .vs(vs)
    );

    // TMDS encoder + serializer (Digilent rgb2dvi, pixel data is {R, B, G})
    rgb2dvi #(
        .kGenerateSerialClk(1'b0),
        .kRstActiveHigh(1'b1)
    ) tmds (
        .TMDS_Clk_p(tmds_clk_p),
        .TMDS_Clk_n(tmds_clk_n),
        .TMDS_Data_p(tmds_data_p),
        .TMDS_Data_n(tmds_data_n),
        .aRst(rst),
        .aRst_n(~rst),
        .vid_pData({r, b, g}),
        .vid_pVDE(de),
        .vid_pHSync(hs),
        .vid_pVSync(vs),
        .PixelClk(pclk),
        .SerialClk(sclk)
    );

endmodule

// 1280x720 picture: the DUT input (left) and output (right), each 128x128
// scaled 4x to 512x512, with 2-pixel white borders on a dark background,
// titles above the panes and a status line below.
// With pattern=1 it shows the bring-up test pattern instead (colour bars,
// 1-pixel white edge, bouncing square).
//
// Pipeline: timing outputs (c0) -> read address + region flags (c1) ->
// RAM data (c2) -> RAM data registered, text bits (c3) -> RGB and syncs (c4).
module video_compositor #(
    parameter PANE_L_X = 85,
    parameter PANE_R_X = 683,
    parameter PANE_Y   = 104,
    parameter PANE     = 512
) (
    input  wire        pclk,
    input  wire        prst,
    output wire        frame_start,
    output reg  [13:0] rd_addr,
    input  wire [7:0]  rd_in,
    input  wire [7:0]  rd_out,
    input  wire        has_frame,
    input  wire [14:0] out_lo,
    input  wire [14:0] out_hi,
    input  wire        out_masked,
    input  wire        pattern,
    input  wire        st_live,
    input  wire        st_bypass,
    input  wire        st_ext,
    input  wire        st_custom,
    input  wire [103:0] st_name,
    input  wire [7:0]  st_fps,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         de,
    output reg         hs,
    output reg         vs
);

    wire [11:0] x, y;
    wire        de0, hs0, vs0;

    video_timing timing (
        .clk(pclk), .rst(prst),
        .x(x), .y(y), .de(de0), .hs(hs0), .vs(vs0), .frame_start(frame_start)
    );

    //==================================================
    // Bouncing square for the test pattern
    //==================================================
    localparam SQ = 64;
    reg [11:0] sq_x, sq_y;
    reg        sq_dx, sq_dy;

    always @(posedge pclk) begin
        if (prst) begin
            sq_x <= 12'd100; sq_y <= 12'd100; sq_dx <= 1'b1; sq_dy <= 1'b1;
        end else if (frame_start) begin
            if (sq_dx) begin
                if (sq_x == 1280 - SQ - 1) sq_dx <= 1'b0; else sq_x <= sq_x + 12'd1;
            end else begin
                if (sq_x == 12'd1) sq_dx <= 1'b1; else sq_x <= sq_x - 12'd1;
            end
            if (sq_dy) begin
                if (sq_y == 720 - SQ - 1) sq_dy <= 1'b0; else sq_y <= sq_y + 12'd1;
            end else begin
                if (sq_y == 12'd1) sq_dy <= 1'b1; else sq_y <= sq_y - 12'd1;
            end
        end
    end

    //==================================================
    // c0 -> c1: regions and frame-buffer read address
    //==================================================
    wire in_l   = (x >= PANE_L_X) && (x < PANE_L_X + PANE) && (y >= PANE_Y) && (y < PANE_Y + PANE);
    wire in_r   = (x >= PANE_R_X) && (x < PANE_R_X + PANE) && (y >= PANE_Y) && (y < PANE_Y + PANE);
    wire near_l = (x + 2 >= PANE_L_X) && (x < PANE_L_X + PANE + 2) && (y + 2 >= PANE_Y) && (y < PANE_Y + PANE + 2);
    wire near_r = (x + 2 >= PANE_R_X) && (x < PANE_R_X + PANE + 2) && (y + 2 >= PANE_Y) && (y < PANE_Y + PANE + 2);

    wire [11:0] px = in_r ? x - PANE_R_X : x - PANE_L_X;
    wire [11:0] py = y - PANE_Y;
    wire [6:0]  col = px[8:2];
    wire [6:0]  row = py[8:2];

    reg       c1_l, c1_r, c1_border, c1_mask, c1_de, c1_hs, c1_vs;
    reg [23:0] c1_pat;

    wire        square = (x >= sq_x) && (x < sq_x + SQ) && (y >= sq_y) && (y < sq_y + SQ);
    wire [2:0]  bar    = x / 12'd160;
    wire        outer  = (x == 12'd0) || (x == 12'd1279) || (y == 12'd0) || (y == 12'd719);

    always @(posedge pclk) begin
        rd_addr   <= {row, col};
        c1_l      <= in_l;
        c1_r      <= in_r;
        c1_border <= (near_l && !in_l) || (near_r && !in_r);
        // Only show output pixels this run wrote, and (normal filtering) not
        // the 2-pixel border where the 5x5 window wraps across image edges
        c1_mask   <= in_r && (({1'b0, row, col} < out_lo) || ({1'b0, row, col} >= out_hi) ||
                              (out_masked && (row < 2 || row > 125 || col < 2 || col > 125)));
        c1_de     <= de0;
        c1_hs     <= hs0;
        c1_vs     <= vs0;
        if (outer)
            c1_pat <= 24'hFFFFFF;
        else if (square)
            c1_pat <= 24'hFF8000;
        else
            c1_pat <= {(bar == 0 || bar == 1 || bar == 4 || bar == 5) ? 8'hBF : 8'h00,
                       (bar == 0 || bar == 1 || bar == 2 || bar == 3) ? 8'hBF : 8'h00,
                       (bar == 0 || bar == 2 || bar == 4 || bar == 6) ? 8'hBF : 8'h00};
    end

    //==================================================
    // c1 -> c2: frame-buffer data arrives
    //==================================================
    reg       c2_l, c2_r, c2_border, c2_mask, c2_de, c2_hs, c2_vs;
    reg [23:0] c2_pat;

    always @(posedge pclk) begin
        {c2_l, c2_r, c2_border, c2_mask, c2_de, c2_hs, c2_vs} <=
            {c1_l, c1_r, c1_border, c1_mask, c1_de, c1_hs, c1_vs};
        c2_pat <= c1_pat;
    end

    //==================================================
    // Overlay text
    //==================================================
    (* ASYNC_REG = "TRUE" *) reg [117:0] st_s1, st_s2;
    always @(posedge pclk) begin
        st_s1 <= {st_live, st_bypass, st_ext, st_custom, st_name, st_fps, 2'b00};
        st_s2 <= st_s1;
    end
    wire         live_p   = st_s2[117];
    wire         bypass_p = st_s2[116];
    wire         ext_p    = st_s2[115];
    wire         custom_p = st_s2[114];
    wire [103:0] name_p   = st_s2[113:10];
    wire [7:0]   fps_p    = st_s2[9:2];

    wire [7:0] fps_tens = (fps_p[7:4] == 4'd0) ? 8'h20 : 8'h30 + fps_p[7:4];
    wire [7:0] fps_ones = 8'h30 + fps_p[3:0];

    wire [20*8-1:0] title_l = live_p ? "INPUT (HDMI IN)     " : "INPUT (JTAG IMAGE)  ";
    wire [21*8-1:0] title_r = bypass_p ? "BYPASS (NO FILTER)   " :
                              custom_p ? {"FILTER: ", "CUSTOM (JTAG)"} : {"FILTER: ", name_p};
    wire [15*8-1:0] mode_s  = live_p ? {"LIVE ", fps_tens, fps_ones, " FPS    "} : "STATIC IMAGE   ";
    wire [41*8-1:0] status  = {mode_s, "DUT: CHIP RTL ON ", ext_p ? "2ND FPGA " : "THIS FPGA"};

    wire on_l, on_r, on_s;
    text_line #(.X0(PANE_L_X), .Y0(PANE_Y - 32),        .LEN(20)) txt_l (.pclk(pclk), .x(x), .y(y), .text(title_l), .on(on_l));
    text_line #(.X0(PANE_R_X), .Y0(PANE_Y - 32),        .LEN(21)) txt_r (.pclk(pclk), .x(x), .y(y), .text(title_r), .on(on_r));
    text_line #(.X0(PANE_L_X), .Y0(PANE_Y + PANE + 14), .LEN(41)) txt_s (.pclk(pclk), .x(x), .y(y), .text(status),  .on(on_s));

    //==================================================
    // c2 -> c3: register the RAM data next to the text bits
    //==================================================
    reg       c3_l, c3_r, c3_border, c3_mask, c3_de, c3_hs, c3_vs;
    reg [23:0] c3_pat;
    reg [7:0]  c3_in, c3_out;

    always @(posedge pclk) begin
        {c3_l, c3_r, c3_border, c3_mask, c3_de, c3_hs, c3_vs} <=
            {c2_l, c2_r, c2_border, c2_mask, c2_de, c2_hs, c2_vs};
        c3_pat <= c2_pat;
        c3_in  <= rd_in;
        c3_out <= rd_out;
    end

    //==================================================
    // c3 -> c4: colour
    //==================================================
    always @(posedge pclk) begin
        de <= c3_de;
        hs <= c3_hs;
        vs <= c3_vs;
        if (!c3_de)
            {r, g, b} <= 24'h000000;
        else if (pattern)
            {r, g, b} <= c3_pat;
        else if (on_l || on_r)
            {r, g, b} <= 24'hFFFFFF;
        else if (on_s)
            {r, g, b} <= 24'hFFB000;
        else if (c3_border)
            {r, g, b} <= 24'hFFFFFF;
        else if (c3_l && has_frame)
            {r, g, b} <= {3{c3_in}};
        else if (c3_r && has_frame && !c3_mask)
            {r, g, b} <= {3{c3_out}};
        else if (c3_l || c3_r)
            {r, g, b} <= 24'h000000;
        else
            {r, g, b} <= 24'h202020;
    end

endmodule

// 1280x720 picture for the Tang Primer 20K camera pipeline: the colour camera
// preview (384x384 from DDR3 via preview_rd, shown 1.5x = 576x576) on the
// left and the 128x128 DUT output (4x = 512x512) on the right, 2-pixel white
// borders, titles above, a status line below. pattern = 1 shows colour bars.
// Derived from video_compositor (../../rtl/video_out.v).
//
// Pipeline: timing (c0) -> addresses + region flags (c1) -> RAM data (c2) ->
// RAM data registered, text bits (c3) -> RGB and syncs (c4).
// Preview source pixel of display offset p: floor(2p / 3) = (p * 683) >> 10,
// exact for p < 576.
module cam_compositor #(
    parameter PV_X  = 48,
    parameter PV_Y  = 80,
    parameter PV    = 576,
    parameter OUT_X = 704,
    parameter OUT_Y = 112,
    parameter OUT   = 512
) (
    input  wire        pclk,
    input  wire        prst,
    output wire        frame_start,

    // preview (preview_rd)
    output reg  [8:0]  need_s,          // source line of the current display line
    output reg  [10:0] pv_addr,         // {slot, sx}
    input  wire [15:0] pv_data,
    input  wire        pv_valid,        // a complete frame exists (pixel clock domain)

    // DUT output (video_frame)
    output reg  [13:0] rd_addr,
    input  wire [4:0]  rd_r,            // 1-cycle latency, 5 bits per channel
    input  wire [4:0]  rd_g,
    input  wire [4:0]  rd_b,
    input  wire        has_frame,
    input  wire [14:0] out_lo,
    input  wire [14:0] out_hi,
    input  wire        out_masked,

    input  wire        pattern,
    input  wire        st_color,        // the output is colour (three runs), else gray
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
    // c0 -> c1: regions and addresses
    //==================================================
    wire in_p   = (x >= PV_X) && (x < PV_X + PV) && (y >= PV_Y) && (y < PV_Y + PV);
    wire in_o   = (x >= OUT_X) && (x < OUT_X + OUT) && (y >= OUT_Y) && (y < OUT_Y + OUT);
    wire near_p = (x + 2 >= PV_X) && (x < PV_X + PV + 2) && (y + 2 >= PV_Y) && (y < PV_Y + PV + 2);
    wire near_o = (x + 2 >= OUT_X) && (x < OUT_X + OUT + 2) && (y + 2 >= OUT_Y) && (y < OUT_Y + OUT + 2);

    // preview source column / row: registered products, one line / pixel ahead
    wire [11:0] pxo = x - PV_X + 12'd1;              // the next pixel's offset
    reg  [19:0] sx_prod;
    reg  [19:0] sy_prod;
    wire [8:0]  sx = sx_prod[18:10];
    wire [8:0]  sy = sy_prod[18:10];
    always @(posedge pclk) begin
        sx_prod <= pxo[9:0] * 10'd683;
        if (x == 12'd0)
            sy_prod <= (y - PV_Y) * 10'd683;
        // the source line the display needs now (0 above the pane); sy_prod
        // holds this line's product from x = 1 on
        if (x == 12'd1)
            need_s <= (y < PV_Y) ? 9'd0 : (y >= PV_Y + PV) ? 9'd383 : sy_prod[18:10];
    end

    wire [11:0] ox = x - OUT_X;
    wire [11:0] oy = y - OUT_Y;
    wire [6:0]  col = ox[8:2];
    wire [6:0]  row = oy[8:2];

    reg        c1_p, c1_o, c1_border, c1_mask, c1_de, c1_hs, c1_vs;
    reg [23:0] c1_pat;

    // x / 160 as parallel compares (a divider is too slow at 74.25 MHz on GW2A)
    wire [2:0]  bar   = (x >= 12'd1120) ? 3'd7 : (x >= 12'd960) ? 3'd6 : (x >= 12'd800) ? 3'd5 :
                        (x >= 12'd640)  ? 3'd4 : (x >= 12'd480) ? 3'd3 : (x >= 12'd320) ? 3'd2 :
                        (x >= 12'd160)  ? 3'd1 : 3'd0;
    wire        outer = (x == 12'd0) || (x == 12'd1279) || (y == 12'd0) || (y == 12'd719);

    always @(posedge pclk) begin
        rd_addr   <= {row, col};
        pv_addr   <= {sy[1:0], sx};
        c1_p      <= in_p;
        c1_o      <= in_o;
        c1_border <= (near_p && !in_p) || (near_o && !in_o);
        c1_mask   <= in_o && (({1'b0, row, col} < out_lo) || ({1'b0, row, col} >= out_hi) ||
                              (out_masked && (row < 2 || row > 125 || col < 2 || col > 125)));
        c1_de     <= de0;
        c1_hs     <= hs0;
        c1_vs     <= vs0;
        if (outer)
            c1_pat <= 24'hFFFFFF;
        else
            c1_pat <= {(bar == 0 || bar == 1 || bar == 4 || bar == 5) ? 8'hBF : 8'h00,
                       (bar == 0 || bar == 1 || bar == 2 || bar == 3) ? 8'hBF : 8'h00,
                       (bar == 0 || bar == 2 || bar == 4 || bar == 6) ? 8'hBF : 8'h00};
    end

    //==================================================
    // c1 -> c2: RAM data arrives
    //==================================================
    reg       c2_p, c2_o, c2_border, c2_mask, c2_de, c2_hs, c2_vs;
    reg [23:0] c2_pat;
    always @(posedge pclk) begin
        {c2_p, c2_o, c2_border, c2_mask, c2_de, c2_hs, c2_vs} <=
            {c1_p, c1_o, c1_border, c1_mask, c1_de, c1_hs, c1_vs};
        c2_pat <= c1_pat;
    end

    //==================================================
    // Overlay text
    //==================================================
    // quasi-static status: one register stage (a rare mid-change sample only
    // shows for a frame)
    reg [117:0] st_s2;
    reg         color_p;
    always @(posedge pclk) begin
        st_s2   <= {st_live, st_bypass, st_ext, st_custom, st_name, st_fps, 2'b00};
        color_p <= st_color;
    end
    wire         live_p   = st_s2[117];
    wire         bypass_p = st_s2[116];
    wire         ext_p    = st_s2[115];
    wire         custom_p = st_s2[114];
    wire [103:0] name_p   = st_s2[113:10];
    wire [7:0]   fps_p    = st_s2[9:2];

    wire [7:0] fps_tens = (fps_p[7:4] == 4'd0) ? 8'h20 : 8'h30 + fps_p[7:4];
    wire [7:0] fps_ones = 8'h30 + fps_p[3:0];

    wire [20*8-1:0] title_l = "CAMERA 384X384      ";
    wire [21*8-1:0] title_r = bypass_p ? "BYPASS (NO FILTER)   " :
                              custom_p ? {"FILTER: ", "CUSTOM (JTAG)"} : {"FILTER: ", name_p};
    wire [15*8-1:0] mode_s  = live_p ? {"LIVE ", fps_tens, fps_ones, " FPS    "} : "STATIC IMAGE   ";
    wire [41*8-1:0] status  = {mode_s, color_p ? "COLOR " : "GRAY  ", "DUT ON ", ext_p ? "2ND FPGA   " : "THIS FPGA  ", "  "};

    // text_line copies its string into its own shift register outside the
    // text box, so the strings need no register here
    wire on_l, on_r, on_s;

    text_line #(.X0(PV_X),  .Y0(PV_Y - 32),      .LEN(20)) txt_l (.pclk(pclk), .x(x), .y(y), .text(title_l),   .on(on_l));
    text_line #(.X0(OUT_X), .Y0(OUT_Y - 32),     .LEN(21)) txt_r (.pclk(pclk), .x(x), .y(y), .text(title_r), .on(on_r));
    text_line #(.X0(PV_X),  .Y0(PV_Y + PV + 14), .LEN(41)) txt_s (.pclk(pclk), .x(x), .y(y), .text(status),  .on(on_s));

    //==================================================
    // c2 -> c3: register the RAM data next to the text bits
    //==================================================
    reg       c3_p, c3_o, c3_border, c3_mask, c3_de, c3_hs, c3_vs;
    reg [23:0] c3_pat;
    reg [15:0] c3_pv;
    reg [14:0] c3_out;
    always @(posedge pclk) begin
        {c3_p, c3_o, c3_border, c3_mask, c3_de, c3_hs, c3_vs} <=
            {c2_p, c2_o, c2_border, c2_mask, c2_de, c2_hs, c2_vs};
        c3_pat <= c2_pat;
        c3_pv  <= pv_data;
        c3_out <= {rd_r, rd_g, rd_b};
    end

    wire [4:0] pr = c3_pv[15:11];
    wire [5:0] pg = c3_pv[10:5];
    wire [4:0] pb = c3_pv[4:0];

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
        else if (c3_p && pv_valid)
            {r, g, b} <= {pr, pr[4:2], pg, pg[5:4], pb, pb[4:2]};
        else if (c3_o && has_frame && !c3_mask)
            {r, g, b} <= {c3_out[14:10], c3_out[14:12], c3_out[9:5], c3_out[9:7], c3_out[4:0], c3_out[4:2]};
        else if (c3_p || c3_o)
            {r, g, b} <= 24'h000000;
        else
            {r, g, b} <= 24'h202020;
    end

endmodule

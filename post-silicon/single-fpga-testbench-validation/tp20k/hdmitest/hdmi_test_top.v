// 640x480@60 DVI/HDMI test pattern for the Tang Primer 20K dock's HDMI port,
// open-source flow (OSER10 serializers + TLVDS_OBUF outputs).
//
// Clocks: 27 MHz -> rPLL -> 126 MHz serial clock (5x pixel, DDR) ->
// CLKDIV /5 -> 25.2 MHz pixel clock (standard 25.175 MHz, 0.1 % off).
//
// Pattern: 8 vertical colour bars on the top half; a gray ramp, then red,
// green and blue ramps on the bottom half; a 1-pixel white border to check
// the image edges; a small square bouncing around to show it's live.
// LEDs (active low): led0 PLL locked, led1 frame heartbeat.
// Needs ../rtl/tmds_encoder.v.
module hdmi_test_top (
    input  wire       clk27,
    input  wire       rst_n,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led_n
);

    //==================================================
    // Clocks
    //==================================================
    wire sclk, pclk, locked;

    rPLL #(
        .FCLKIN("27.0"),
        .IDIV_SEL(2),       // PFD 9 MHz
        .FBDIV_SEL(13),     // 9 * 14 = 126 MHz
        .ODIV_SEL(8)        // VCO 1008 MHz
    ) pll (
        .CLKIN(clk27), .CLKOUT(sclk), .LOCK(locked),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    CLKDIV #(.DIV_MODE("5")) pdiv (
        .HCLKIN(sclk), .RESETN(locked), .CALIB(1'b0), .CLKOUT(pclk)
    );

    reg [3:0] prst_sync = 4'hF;
    always @(posedge pclk or negedge locked)
        if (!locked) prst_sync <= 4'hF;
        else         prst_sync <= {prst_sync[2:0], !rst_n};
    wire prst = prst_sync[3];

    //==================================================
    // 640x480@60 timing (800 x 525 total, negative syncs)
    //==================================================
    localparam H_ACT = 640, H_FP = 16, H_SYNC = 96, H_BP = 48, H_TOT = 800;
    localparam V_ACT = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33, V_TOT = 525;

    reg [9:0] hc = 0, vc = 0;
    always @(posedge pclk) begin
        if (prst) begin
            hc <= 0;
            vc <= 0;
        end else if (hc == H_TOT - 1) begin
            hc <= 0;
            vc <= (vc == V_TOT - 1) ? 10'd0 : vc + 10'd1;
        end else begin
            hc <= hc + 10'd1;
        end
    end

    wire de    = (hc < H_ACT) && (vc < V_ACT);
    wire hsync = !((hc >= H_ACT + H_FP) && (hc < H_ACT + H_FP + H_SYNC));
    wire vsync = !((vc >= V_ACT + V_FP) && (vc < V_ACT + V_FP + V_SYNC));
    wire frame = (hc == 0) && (vc == V_ACT);       // once per frame, after the active area

    //==================================================
    // Pattern
    //==================================================
    reg [9:0] bx = 20, by = 20;
    reg       bdx = 1'b1, bdy = 1'b1;
    reg [5:0] fcount = 0;
    always @(posedge pclk) begin
        if (frame) begin
            fcount <= fcount + 6'd1;
            bx  <= bdx ? bx + 10'd2 : bx - 10'd2;
            by  <= bdy ? by + 10'd2 : by - 10'd2;
            if (bx >= H_ACT - 32 - 2) bdx <= 1'b0; else if (bx <= 2) bdx <= 1'b1;
            if (by >= V_ACT - 32 - 2) bdy <= 1'b0; else if (by <= 2) bdy <= 1'b1;
        end
    end

    // Column helpers stepped along with hc (no dividers on the pixel path):
    // bar = hc / 80, quarter = hc / 160, qx = hc % 160
    reg [6:0] b80 = 0;
    reg [2:0] bar = 0;
    reg [7:0] qx = 0;
    reg [1:0] quarter = 0;
    always @(posedge pclk) begin
        if (hc == H_TOT - 1) begin
            b80 <= 0; bar <= 0; qx <= 0; quarter <= 0;
        end else begin
            if (b80 == 79) begin b80 <= 0; bar <= bar + 3'd1; end
            else           b80 <= b80 + 7'd1;
            if (qx == 159) begin qx <= 0; quarter <= quarter + 2'd1; end
            else           qx <= qx + 8'd1;
        end
    end

    // Ramp 0..255 across a quarter: qx * 1.625, saturated
    wire [9:0] ramp_w = {2'b00, qx} + {3'b000, qx[7:1]} + {5'b00000, qx[7:3]};
    wire [7:0] ramp   = ramp_w[9:8] != 2'b00 ? 8'hFF : ramp_w[7:0];

    reg [23:0] rgb_c;   // {R, G, B}, combinational
    always @(*) begin
        if (hc == 0 || hc == H_ACT - 1 || vc == 0 || vc == V_ACT - 1)
            rgb_c = 24'hFFFFFF;
        else if (hc >= bx && hc < bx + 32 && vc >= by && vc < by + 32)
            rgb_c = 24'hFF8000;
        else if (vc < V_ACT / 2)
            case (bar)                           // 8 bars, 80 px each
                0: rgb_c = 24'hFFFFFF;
                1: rgb_c = 24'hFFFF00;
                2: rgb_c = 24'h00FFFF;
                3: rgb_c = 24'h00FF00;
                4: rgb_c = 24'hFF00FF;
                5: rgb_c = 24'hFF0000;
                6: rgb_c = 24'h0000FF;
                default: rgb_c = 24'h000000;
            endcase
        else
            case (quarter)
                0: rgb_c = {ramp, ramp, ramp};
                1: rgb_c = {ramp, 8'd0, 8'd0};
                2: rgb_c = {8'd0, ramp, 8'd0};
                default: rgb_c = {8'd0, 8'd0, ramp};
            endcase
    end

    // One pipeline stage: colour and the sync/enable signals together
    reg [23:0] rgb;
    reg        de_q, hsync_q, vsync_q;
    always @(posedge pclk) begin
        rgb     <= rgb_c;
        de_q    <= de;
        hsync_q <= hsync;
        vsync_q <= vsync;
    end

    //==================================================
    // TMDS encoding (DVI 1.0) and serialization
    //==================================================
    wire [9:0] sym_b, sym_g, sym_r;
    tmds_encoder enc_b (.clk(pclk), .rst(prst), .de(de_q), .data(rgb[7:0]),   .c({vsync_q, hsync_q}), .sym(sym_b));
    tmds_encoder enc_g (.clk(pclk), .rst(prst), .de(de_q), .data(rgb[15:8]),  .c(2'b00),          .sym(sym_g));
    tmds_encoder enc_r (.clk(pclk), .rst(prst), .de(de_q), .data(rgb[23:16]), .c(2'b00),          .sym(sym_r));

    wire [9:0] sym [0:3];
    assign sym[0] = sym_b;
    assign sym[1] = sym_g;
    assign sym[2] = sym_r;
    assign sym[3] = 10'b0000011111;              // TMDS clock: one pixel period

    wire [3:0] ser;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            OSER10 #(.GSREN("false"), .LSREN("true")) oser (
                .Q(ser[i]),
                .D0(sym[i][0]), .D1(sym[i][1]), .D2(sym[i][2]), .D3(sym[i][3]), .D4(sym[i][4]),
                .D5(sym[i][5]), .D6(sym[i][6]), .D7(sym[i][7]), .D8(sym[i][8]), .D9(sym[i][9]),
                .PCLK(pclk), .FCLK(sclk), .RESET(prst)
            );
        end
    endgenerate

    TLVDS_OBUF obuf_d0  (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF obuf_d1  (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF obuf_d2  (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    TLVDS_OBUF obuf_clk (.I(ser[3]), .O(tmds_clk_p),  .OB(tmds_clk_n));

    assign led_n = ~{4'b0000, fcount[5], locked};

endmodule

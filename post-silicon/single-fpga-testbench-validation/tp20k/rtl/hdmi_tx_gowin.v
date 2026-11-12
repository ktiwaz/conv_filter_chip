// DVI/HDMI transmitter for Gowin GW2A with the open-source flow: three TMDS
// encoders, 10:1 OSER10 serializers and true-LVDS output buffers. Replaces
// Digilent rgb2dvi (Xilinx) in the tp20k builds.
//
// sclk is the 5x pixel clock (OSER10 is DDR); pclk must come from sclk
// through CLKDIV /5 so the two are phase related. Syncs are passed through
// as-is (C0 = hs, C1 = vs on the blue channel), so their polarity is the
// timing generator's.
//
// The TLVDS_OBUF outputs need their _p and _n ports constrained to the A and
// B pins of a true-LVDS pair (one IO_LOC each, no IO_TYPE); see
// tp20k/hdmitest/hdmi_test.cst.
module hdmi_tx_gowin (
    input  wire       pclk,
    input  wire       sclk,
    input  wire       rst,          // synchronous to pclk
    input  wire [7:0] r,
    input  wire [7:0] g,
    input  wire [7:0] b,
    input  wire       de,
    input  wire       hs,
    input  wire       vs,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

    wire [9:0] sym_b, sym_g, sym_r;
    tmds_encoder enc_b (.clk(pclk), .rst(rst), .de(de), .data(b), .c({vs, hs}), .sym(sym_b));
    tmds_encoder enc_g (.clk(pclk), .rst(rst), .de(de), .data(g), .c(2'b00),    .sym(sym_g));
    tmds_encoder enc_r (.clk(pclk), .rst(rst), .de(de), .data(r), .c(2'b00),    .sym(sym_r));

    wire [9:0] sym [0:3];
    assign sym[0] = sym_b;
    assign sym[1] = sym_g;
    assign sym[2] = sym_r;
    assign sym[3] = 10'b0000011111;     // TMDS clock: one pixel period

    wire [3:0] ser;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            OSER10 #(.GSREN("false"), .LSREN("true")) oser (
                .Q(ser[i]),
                .D0(sym[i][0]), .D1(sym[i][1]), .D2(sym[i][2]), .D3(sym[i][3]), .D4(sym[i][4]),
                .D5(sym[i][5]), .D6(sym[i][6]), .D7(sym[i][7]), .D8(sym[i][8]), .D9(sym[i][9]),
                .PCLK(pclk), .FCLK(sclk), .RESET(rst)
            );
        end
    endgenerate

    TLVDS_OBUF obuf_d0  (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF obuf_d1  (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF obuf_d2  (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    TLVDS_OBUF obuf_clk (.I(ser[3]), .O(tmds_clk_p),  .OB(tmds_clk_n));

endmodule

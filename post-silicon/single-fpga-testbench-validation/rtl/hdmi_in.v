// HDMI input: Digilent dvi2rgb (TMDS deserializer, bit/channel alignment,
// EDID emulation on the DDC bus) for 1280x720 @ 60 Hz.
module hdmi_in #(
    parameter EDID_FILE = "edid_720p.data"   // 256 lines of 8 binary digits
) (
    input  wire        ref_clk_200,     // IDELAYCTRL reference
    input  wire        rst,             // async, high while ref_clk_200 is not stable

    input  wire        tmds_clk_p,
    input  wire        tmds_clk_n,
    input  wire [2:0]  tmds_data_p,
    input  wire [2:0]  tmds_data_n,
    inout  wire        ddc_scl,
    inout  wire        ddc_sda,
    output wire        hpd,             // hot-plug detect to the source

    output wire        rx_clk,          // recovered pixel clock
    output wire        rx_locked,
    output wire [23:0] rx_data,         // {R, B, G}
    output wire        rx_de,
    output wire        rx_hs,
    output wire        rx_vs
);

    // Tell the source a sink is present once the receiver can lock
    assign hpd = !rst;

    wire scl_i, scl_o, scl_t, sda_i, sda_o, sda_t;

    IOBUF scl_buf (.IO(ddc_scl), .I(scl_o), .O(scl_i), .T(scl_t));
    IOBUF sda_buf (.IO(ddc_sda), .I(sda_o), .O(sda_i), .T(sda_t));

    dvi2rgb #(
        .kEmulateDDC(1'b1),
        .kRstActiveHigh(1'b1),
        .kAddBUFG(1'b1),
        .kClkRange(2),                  // pixel clock >= 60 MHz
        .kEdidFileName(EDID_FILE),
        .kDebug(1'b0)
    ) rx (
        .TMDS_Clk_p(tmds_clk_p),
        .TMDS_Clk_n(tmds_clk_n),
        .TMDS_Data_p(tmds_data_p),
        .TMDS_Data_n(tmds_data_n),
        .RefClk(ref_clk_200),
        .aRst(rst),
        .aRst_n(!rst),
        .vid_pData(rx_data),
        .vid_pVDE(rx_de),
        .vid_pHSync(rx_hs),
        .vid_pVSync(rx_vs),
        .PixelClk(rx_clk),
        .SerialClk(),
        .aPixelClkLckd(),
        .pLocked(rx_locked),
        .SDA_I(sda_i),
        .SDA_O(sda_o),
        .SDA_T(sda_t),
        .SCL_I(scl_i),
        .SCL_O(scl_o),
        .SCL_T(scl_t),
        .pRst(1'b0),
        .pRst_n(1'b1)
    );

endmodule

/* verilator lint_off PINCONNECTEMPTY */
`include "ddr3/ddr3_ctrl.sv"
`include "ddr3/clk/ddr3_clk_2to1_tang_primer_20k.sv"
`include "ddr3/ddr3_phy_2to1.sv"

// DDR3 on the Tang Primer 20K core board (1 Gbit, x16): gowin-ddr3's
// ddr3_phy_2to1 and ddr3_ctrl with our BL8 burst-write patch
// and ddr3_phy_2to1 holding write data instead of a 9-stage pipeline
// (../ddr3/*.patch, applied into $(BUILD)/ddr3/ by the Makefile),
// on its own rPLL: dclk = CK = 94.5 MHz, DLL-off mode. (At 108 MHz, as in
// gowin-ddr3's example, about one masked write in 8000 landed one beat pair
// off on the low byte lane under load; 94.5 MHz leaves twice the bandwidth
// the camera pipeline needs.) Wiring as in
// gowin-ddr3's examples/tang-primer-20k-2to1/top.sv.
//
// User side (dclk): ddr3_ctrl's request interface, burst writes only
// (wr_burst is tied high), 26-bit word address {bank, row, column}.
module ddr3_sys (
    input          clk27,
    output         dclk,
    output         drst,                // high until the PLL locked + 128 cycles
    output         calib_done,
    output         calib_fail,

    input          rd,
    input          wr,
    input          refresh,
    input   [25:0] addr,
    input  [127:0] din_burst,
    input   [15:0] be_burst,
    output [127:0] dout_burst,
    output         data_ready,
    output         busy,

    output         ddr_ck,
    output         ddr_ck_n,
    output         ddr_reset_n,
    output         ddr_cke,
    output         ddr_cs_n,
    output         ddr_ras_n,
    output         ddr_cas_n,
    output         ddr_we_n,
    output         ddr_odt,
    output   [2:0] ddr_ba,
    output  [13:0] ddr_addr,
    output   [1:0] ddr_dm,
    inout    [1:0] ddr_dqs,
    inout    [1:0] ddr_dqs_n,
    inout   [15:0] ddr_dq
);

localparam DQ_W = 16, ROW_W = 13, COL_W = 10, BA_W = 3, DW = 6;
localparam LANES = DQ_W / 8;
localparam SYS_FREQ = 94_500_000;     // 27 MHz * 7 / 2
localparam TCK_PS = 1_000_000_000 / (SYS_FREQ / 1000);

// the Gowin IO logic models refer to GSR (as in gowin-ddr3's example)
GSR GSR(.GSRI(1'b1));

wire lock;
// IDIV 1, FBDIV 6: 27 * 7 / 2 = 94.5 MHz, VCO 94.5 * 8 = 756 MHz
ddr3_clk_2to1_tang_primer_20k #(.IDIV(1), .FBDIV(6), .ODIV(8)) clocks(.clkin(clk27), .clk(dclk), .lock(lock));

reg [7:0] reset_cnt = 0;
assign drst = !reset_cnt[7];
always @(posedge dclk) begin
    if (!lock) reset_cnt <= 0;
    else if (drst) reset_cnt <= reset_cnt + 1'd1;
end

wire ce, phy_reset_n, phy_cke, phy_odt, phy_wr, phy_rd, phy_rvalid, phy_ready;
wire [2:0] phy_cmd;
wire [ROW_W-1:0] phy_addr;
wire [BA_W-1:0] phy_ba;
wire [1:0] phy_wr_ph, phy_rd_ph, phy_wr_shift;
wire [8*DQ_W-1:0] phy_wdata, phy_rdata;
wire [DQ_W-1:0] phy_wmask;
wire [LANES*DW-1:0] phy_rd_delay;

ddr3_ctrl #(
    .DQ_W(DQ_W), .ROW_W(ROW_W), .COL_W(COL_W), .BA_W(BA_W),
    .NPH(1), .TCK_PS(TCK_PS), .CL(6), .CWL(6), .NWR(5), .DLL_OFF(1),
    .T_RFC_PS(110_000), .CAL_DW(DW), .CAL_STEPS(2 ** DW), .CAL_PER_LANE(1)
) ctrl (
    .clk(dclk), .ce(ce), .rst(drst),
    .rd(rd), .wr(wr), .refresh(refresh), .addr(addr), .din('0), .be('1),
    .wr_burst(1'b1), .din_burst(din_burst), .be_burst(be_burst),
    .dout(), .dout_burst(dout_burst), .data_ready(data_ready), .busy(busy),
    .init_done(), .calib_done(calib_done), .calib_fail(calib_fail),
    .phy_reset_n(phy_reset_n), .phy_cke(phy_cke), .phy_odt(phy_odt),
    .phy_cmd(phy_cmd), .phy_addr(phy_addr), .phy_ba(phy_ba),
    .phy_wr(phy_wr), .phy_wr_ph(phy_wr_ph), .phy_wdata(phy_wdata), .phy_wmask(phy_wmask),
    .phy_rd(phy_rd), .phy_rd_ph(phy_rd_ph), .phy_rd_delay(phy_rd_delay), .phy_wr_shift(phy_wr_shift),
    .phy_rvalid(phy_rvalid), .phy_rdata(phy_rdata), .phy_ready(phy_ready)
);

// the 1Gb chip has 13 row bits, A13 stays low
wire [ROW_W-1:0] ddr_row_addr;
assign ddr_addr = 14'(ddr_row_addr);

ddr3_phy_2to1 #(.DQ_W(DQ_W), .ROW_W(ROW_W), .BA_W(BA_W), .TCK_PS(TCK_PS), .DW(DW)) phy (
    .clk(dclk), .lock(lock), .ce(ce), .dbg_rx(),
    .phy_reset_n(phy_reset_n), .phy_cke(phy_cke), .phy_odt(phy_odt),
    .phy_cmd(phy_cmd), .phy_addr(phy_addr), .phy_ba(phy_ba),
    .phy_wr(phy_wr), .phy_wr_ph(phy_wr_ph), .phy_wdata(phy_wdata), .phy_wmask(phy_wmask),
    .phy_rd(phy_rd), .phy_rd_ph(phy_rd_ph), .phy_rd_delay(phy_rd_delay), .phy_wr_shift(phy_wr_shift),
    .phy_rvalid(phy_rvalid), .phy_rdata(phy_rdata), .phy_ready(phy_ready),
    .ddr_ck(ddr_ck), .ddr_ck_n(ddr_ck_n), .ddr_reset_n(ddr_reset_n), .ddr_cke(ddr_cke),
    .ddr_cs_n(ddr_cs_n), .ddr_ras_n(ddr_ras_n), .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n),
    .ddr_odt(ddr_odt), .ddr_ba(ddr_ba), .ddr_addr(ddr_row_addr), .ddr_dm(ddr_dm),
    .ddr_dqs(ddr_dqs), .ddr_dqs_n(ddr_dqs_n), .ddr_dq(ddr_dq)
);

endmodule

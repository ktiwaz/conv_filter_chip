// Camera connection check for the Tang Primer 20K dock DVP port (OV5640).
//
// The PC (scripts/camcheck.py) drives the camera's control pins and
// bit-bangs SCCB through these registers, over the same UART -> AXI bridge
// as the tester (third_party/core_dbg_bridge):
//
//   0x00 CTRL  RW  bit0 pwdn (1 = power down), bit1 rst_n, bit2 xclk enable,
//                  bit3 SCL low (open drain), bit4 SDA low (open drain)
//                  reset: power down, in reset, XCLK on, SCL/SDA released
//   0x04 PINS  R   bit0 SCL, bit1 SDA, bit2 VSYNC, bit3 HREF, bit4 PCLK,
//                  [15:8] D[7:0]   (synchronized samples)
//   0x08 PCLK  R   PCLK rising edges (free running, Gray-coded across domains)
//   0x0C VSYNC R   VSYNC rising edges
//   0x10 HREF  R   HREF rising edges
//   0x14 ID    R   0xCA3C_0001
module camcheck_top #(
    parameter CLK_HZ = 48_000_000,
    parameter BAUD   = 1_000_000
) (
    input  wire       clk27,
    input  wire       rst_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led_n,

    inout  wire       cmos_scl,
    inout  wire       cmos_sda,
    output wire       cmos_xclk,
    output wire       cmos_pwdn,
    output wire       cmos_rst_n,
    input  wire       cmos_pclk,
    input  wire       cmos_vsync,
    input  wire       cmos_href,
    input  wire [7:0] cmos_db
);

    //==================================================
    // Clock: 27 MHz -> 48 MHz; XCLK = 24 MHz
    //==================================================
    wire clk, locked;
    rPLL #(
        .FCLKIN("27.0"), .IDIV_SEL(8), .FBDIV_SEL(15), .ODIV_SEL(16)
    ) pll (
        .CLKIN(clk27), .CLKOUT(clk), .LOCK(locked),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    reg [3:0] rst_sync = 4'b0000;
    always @(posedge clk or negedge locked)
        if (!locked) rst_sync <= 4'b0000;
        else         rst_sync <= {rst_sync[2:0], rst_n};
    wire rst = !rst_sync[3];

    //==================================================
    // UART -> AXI
    //==================================================
    wire [31:0] awaddr, wdata, araddr;
    wire        awvalid, wvalid, bready, arvalid, rready;
    reg         bvalid, rvalid;
    reg  [31:0] rdata;
    wire        aw_go = awvalid && wvalid && !bvalid;

    dbg_bridge #(.CLK_FREQ(CLK_HZ), .UART_SPEED(BAUD)) bridge (
        .clk_i(clk), .rst_i(rst),
        .uart_rxd_i(uart_rx), .uart_txd_o(uart_tx),
        .mem_awvalid_o(awvalid), .mem_awaddr_o(awaddr), .mem_awid_o(),
        .mem_awlen_o(), .mem_awburst_o(), .mem_awready_i(aw_go),
        .mem_wvalid_o(wvalid), .mem_wdata_o(wdata), .mem_wstrb_o(),
        .mem_wlast_o(), .mem_wready_i(aw_go),
        .mem_bvalid_i(bvalid), .mem_bresp_i(2'b00), .mem_bid_i(4'd0), .mem_bready_o(bready),
        .mem_arvalid_o(arvalid), .mem_araddr_o(araddr), .mem_arid_o(),
        .mem_arlen_o(), .mem_arburst_o(), .mem_arready_i(!rvalid),
        .mem_rvalid_i(rvalid), .mem_rdata_i(rdata), .mem_rresp_i(2'b00),
        .mem_rid_i(4'd0), .mem_rlast_i(1'b1), .mem_rready_o(rready),
        .gpio_inputs_i(32'd0), .gpio_outputs_o()
    );

    //==================================================
    // Camera pins
    //==================================================
    reg [4:0] ctrl;
    wire pwdn = ctrl[0], cam_rst_n = ctrl[1], xclk_en = ctrl[2];
    wire scl_low = ctrl[3], sda_low = ctrl[4];

    reg xclk_q = 1'b0;
    always @(posedge clk) xclk_q <= xclk_en ? ~xclk_q : 1'b0;

    assign cmos_xclk  = xclk_q;
    assign cmos_pwdn  = pwdn;
    assign cmos_rst_n = cam_rst_n;
    assign cmos_scl   = scl_low ? 1'b0 : 1'bz;
    assign cmos_sda   = sda_low ? 1'b0 : 1'bz;

    // Synchronized pin samples
    reg [12:0] pins_m, pins_s;
    always @(posedge clk) begin
        pins_m <= {cmos_db, cmos_pclk, cmos_href, cmos_vsync, cmos_sda, cmos_scl};
        pins_s <= pins_m;
    end

    // PCLK edges counted in the PCLK domain, read through a Gray-code sync
    reg  [31:0] pclk_cnt = 32'd0, pclk_gray = 32'd0;
    always @(posedge cmos_pclk) begin
        pclk_cnt  <= pclk_cnt + 32'd1;
        pclk_gray <= (pclk_cnt + 32'd1) ^ ((pclk_cnt + 32'd1) >> 1);
    end
    reg [31:0] pclk_gray_m, pclk_gray_s;
    always @(posedge clk) begin
        pclk_gray_m <= pclk_gray;
        pclk_gray_s <= pclk_gray_m;
    end
    reg [31:0] pclk_bin;
    integer i;
    always @(*) begin
        pclk_bin[31] = pclk_gray_s[31];
        for (i = 30; i >= 0; i = i - 1)
            pclk_bin[i] = pclk_bin[i + 1] ^ pclk_gray_s[i];
    end

    // VSYNC / HREF rising edges (slow enough to count in the fabric clock)
    reg        vs_q, hr_q;
    reg [31:0] vs_cnt, hr_cnt;
    always @(posedge clk) begin
        vs_q <= pins_s[2];
        hr_q <= pins_s[3];
        if (rst) begin
            vs_cnt <= 32'd0;
            hr_cnt <= 32'd0;
        end else begin
            if (pins_s[2] && !vs_q) vs_cnt <= vs_cnt + 32'd1;
            if (pins_s[3] && !hr_q) hr_cnt <= hr_cnt + 32'd1;
        end
    end

    //==================================================
    // Registers
    //==================================================
    always @(posedge clk) begin
        if (rst) begin
            ctrl   <= 5'b00101;     // power down, in reset, XCLK on
            bvalid <= 1'b0;
            rvalid <= 1'b0;
            rdata  <= 32'd0;
        end else begin
            if (aw_go) begin
                if (awaddr[7:0] == 8'h00) ctrl <= wdata[4:0];
                bvalid <= 1'b1;
            end else if (bvalid && bready) begin
                bvalid <= 1'b0;
            end

            if (arvalid && !rvalid) begin
                rvalid <= 1'b1;
                case (araddr[7:0])
                    8'h00:   rdata <= {27'd0, ctrl};
                    8'h04:   rdata <= {16'd0, pins_s[12:5], 3'd0, pins_s[4:0]};
                    8'h08:   rdata <= pclk_bin;
                    8'h0C:   rdata <= vs_cnt;
                    8'h10:   rdata <= hr_cnt;
                    8'h14:   rdata <= 32'hCA3C_0001;
                    default: rdata <= 32'hDEAD_BEEF;
                endcase
            end else if (rvalid && rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    // LEDs (active low): heartbeat, VSYNC activity, PCLK activity, PWDN
    reg [24:0] hb = 25'd0;
    always @(posedge clk) hb <= hb + 25'd1;
    assign led_n = ~{2'b00, pwdn, pclk_bin[22], vs_cnt[2], hb[24]};

endmodule

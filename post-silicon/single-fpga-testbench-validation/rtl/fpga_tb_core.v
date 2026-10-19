// FPGA testbench core: JTAG/AXI-accessible input RAM, DUT sequencer,
// conv_filter_top DUT, capture sink, and capture RAM. Everything except
// vendor IP lives here so it can be simulated directly.
//
// AXI address map (byte addresses):
//   0x0000_0000 - 0x0000_3FFF  input RAM   (16384 x 8, packed 4 px/word, little-endian)
//   0x0001_0000 - 0x0001_3FFF  capture RAM (16384 x 8, same packing)
//   0x0002_0000  CTRL      W   bit0: start run (self-clearing)
//   0x0002_0004  STATUS    R   bit0: busy, bit1: done (sticky, cleared on start),
//                              bits[5:4]: DUT status (0 idle, 1 load kernel, 2 load norm, 3 error)
//   0x0002_0008  CAP_COUNT R   valid beats captured since last start (0..16384)
//   0x0002_000C  ID        R   0xC0F1_0003
//   0x0002_0010  CONFIG    RW  bit0: bypass (capture the raw pixel stream), bit1: DUT test_mode,
//                              bit2: ext (use the external DUT over the chip_* link pins)
//   0x0002_0014  NORM      RW  [15:0] normalization value, Q1.15 (reset 0x8000 = 1.0)
//   0x0002_0018  GAP       RW  [31:16] insert a gap after every N pixels (0 = never),
//                              [15:0] gap length in cycles
//   0x0002_001C  LINK      RW  [7:0] H: link half period in fabric cycles (f = 25/H MHz),
//                              [15:8] S: output sample phase (fabric cycles after the
//                              link rising edge; default 0 = at the next rising
//                              edge). See link_phy.v.
//   0x0002_0040 - 0x0002_0058  KERNEL RW  25 signed bytes, row-major, byte k at 0x40 + k
module fpga_tb_core #(
    parameter INIT_FILE = "input_image_w32.hex",
    parameter ID_WIDTH  = 1
) (
    input  wire                  clk,
    input  wire                  aresetn,     // synchronous, active low
    input  wire                  start_sw,    // asynchronous switch; rising edge starts a run

    // AXI4 slave (from jtag_axi)
    input  wire [ID_WIDTH-1:0]   s_axi_awid,
    input  wire [31:0]           s_axi_awaddr,
    input  wire [7:0]            s_axi_awlen,
    input  wire [2:0]            s_axi_awsize,
    input  wire [1:0]            s_axi_awburst,
    input  wire                  s_axi_awvalid,
    output wire                  s_axi_awready,
    input  wire [31:0]           s_axi_wdata,
    input  wire [3:0]            s_axi_wstrb,
    input  wire                  s_axi_wlast,
    input  wire                  s_axi_wvalid,
    output wire                  s_axi_wready,
    output wire [ID_WIDTH-1:0]   s_axi_bid,
    output wire [1:0]            s_axi_bresp,
    output wire                  s_axi_bvalid,
    input  wire                  s_axi_bready,
    input  wire [ID_WIDTH-1:0]   s_axi_arid,
    input  wire [31:0]           s_axi_araddr,
    input  wire [7:0]            s_axi_arlen,
    input  wire [2:0]            s_axi_arsize,
    input  wire [1:0]            s_axi_arburst,
    input  wire                  s_axi_arvalid,
    output wire                  s_axi_arready,
    output wire [ID_WIDTH-1:0]   s_axi_rid,
    output wire [31:0]           s_axi_rdata,
    output wire [1:0]            s_axi_rresp,
    output wire                  s_axi_rlast,
    output wire                  s_axi_rvalid,
    input  wire                  s_axi_rready,

    // Status / debug
    output wire                  busy,
    output wire                  done,
    output wire                  start_pulse,
    output wire [13:0]           stream_addr,
    output wire                  pixel_valid,
    output wire [7:0]            dut_dataout,
    output wire                  dut_output_valid,
    output wire [1:0]            dut_status,

    // Link to an external DUT (second FPGA or the chip)
    output wire                  chip_clk,
    output wire                  chip_reset_n,
    output wire                  chip_kernel_valid,
    output wire                  chip_normalization_valid,
    output wire                  chip_pixel_valid,
    output wire                  chip_test_mode,
    output wire [7:0]            chip_datain,
    input  wire [7:0]            chip_dataout,
    input  wire                  chip_output_valid,
    input  wire [1:0]            chip_status
);

    localparam [31:0] ID_VALUE = 32'hC0F1_0003;
    localparam [14:0] NUM_PIXELS = 15'd16384;
    localparam KERNEL_WORDS = 25;
    localparam KERNEL_REGS  = (KERNEL_WORDS + 3) / 4;

    //==================================================
    // AXI -> native bus
    //==================================================
    wire        m_en;
    wire [3:0]  m_we;
    wire [17:0] m_addr;
    wire [31:0] m_wdata;
    reg  [31:0] m_rdata;
    reg         m_rvalid;

    axi4_slave_native #(
        .ADDR_WIDTH(18),
        .ID_WIDTH(ID_WIDTH)
    ) axi_slave (
        .aclk(clk),
        .aresetn(aresetn),
        .s_axi_awid(s_axi_awid),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .m_en(m_en),
        .m_we(m_we),
        .m_addr(m_addr),
        .m_wdata(m_wdata),
        .m_rdata(m_rdata),
        .m_rvalid(m_rvalid)
    );

    //==================================================
    // Address decode
    //==================================================
    localparam SEL_IN   = 2'd0,
               SEL_CAP  = 2'd1,
               SEL_REGS = 2'd2;

    localparam R_CTRL      = 5'd0,
               R_STATUS    = 5'd1,
               R_CAP_COUNT = 5'd2,
               R_ID        = 5'd3,
               R_CONFIG    = 5'd4,
               R_NORM      = 5'd5,
               R_GAP       = 5'd6,
               R_LINK      = 5'd7,
               R_KERNEL    = 5'd16;   // 0x40

    wire [1:0]  sel     = m_addr[17:16];
    wire [11:0] word    = m_addr[13:2];
    wire [4:0]  reg_idx = m_addr[6:2];
    wire        in_en   = m_en && (sel == SEL_IN);
    wire        cap_en  = m_en && (sel == SEL_CAP);
    wire        reg_en  = m_en && (sel == SEL_REGS);
    wire        reg_wr  = reg_en && (m_we != 4'b0000);
    wire        ctrl_start = reg_wr && reg_idx == R_CTRL && m_we[0] && m_wdata[0];

    wire [31:0] in_a_dout, cap_a_dout;

    reg [14:0]  cap_count;
    reg [31:0]  reg_rdata;
    reg [1:0]   rd_sel_q;
    reg         rd_pend_q;

    //==================================================
    // Configuration registers
    //==================================================
    reg [31:0] config_r;
    reg [31:0] norm_r;
    reg [31:0] gap_r;
    reg [31:0] link_r;
    reg [31:0] kernel_r [0:KERNEL_REGS-1];

    wire bypass    = config_r[0];
    wire test_mode = config_r[1];
    wire ext       = config_r[2];

    // Apply byte strobes to a 32-bit register
    function [31:0] merge;
        input [31:0] old;
        input [31:0] new_data;
        input [3:0]  strb;
        integer b;
        begin
            for (b = 0; b < 4; b = b + 1)
                merge[b*8 +: 8] = strb[b] ? new_data[b*8 +: 8] : old[b*8 +: 8];
        end
    endfunction

    integer k;
    always @(posedge clk) begin
        if (!aresetn) begin
            config_r <= 32'd0;
            norm_r   <= 32'h0000_8000;
            gap_r    <= 32'd0;
            link_r   <= 32'h0000_0003;   // H=3 (8.33 MHz), S=0
            for (k = 0; k < KERNEL_REGS; k = k + 1)
                kernel_r[k] <= 32'd0;
        end else if (reg_wr) begin
            case (reg_idx)
                R_CONFIG: config_r <= merge(config_r, m_wdata, m_we) & 32'h7;
                R_NORM:   norm_r   <= merge(norm_r,   m_wdata, m_we) & 32'hFFFF;
                R_GAP:    gap_r    <= merge(gap_r,    m_wdata, m_we);
                R_LINK:   link_r   <= merge(link_r,   m_wdata, m_we) & 32'hFFFF;
                default: begin
                    if (reg_idx >= R_KERNEL && reg_idx < R_KERNEL + KERNEL_REGS)
                        kernel_r[reg_idx - R_KERNEL] <= merge(kernel_r[reg_idx - R_KERNEL], m_wdata, m_we);
                end
            endcase
        end
    end

    wire [KERNEL_REGS*32-1:0] kernel_flat;
    genvar g;
    generate
        for (g = 0; g < KERNEL_REGS; g = g + 1) begin : g_kernel
            assign kernel_flat[g*32 +: 32] = kernel_r[g];
        end
    endgenerate

    //==================================================
    // Read return: RAM output is valid one cycle after m_en, then registered.
    //==================================================
    always @(posedge clk) begin
        if (!aresetn) begin
            rd_pend_q <= 1'b0;
            m_rvalid  <= 1'b0;
        end else begin
            rd_pend_q <= m_en && (m_we == 4'b0000);
            m_rvalid  <= rd_pend_q;
        end

        if (m_en) begin
            rd_sel_q <= sel;
            case (reg_idx)
                R_STATUS:    reg_rdata <= {26'd0, dut_status, 2'd0, done, busy};
                R_CAP_COUNT: reg_rdata <= {17'd0, cap_count};
                R_ID:        reg_rdata <= ID_VALUE;
                R_CONFIG:    reg_rdata <= config_r;
                R_NORM:      reg_rdata <= norm_r;
                R_GAP:       reg_rdata <= gap_r;
                R_LINK:      reg_rdata <= link_r;
                default: begin
                    if (reg_idx >= R_KERNEL && reg_idx < R_KERNEL + KERNEL_REGS)
                        reg_rdata <= kernel_r[reg_idx - R_KERNEL];
                    else
                        reg_rdata <= 32'd0;
                end
            endcase
        end

        case (rd_sel_q)
            SEL_IN:   m_rdata <= in_a_dout;
            SEL_CAP:  m_rdata <= cap_a_dout;
            SEL_REGS: m_rdata <= reg_rdata;
            default:  m_rdata <= 32'd0;
        endcase
    end

    //==================================================
    // Start: synchronized rising edge of the switch, or CTRL.start
    //==================================================
    reg [2:0] sw_sync;
    always @(posedge clk) begin
        if (!aresetn)
            sw_sync <= 3'b111;  // a switch already high at reset doesn't start a run
        else
            sw_sync <= {sw_sync[1:0], start_sw};
    end

    assign start_pulse = (sw_sync[1] && !sw_sync[2]) || ctrl_start;

    // Starts are ignored while a run is still in flight.
    wire start_go = start_pulse && !busy;

    //==================================================
    // DUT sequencer: reset, kernel, normalization, then pixels from the input RAM
    //==================================================
    wire        in_b_en;
    wire [11:0] in_b_addr;
    wire [31:0] in_b_dout;

    wire        seq_ce;
    wire        dut_reset_n;
    wire        kernel_valid;
    wire        normalization_valid;
    wire [7:0]  datain;

    dut_sequencer #(
        .KERNEL_WORDS(KERNEL_WORDS),
        .NUM_PIXELS(NUM_PIXELS)
    ) sequencer (
        .clk(clk),
        .aresetn(aresetn),
        .start(start_pulse),
        .ce(seq_ce),
        .kernel(kernel_flat[KERNEL_WORDS*8-1:0]),
        .norm(norm_r[15:0]),
        .gap_every(gap_r[31:16]),
        .gap_cycles(gap_r[15:0]),
        .ram_en(in_b_en),
        .ram_addr(in_b_addr),
        .ram_dout(in_b_dout),
        .dut_reset_n(dut_reset_n),
        .kernel_valid(kernel_valid),
        .normalization_valid(normalization_valid),
        .pixel_valid(pixel_valid),
        .datain(datain),
        .stream_addr(stream_addr),
        .busy(busy),
        .done(done)
    );

    //==================================================
    // Link to the external DUT. In internal mode it idles and ce stays high.
    //==================================================
    wire       ext_strobe;
    wire [7:0] ext_dataout;
    wire       ext_output_valid;
    wire [1:0] ext_status;

    link_phy link (
        .clk(clk),
        .aresetn(aresetn),
        .enable(ext),
        .half(link_r[7:0]),
        .sample(link_r[15:8]),
        .ce(seq_ce),
        .dut_reset_n(dut_reset_n),
        .kernel_valid(kernel_valid),
        .normalization_valid(normalization_valid),
        .pixel_valid(pixel_valid),
        .test_mode(test_mode),
        .datain(datain),
        .out_strobe(ext_strobe),
        .out_dataout(ext_dataout),
        .out_output_valid(ext_output_valid),
        .out_status(ext_status),
        .chip_clk(chip_clk),
        .chip_reset_n(chip_reset_n),
        .chip_kernel_valid(chip_kernel_valid),
        .chip_normalization_valid(chip_normalization_valid),
        .chip_pixel_valid(chip_pixel_valid),
        .chip_test_mode(chip_test_mode),
        .chip_datain(chip_datain),
        .chip_dataout(chip_dataout),
        .chip_output_valid(chip_output_valid),
        .chip_status(chip_status)
    );

    //==================================================
    // Internal DUT: conv_filter_top in the taped-out configuration.
    // Held in reset while the external DUT is in use.
    //==================================================
    wire [7:0] int_dataout;
    wire       int_output_valid;
    wire [1:0] int_status;

    conv_filter_top #(
        .DATA_WIDTH(8),
        .KERNEL_SIZE(5),
        .LINE_WIDTH(128),
        .NORM_WIDTH(16)
    ) dut (
        .clk(clk),
        .reset_n(dut_reset_n && !ext),
        .kernel_valid(kernel_valid),
        .normalization_valid(normalization_valid),
        .pixel_valid(pixel_valid),
        .test_mode(test_mode),
        .datain(datain),
        .dataout(int_dataout),
        .output_valid(int_output_valid),
        .status(int_status)
    );

    // Selected DUT: one output beat per strobe from the link, or per cycle internally
    assign dut_dataout      = ext ? ext_dataout                   : int_dataout;
    assign dut_output_valid = ext ? ext_strobe && ext_output_valid : int_output_valid;
    assign dut_status       = ext ? ext_status                    : int_status;

    // Sequencer outputs change on the cycle after ce, so count each beat once
    reg beat_q;
    always @(posedge clk) beat_q <= seq_ce;

    // Bypass captures the raw pixel stream instead of the DUT output
    wire       cap_valid = bypass ? pixel_valid && beat_q : dut_output_valid;
    wire [7:0] cap_data  = bypass ? datain                : dut_dataout;

    //==================================================
    // Capture sink: capture RAM port B, byte writes at an incrementing address
    //==================================================
    wire cap_wr = cap_valid && (cap_count < NUM_PIXELS);

    always @(posedge clk) begin
        if (!aresetn)
            cap_count <= 15'd0;
        else if (start_go)
            cap_count <= 15'd0;
        else if (cap_wr)
            cap_count <= cap_count + 15'd1;
    end

    //==================================================
    // RAMs (4096 x 32 each)
    //==================================================
    bram_dp_be #(
        .ADDR_WIDTH(12),
        .NUM_BYTES(4),
        .INIT_FILE(INIT_FILE)
    ) input_ram (
        .clk(clk),
        .a_en(in_en),
        .a_we(m_we),
        .a_addr(word),
        .a_din(m_wdata),
        .a_dout(in_a_dout),
        .b_en(in_b_en),
        .b_we(4'b0000),
        .b_addr(in_b_addr),
        .b_din(32'd0),
        .b_dout(in_b_dout)
    );

    bram_dp_be #(
        .ADDR_WIDTH(12),
        .NUM_BYTES(4),
        .INIT_FILE("")
    ) capture_ram (
        .clk(clk),
        .a_en(cap_en),
        .a_we(m_we),
        .a_addr(word),
        .a_din(m_wdata),
        .a_dout(cap_a_dout),
        .b_en(cap_wr),
        .b_we(4'b0001 << cap_count[1:0]),
        .b_addr(cap_count[13:2]),
        .b_din({4{cap_data}}),
        .b_dout()
    );

endmodule

// I/O timing lab: measures board I/O + wire timing on one PYNQ-Z2 by
// sweeping an MMCM fine phase shift and counting PRBS-7 errors per lane.
//
// Clock domains (all from one MMCM, plus the looped-back forwarded clock):
//   clk     control: AXI registers, sweep engine, result RAM, MMCM PSCLK
//   clk_ref fixed phase: experiment A capture (IOB flops), forwarded clock
//   clk_ps  fine phase shifted: bus launch (IOB flops), experiment B2 capture
//   rclk    forwarded clock after its loopback, a pin and a BUFG (emulates
//           the DUT board): experiment B capture, B2 return launch
//
// Experiments:
//   A  (0): bus launched on clk_ps -> wires -> captured on clk_ref (IOB)
//   B  (1): bus launched on clk_ps -> wires -> captured on rclk (fabric flops)
//   B2 (2): PRBS launched on rclk (fabric flop) -> return wire -> clk_ps (IOB)
//
// Lane modes (bus launch): 0 single (lane under test PRBS, others low),
// 1 all (independent PRBS per lane), 2 sso (every lane carries the lane under
// test's PRBS), 3 aggressor (lane under test PRBS, others toggle each cycle),
// 4 static (lanes = STATIC register, for wiring checks).
//
// AXI address map (byte addresses):
//   0x0_0000  ID        R   0x10_1AB0_01
//   0x0_0004  CTRL      W   bit0 start sweep, bit1 abort
//   0x0_0008  STATUS    R   bit0 busy, bit1 done, bit2 a point timed out,
//                           [31:16] points completed
//   0x0_000C  CONFIG    RW  [1:0] experiment, [6:4] mode, [10:8] lane under test
//   0x0_0010  STEP      RW  phase-shift steps per point (1 step = VCO period / 56)
//   0x0_0014  POINTS    RW  points per sweep (max 2048)
//   0x0_0018  LOG2N     RW  samples per point = 2^LOG2N (1..24)
//   0x0_001C  STATIC    RW  [7:0] lane levels in static mode
//   0x0_0020  RX_A      R   [7:0] lanes as captured on clk_ref (live)
//   0x0_0024  RX_B      R   [7:0] lanes as captured on rclk (live)
//   0x0_0028  PHASE     R   net phase-shift steps applied since reset (signed)
//   0x0_002C  INFO      R   [7:0] clock divider (f = VCO / div), [15:8] wired lanes,
//                           [31:16] VCO frequency in MHz
//   0x0_0030  WIRING    R   0 pmod8, 1 pmod_fwd, 2 jumper, 3 pmod8_rev, 4 jumper_rev,
//                           5 jumper_check
//   0x0_0034  RCLK_HZ   R   rclk frequency, measured each second (0 = not looped back)
//   0x0_0040 + 4l  ONES R   lane l: ones counted at the last point (stuck-lane check)
//   0x2_0000  RESULTS   R   16 words per point p:
//                             word p*16 + l      lane l: all PRBS check failures
//                             word p*16 + 8 + l  lane l: {falling[15:0], rising[15:0]}:
//                               failures on samples where a 1->0 / 0->1 transition
//                               was expected (saturating). They separate the two
//                               edges' delays when rise and fall times differ.
module iolab_core #(
    parameter DIV     = 40,             // clk_ref/clk_ps = 1000 MHz / DIV
    parameter LANES   = 8,              // lanes actually wired
    parameter WIRING  = 0,
    parameter VCO_MHZ = 1000,
    parameter ID_WIDTH = 1
) (
    input  wire                clk,
    input  wire                aresetn,
    input  wire                clk_ref,
    input  wire                clk_ps,
    input  wire                rclk,

    // MMCM dynamic phase shift (PSCLK = clk)
    output reg                 psen,
    output wire                psincdec,
    input  wire                psdone,

    // AXI4 slave (from jtag_axi)
    input  wire [ID_WIDTH-1:0] s_axi_awid,
    input  wire [31:0]         s_axi_awaddr,
    input  wire [7:0]          s_axi_awlen,
    input  wire [2:0]          s_axi_awsize,
    input  wire [1:0]          s_axi_awburst,
    input  wire                s_axi_awvalid,
    output wire                s_axi_awready,
    input  wire [31:0]         s_axi_wdata,
    input  wire [3:0]          s_axi_wstrb,
    input  wire                s_axi_wlast,
    input  wire                s_axi_wvalid,
    output wire                s_axi_wready,
    output wire [ID_WIDTH-1:0] s_axi_bid,
    output wire [1:0]          s_axi_bresp,
    output wire                s_axi_bvalid,
    input  wire                s_axi_bready,
    input  wire [ID_WIDTH-1:0] s_axi_arid,
    input  wire [31:0]         s_axi_araddr,
    input  wire [7:0]          s_axi_arlen,
    input  wire [2:0]          s_axi_arsize,
    input  wire [1:0]          s_axi_arburst,
    input  wire                s_axi_arvalid,
    output wire                s_axi_arready,
    output wire [ID_WIDTH-1:0] s_axi_rid,
    output wire [31:0]         s_axi_rdata,
    output wire [1:0]          s_axi_rresp,
    output wire                s_axi_rlast,
    output wire                s_axi_rvalid,
    input  wire                s_axi_rready,

    // Pins
    output wire [7:0]          lane_out,
    input  wire [7:0]          lane_in,
    output wire                ret_out,
    input  wire                ret_in
);

    localparam [31:0] ID_VALUE  = 32'h101A_B001;
    localparam MAX_POINTS = 2048;       // x 16 words = the 32K-word result RAM

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
        .aclk(clk), .aresetn(aresetn),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize), .s_axi_awburst(s_axi_awburst),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize), .s_axi_arburst(s_axi_arburst),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rlast(s_axi_rlast), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .m_en(m_en), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_rvalid(m_rvalid)
    );

    //==================================================
    // Registers
    //==================================================
    localparam R_ID = 7'd0, R_CTRL = 7'd1, R_STATUS = 7'd2, R_CONFIG = 7'd3,
               R_STEP = 7'd4, R_POINTS = 7'd5, R_LOG2N = 7'd6, R_STATIC = 7'd7,
               R_RX_A = 7'd8, R_RX_B = 7'd9, R_PHASE = 7'd10, R_INFO = 7'd11,
               R_WIRING = 7'd12, R_RCLK_HZ = 7'd13, R_ONES = 7'd16;

    wire       sel_regs = !m_addr[17];
    wire       sel_res  = m_addr[17];
    wire [6:0] reg_idx  = m_addr[8:2];
    wire       reg_wr   = m_en && sel_regs && (m_we != 4'b0000);

    reg [1:0]  cfg_exp;
    reg [2:0]  cfg_mode;
    reg [2:0]  cfg_lane;
    reg [15:0] cfg_step;
    reg [11:0] cfg_points;
    reg [4:0]  cfg_log2n;
    reg [7:0]  cfg_static;

    wire start = reg_wr && reg_idx == R_CTRL && m_wdata[0];
    wire abort = reg_wr && reg_idx == R_CTRL && m_wdata[1];

    always @(posedge clk) begin
        if (!aresetn) begin
            cfg_exp <= 2'd0; cfg_mode <= 3'd1; cfg_lane <= 3'd0;
            cfg_step <= 16'd4; cfg_points <= 12'd560; cfg_log2n <= 5'd16; cfg_static <= 8'd0;
        end else if (reg_wr) begin
            case (reg_idx)
                R_CONFIG: begin cfg_exp <= m_wdata[1:0]; cfg_mode <= m_wdata[6:4]; cfg_lane <= m_wdata[10:8]; end
                R_STEP:   cfg_step   <= m_wdata[15:0];
                R_POINTS: cfg_points <= (m_wdata[11:0] > MAX_POINTS) ? MAX_POINTS : m_wdata[11:0];
                R_LOG2N:  cfg_log2n  <= (m_wdata[4:0] == 5'd0) ? 5'd1 : (m_wdata[4:0] > 5'd24) ? 5'd24 : m_wdata[4:0];
                R_STATIC: cfg_static <= m_wdata[7:0];
                default: ;
            endcase
        end
    end

    //==================================================
    // Launch: bus on clk_ps (IOB flops), return bit on rclk (fabric flop)
    //==================================================
    iol_launch #(.LANES(8)) launch_bus (
        .clk(clk_ps), .mode(cfg_mode), .lane(cfg_lane), .static_val(cfg_static),
        .out(lane_out)
    );

    // B2: the "DUT board" drives its return line from a fabric flop, like the
    // DUT's outputs (no IOB register)
    wire       ret_prbs;
    prbs7_gen #(.SEED(7'h5A)) ret_gen (.clk(rclk), .bit_out(ret_prbs));
    (* IOB = "FALSE" *) reg ret_q;
    always @(posedge rclk) ret_q <= ret_prbs;
    assign ret_out = ret_q;

    //==================================================
    // Capture and check
    //==================================================
    // A: IOB flops on clk_ref
    (* IOB = "TRUE" *) reg [7:0] a_q;
    always @(posedge clk_ref) a_q <= lane_in;

    // B: fabric flops on rclk, as the DUT board's inputs feed fabric logic
    (* IOB = "FALSE" *) reg [7:0] b_q;
    always @(posedge rclk) b_q <= lane_in;

    // B2: IOB flop on clk_ps
    (* IOB = "TRUE" *) reg r_q;
    always @(posedge clk_ps) r_q <= ret_in;

    reg  [2:0] chk_start;               // toggles, one per checker
    wire [2:0] chk_done;
    wire [8*32-1:0] err_a, err_b, ones_a, ones_b;
    wire [31:0]     err_r, ones_r;
    wire [8*32-1:0] rf_a, rf_b;        // per lane {falling, rising}
    wire [31:0]     rf_r;
    wire [7:0]      now_a, now_b;
    wire            now_r;

    iol_checker #(.LANES(8)) chk_a (
        .clk(clk_ref), .rx(a_q), .start_tog(chk_start[0]), .log2n(cfg_log2n),
        .done_tog(chk_done[0]), .err(err_a), .ones(ones_a), .rf(rf_a), .rx_now(now_a));
    iol_checker #(.LANES(8)) chk_b (
        .clk(rclk), .rx(b_q), .start_tog(chk_start[1]), .log2n(cfg_log2n),
        .done_tog(chk_done[1]), .err(err_b), .ones(ones_b), .rf(rf_b), .rx_now(now_b));
    iol_checker #(.LANES(1)) chk_r (
        .clk(clk_ps), .rx(r_q), .start_tog(chk_start[2]), .log2n(cfg_log2n),
        .done_tog(chk_done[2]), .err(err_r), .ones(ones_r), .rf(rf_r), .rx_now(now_r));

    (* ASYNC_REG = "TRUE" *) reg [2:0] done_s1, done_s2;
    reg [2:0] done_s3;
    always @(posedge clk) begin
        done_s1 <= chk_done;
        done_s2 <= done_s1;
        done_s3 <= done_s2;
    end
    wire [2:0] done_edge = done_s2 ^ done_s3;

    // Counts of the selected experiment (stable while its checker is idle).
    // store_word 0..7: total errors of lane store_word; 8..15: {fall, rise}.
    reg [31:0] sel_err, sel_ones, sel_rf;
    reg [3:0]  store_word;
    wire [2:0] store_lane = store_word[2:0];
    always @(*) begin
        case (cfg_exp)
            2'd1:    begin sel_err = err_b[store_lane*32 +: 32]; sel_ones = ones_b[store_lane*32 +: 32];
                           sel_rf  = rf_b[store_lane*32 +: 32]; end
            2'd2:    begin sel_err  = (store_lane == 0) ? err_r  : 32'd0;
                           sel_ones = (store_lane == 0) ? ones_r : 32'd0;
                           sel_rf   = (store_lane == 0) ? rf_r   : 32'd0; end
            default: begin sel_err = err_a[store_lane*32 +: 32]; sel_ones = ones_a[store_lane*32 +: 32];
                           sel_rf  = rf_a[store_lane*32 +: 32]; end
        endcase
    end

    //==================================================
    // Sweep engine
    //==================================================
    localparam S_IDLE = 3'd0, S_STEP = 3'd1, S_PSWAIT = 3'd2, S_SETTLE = 3'd3,
               S_MEAS = 3'd4, S_STORE = 3'd5;

    reg  [2:0]  state;
    reg  [15:0] steps_left;
    reg  [11:0] point;
    reg  [9:0]  settle;
    reg  [27:0] timeout;
    reg         done_flag, timed_out;
    reg         meas_ok;                // this point's counts are valid (no timeout)
    reg  signed [31:0] phase_pos;
    reg  [31:0] ones_r_lanes [0:7];

    assign psincdec = 1'b1;             // always step later; a full period wraps around

    wire        res_we   = (state == S_STORE);
    wire [14:0] res_addr = {point[10:0], store_word};
    wire [31:0] res_dout;

    integer i;
    always @(posedge clk) begin
        psen <= 1'b0;
        if (!aresetn) begin
            state <= S_IDLE; point <= 12'd0; steps_left <= 16'd0; settle <= 10'd0;
            timeout <= 28'd0; done_flag <= 1'b0; timed_out <= 1'b0; phase_pos <= 32'sd0;
            chk_start <= 3'd0; store_word <= 4'd0; meas_ok <= 1'b0;
            for (i = 0; i < 8; i = i + 1) ones_r_lanes[i] <= 32'd0;
        end else if (abort) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    point <= 12'd0; done_flag <= 1'b0; timed_out <= 1'b0;
                    steps_left <= cfg_step;
                    state <= S_STEP;
                end
                S_STEP: begin
                    if (steps_left == 16'd0) begin
                        settle <= 10'd0;
                        state  <= S_SETTLE;
                    end else begin
                        psen  <= 1'b1;
                        state <= S_PSWAIT;
                    end
                end
                S_PSWAIT: if (psdone) begin
                    steps_left <= steps_left - 16'd1;
                    phase_pos  <= phase_pos + 32'sd1;
                    state      <= S_STEP;
                end
                S_SETTLE: begin
                    settle <= settle + 10'd1;
                    if (&settle) begin
                        chk_start[cfg_exp] <= ~chk_start[cfg_exp];
                        timeout <= 28'd0;
                        state   <= S_MEAS;
                    end
                end
                S_MEAS: begin
                    timeout <= timeout + 28'd1;
                    if (done_edge[cfg_exp]) begin
                        meas_ok    <= 1'b1;
                        store_word <= 4'd0;
                        state      <= S_STORE;
                    end else if (&timeout) begin
                        // No clock in that domain (e.g. no clock loopback wired)
                        meas_ok    <= 1'b0;
                        timed_out  <= 1'b1;
                        store_word <= 4'd0;
                        state      <= S_STORE;
                    end
                end
                S_STORE: begin
                    if (!store_word[3]) ones_r_lanes[store_lane] <= sel_ones;
                    store_word <= store_word + 4'd1;
                    if (store_word == 4'd15) begin
                        point <= point + 12'd1;
                        if (point + 12'd1 == cfg_points) begin
                            done_flag <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            steps_left <= cfg_step;
                            state      <= S_STEP;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // Results: port B written by the engine, port A read over AXI
    bram_dp_be #(
        .ADDR_WIDTH(15),
        .NUM_BYTES(4),
        .INIT_FILE("")
    ) results (
        .clk(clk),
        .a_en(m_en && sel_res),
        .a_we(4'b0000),
        .a_addr(m_addr[16:2]),
        .a_din(32'd0),
        .a_dout(res_dout),
        .b_en(res_we),
        .b_we({4{res_we}}),
        .b_addr(res_addr),
        .b_din(!meas_ok ? 32'hFFFF_FFFF :          // all ones: point timed out
               store_word[3] ? sel_rf : sel_err),
        .b_dout()
    );

    //==================================================
    // rclk frequency (rclk cycles per second of clk; 50 MHz control clock)
    //==================================================
    reg [3:0]  rdiv = 4'd0;
    always @(posedge rclk) rdiv <= rdiv + 4'd1;   // count rclk/16 to stay below clk/2
    (* ASYNC_REG = "TRUE" *) reg [2:0] rdiv_s;
    reg [25:0] sec;
    reg [27:0] rcount;
    reg [31:0] rclk_hz;
    always @(posedge clk) begin
        rdiv_s <= {rdiv_s[1:0], rdiv[3]};
        if (!aresetn) begin
            sec <= 26'd0; rcount <= 28'd0; rclk_hz <= 32'd0;
        end else if (sec == 26'd49_999_999) begin
            sec     <= 26'd0;
            rclk_hz <= {rcount, 4'd0};
            rcount  <= 28'd0;
        end else begin
            sec <= sec + 26'd1;
            if (rdiv_s[2] && !rdiv_s[1]) rcount <= rcount + 28'd1;
        end
    end

    //==================================================
    // Register / result reads (2-cycle latency, like fpga_tb_core)
    //==================================================
    (* ASYNC_REG = "TRUE" *) reg [7:0] now_a_s, now_b_s;
    always @(posedge clk) begin
        now_a_s <= now_a;
        now_b_s <= now_b;
    end

    reg        rd_pend, rd_res;
    reg [31:0] reg_rdata;
    always @(posedge clk) begin
        if (!aresetn) begin
            rd_pend  <= 1'b0;
            m_rvalid <= 1'b0;
        end else begin
            rd_pend  <= m_en && (m_we == 4'b0000);
            m_rvalid <= rd_pend;
        end
        if (m_en) begin
            rd_res <= sel_res;
            case (reg_idx)
                R_ID:      reg_rdata <= ID_VALUE;
                R_STATUS:  reg_rdata <= {4'd0, point, 13'd0, timed_out, done_flag, state != S_IDLE};
                R_CONFIG:  reg_rdata <= {21'd0, cfg_lane, 1'b0, cfg_mode, 2'd0, cfg_exp};
                R_STEP:    reg_rdata <= {16'd0, cfg_step};
                R_POINTS:  reg_rdata <= {20'd0, cfg_points};
                R_LOG2N:   reg_rdata <= {27'd0, cfg_log2n};
                R_STATIC:  reg_rdata <= {24'd0, cfg_static};
                R_RX_A:    reg_rdata <= {24'd0, now_a_s};
                R_RX_B:    reg_rdata <= {24'd0, now_b_s};
                R_PHASE:   reg_rdata <= phase_pos;
                R_INFO:    reg_rdata <= {VCO_MHZ[15:0], LANES[7:0], DIV[7:0]};
                R_WIRING:  reg_rdata <= WIRING;
                R_RCLK_HZ: reg_rdata <= rclk_hz;
                default:   reg_rdata <= (reg_idx >= R_ONES && reg_idx < R_ONES + 8) ?
                                        ones_r_lanes[reg_idx - R_ONES] : 32'd0;
            endcase
        end
        m_rdata <= rd_res ? res_dout : reg_rdata;
    end

endmodule

// PRBS-7 (x^7 + x^6 + 1) generator: b[n] = b[n-7] ^ b[n-6]
module prbs7_gen #(
    parameter [6:0] SEED = 7'h01        // any non-zero value
) (
    input  wire clk,
    output wire bit_out
);
    reg [6:0] s = SEED;                 // s[0] newest bit, s[6] oldest
    assign bit_out = s[6] ^ s[5];
    always @(posedge clk) s <= {s[5:0], bit_out};
endmodule

// Bus launch patterns, registered into IOB flops
module iol_launch #(
    parameter LANES = 8
) (
    input  wire             clk,
    input  wire [2:0]       mode,       // quasi-static (control clock domain)
    input  wire [2:0]       lane,
    input  wire [LANES-1:0] static_val,
    output wire [LANES-1:0] out
);
    (* ASYNC_REG = "TRUE" *) reg [2:0] mode_s1, mode_s2, lane_s1, lane_s2;
    (* ASYNC_REG = "TRUE" *) reg [LANES-1:0] stat_s1, stat_s2;
    always @(posedge clk) begin
        mode_s1 <= mode;       mode_s2 <= mode_s1;
        lane_s1 <= lane;       lane_s2 <= lane_s1;
        stat_s1 <= static_val; stat_s2 <= stat_s1;
    end

    wire [LANES-1:0] prbs;
    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_gen
            // Different seeds: shifted copies of the sequence, uncorrelated per bit
            prbs7_gen #(.SEED(g * 17 + 1)) gen (.clk(clk), .bit_out(prbs[g]));
        end
    endgenerate

    reg toggle = 1'b0;
    always @(posedge clk) toggle <= ~toggle;

    reg [LANES-1:0] next;
    integer i;
    always @(*) begin
        for (i = 0; i < LANES; i = i + 1) begin
            case (mode_s2)
                3'd0:    next[i] = (i == lane_s2) ? prbs[i] : 1'b0;         // single
                3'd1:    next[i] = prbs[i];                                 // all
                3'd2:    next[i] = prbs[lane_s2];                           // sso
                3'd3:    next[i] = (i == lane_s2) ? prbs[i] : toggle;       // aggressor
                default: next[i] = stat_s2[i];                              // static
            endcase
        end
    end

    (* IOB = "TRUE" *) reg [LANES-1:0] q;
    always @(posedge clk) q <= next;
    assign out = q;
endmodule

// Per-lane self-synchronizing PRBS-7 checker in its capture clock domain.
// A start toggle (from the control domain) clears the counters and counts
// 2^log2n samples; done_tog then flips and the counts stay stable until the
// next start. One received bit error is flagged up to 3 times (the bit itself
// and the two predictions that use it). Failures are also split by the
// expected transition: rising (0 -> 1 expected) and falling (1 -> 0), 16-bit
// saturating, so lanes with unequal rise/fall delays show two separate walls.
module iol_checker #(
    parameter LANES = 8
) (
    input  wire               clk,
    input  wire [LANES-1:0]   rx,
    input  wire               start_tog,
    input  wire [4:0]         log2n,
    output reg                done_tog = 1'b0,
    output reg  [LANES*32-1:0] err  = 0,
    output reg  [LANES*32-1:0] ones = 0,
    output reg  [LANES*32-1:0] rf   = 0,    // per lane {falling[15:0], rising[15:0]}
    output reg  [LANES-1:0]   rx_now
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] start_s = 2'b00;
    reg        start_q = 1'b0;
    reg        running = 1'b0;
    reg [23:0] count;
    reg [6:0]  hist [0:LANES-1];

    (* ASYNC_REG = "TRUE" *) reg [4:0] log2n_s1, log2n_s2;
    wire [23:0] last = (24'd1 << log2n_s2) - 24'd1;

    integer l;
    always @(posedge clk) begin
        start_s  <= {start_s[0], start_tog};
        start_q  <= start_s[1];
        log2n_s1 <= log2n;
        log2n_s2 <= log2n_s1;
        rx_now   <= rx;
        for (l = 0; l < LANES; l = l + 1)
            hist[l] <= {hist[l][5:0], rx[l]};

        if (start_s[1] != start_q) begin
            running <= 1'b1;
            count   <= 24'd0;
            err     <= 0;
            ones    <= 0;
            rf      <= 0;
        end else if (running) begin
            for (l = 0; l < LANES; l = l + 1) begin
                // expected bit = hist[6] ^ hist[5]; previous bit = hist[0]
                err[l*32 +: 32]  <= err[l*32 +: 32]  + (rx[l] ^ hist[l][6] ^ hist[l][5]);
                ones[l*32 +: 32] <= ones[l*32 +: 32] + rx[l];
                if ((rx[l] ^ hist[l][6] ^ hist[l][5]) && ((hist[l][6] ^ hist[l][5]) != hist[l][0])) begin
                    if (hist[l][6] ^ hist[l][5]) begin
                        if (rf[l*32 +: 16] != 16'hFFFF) rf[l*32 +: 16] <= rf[l*32 +: 16] + 16'd1;
                    end else begin
                        if (rf[l*32 + 16 +: 16] != 16'hFFFF) rf[l*32 + 16 +: 16] <= rf[l*32 + 16 +: 16] + 16'd1;
                    end
                end
            end
            count <= count + 24'd1;
            if (count == last) begin
                running  <= 1'b0;
                done_tog <= ~done_tog;
            end
        end
    end
endmodule

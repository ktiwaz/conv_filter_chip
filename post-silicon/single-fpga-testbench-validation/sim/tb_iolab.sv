// Self-checking simulation of the I/O lab (iolab_board): the jumpers are
// transport delays, and the MMCM fine phase shift comes from the UNISIM model.
// Each experiment's error region must sit where the modelled delays put it.
`timescale 1ns/1ps

module tb_iolab;

    parameter int  DIV    = 10;                 // 100 MHz: short sweeps
    localparam real T_NS  = DIV * 1.0;          // VCO = 1 GHz
    localparam real STEP_NS = 1.0 / 56.0;       // one fine phase-shift step
    localparam int  STEPS_PER_PERIOD = 56 * DIV;

    // Modelled wire delays (ns)
    localparam real D_DATA = 4.0;
    localparam real D_CLK  = 4.5;
    localparam real D_RET  = 3.0;

    localparam [31:0] R_CTRL = 32'h04, R_STATUS = 32'h08, R_CONFIG = 32'h0C,
                      R_STEP = 32'h10, R_POINTS = 32'h14, R_LOG2N = 32'h18,
                      R_STATIC = 32'h1C, R_RX_A = 32'h20, R_RX_B = 32'h24,
                      R_ID = 32'h00, R_ONES = 32'h40, RESULTS = 32'h2_0000;

    logic refclk = 0;
    always #4 refclk = ~refclk;                 // 125 MHz
    logic rst = 1;

    wire        clk, aresetn, locked, rclk_alive;
    wire [7:0]  lane_out;
    logic [7:0] lane_in = 0;
    wire        fclk_out, ret_out;
    logic       fclk_in = 0, ret_in = 0;
    logic [7:0] stuck_mask = 0;                 // lanes forced to 0 at the receiver

    // Wires: transport delays (pulses shorter than the delay are kept), with
    // +/-100 ps random jitter per data transition so each edge has a width
    // the sweep can find. The forwarded clock is clean.
    localparam real JITTER = 0.100;
    real d_rise = D_DATA, d_fall = D_DATA;      // per-direction data wire delay
    function automatic real jit();
        return ($urandom_range(0, 2000) / 1000.0 - 1.0) * JITTER;
    endfunction

    genvar gl;
    generate
        for (gl = 0; gl < 8; gl++) begin : g_wire
            always @(lane_out[gl])
                lane_in[gl] <= #((lane_out[gl] ? d_rise : d_fall) + jit()) (lane_out[gl] & ~stuck_mask[gl]);
        end
    endgenerate
    always @(fclk_out) fclk_in <= #(D_CLK)          fclk_out;
    always @(ret_out)  ret_in  <= #(D_RET + jit())  ret_out;

    // AXI master signals (names used by axi_bfm.svh)
    logic [0:0]  awid = 0, arid = 0;
    logic [31:0] awaddr, araddr;
    logic [7:0]  awlen, arlen;
    logic [2:0]  awsize = 3'd2, arsize = 3'd2;
    logic [1:0]  awburst = 2'b01, arburst = 2'b01;
    logic        awvalid = 0, arvalid = 0;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wlast, wvalid = 0;
    logic        bready = 0, rready = 0;
    wire         awready, wready, bvalid, arready, rvalid, rlast;
    wire [0:0]   bid, rid;
    wire [1:0]   bresp, rresp;
    wire [31:0]  rdata;

    iolab_board #(.DIV(DIV), .LANES(8), .WIRING(2)) dut (
        .refclk_125(refclk), .rst(rst),
        .clk_ctl(clk), .aresetn(aresetn), .locked(locked), .rclk_alive(rclk_alive),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awsize(awsize),
        .s_axi_awburst(awburst), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize),
        .s_axi_arburst(arburst), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .lane_out(lane_out), .lane_in(lane_in),
        .fclk_out(fclk_out), .fclk_in(fclk_in), .ret_out(ret_out), .ret_in(ret_in)
    );

    `include "axi_bfm.svh"

    // Wrap a phase (ns) into [-T/2, T/2) around a reference
    function automatic real wrap_diff(real a, real b);
        real d = a - b;
        while (d >= T_NS / 2) d -= T_NS;
        while (d < -T_NS / 2) d += T_NS;
        return d;
    endfunction

    // Run a full-period sweep; return the phase (ns) of the centre of the
    // error region for `lane`, and the error count at the opposite phase
    task automatic sweep(input int exp, input int mode, input int lane,
                         output real wall_ns, output int mid_errors);
        localparam int K = 4;
        int points = STEPS_PER_PERIOD / K;
        logic [31:0] v;
        logic [31:0] d[$];
        int errs[$];
        int first, last, best_len, cur_start, cur_len, i, idx, centre;

        write_reg(R_CONFIG, (lane << 8) | (mode << 4) | exp);
        write_reg(R_STEP, K);
        write_reg(R_POINTS, points);
        write_reg(R_LOG2N, 6);                  // 64 samples per point
        write_reg(R_CTRL, 1);
        do begin repeat (2000) @(posedge clk); axi_read1(R_STATUS, v); end while (v[0]);
        check("sweep done without timeouts", v[2:1], 2'b01);

        errs = {};
        for (int p0 = 0; p0 < points; p0 += 16) begin
            int n = (points - p0 < 16) ? points - p0 : 16;
            axi_read(RESULTS + p0 * 64, n * 16, d);
            for (int p = 0; p < n; p++) errs.push_back(d[p * 16 + lane]);
        end

        // Longest circular run of points with errors = the eye wall
        best_len = 0; centre = 0;
        for (int s = 0; s < points; s++) begin
            if (errs[s] != 0 && errs[(s + points - 1) % points] == 0) begin
                cur_len = 0;
                while (cur_len < points && errs[(s + cur_len) % points] != 0) cur_len++;
                if (cur_len > best_len) begin best_len = cur_len; centre = (s + cur_len / 2) % points; end
            end
        end
        // Points are measured after their phase steps: point p is at (p + 1) * K steps
        wall_ns    = ((centre + 1) * K) * STEP_NS;
        mid_errors = errs[(centre + points / 2) % points];
        $display("  exp %0d mode %0d lane %0d: errors in %0d of %0d points, centre %.3f ns",
                 exp, mode, lane, best_len, points, wall_ns);
    endtask

    // Pass when the error-region centre is within 2 points (+ jitter) of the model
    task automatic check_wall(string what, real got, real exp_ns);
        real dlt = wrap_diff(got, exp_ns);
        real expw = exp_ns;
        while (expw >= T_NS) expw -= T_NS;
        while (expw < 0) expw += T_NS;
        if (dlt > 2 * 4 * STEP_NS + JITTER || dlt < -2 * 4 * STEP_NS - JITTER) begin
            errors++;
            $display("  FAIL %s: %.3f ns, expected %.3f ns", what, got, expw);
        end else begin
            $display("  ok   %s: %.3f ns (expected %.3f)", what, got, expw);
        end
    endtask

    function automatic real pt_ns(int idx, int K);
        return ((idx + 1) * K) * STEP_NS;
    endfunction

    function automatic real circ_centroid(int v[$], int K);
        real s = 0, c = 0, a;
        foreach (v[i]) begin
            a = 2.0 * 3.14159265358979 * pt_ns(i, K) / T_NS;
            s += v[i] * $sin(a);
            c += v[i] * $cos(a);
        end
        a = $atan2(s, c) / (2.0 * 3.14159265358979) * T_NS;
        return (a < 0) ? a + T_NS : a;
    endfunction

    // Length of the longest circular run of points with errors
    function automatic int run_len(int v[$]);
        int n = v.size(), best = 0;
        for (int s = 0; s < n; s++) begin
            if (v[s] != 0 && v[(s + n - 1) % n] == 0) begin
                int L = 0;
                while (L < n && v[(s + L) % n] != 0) L++;
                if (L > best) best = L;
            end
        end
        return best;
    endfunction

    // The end of the longest error run that is farther from `other`
    function automatic real far_end(int v[$], int K, real other);
        int n = v.size(), best = 0, bs = 0;
        real e1, e2, d1, d2;
        for (int s = 0; s < n; s++) begin
            if (v[s] != 0 && v[(s + n - 1) % n] == 0) begin
                int L = 0;
                while (L < n && v[(s + L) % n] != 0) L++;
                if (L > best) begin best = L; bs = s; end
            end
        end
        e1 = pt_ns(bs, K);
        e2 = pt_ns((bs + best - 1) % n, K);
        d1 = wrap_diff(e1, other);
        d2 = wrap_diff(e2, other);
        if (d1 < 0) d1 = -d1;
        if (d2 < 0) d2 = -d2;
        return (d1 > d2) ? e1 : e2;
    endfunction

    // Exp A sweep returning the rise-only and fall-only error walls of a lane
    task automatic sweep_rf(input int lane, output real rise_ns, output real fall_ns);
        localparam int K = 4;
        int points = STEPS_PER_PERIOD / K;
        logic [31:0] v;
        logic [31:0] d[$];
        write_reg(R_CONFIG, (lane << 8) | (0 << 4) | 0);    // exp A, single
        write_reg(R_STEP, K);
        write_reg(R_POINTS, points);
        write_reg(R_LOG2N, 6);
        write_reg(R_CTRL, 1);
        do begin repeat (2000) @(posedge clk); axi_read1(R_STATUS, v); end while (v[0]);
        // The faster edge only errs at its own wall (its error centroid is the
        // wall). The slower edge's errors fill the plateau between the two
        // walls, so its wall is the end of that plateau away from the other wall.
        begin
            int rv[$], fv[$];
            real r_c, f_c;
            for (int p0 = 0; p0 < points; p0 += 16) begin
                int n = (points - p0 < 16) ? points - p0 : 16;
                axi_read(RESULTS + p0 * 64, n * 16, d);
                for (int p = 0; p < n; p++) begin
                    rv.push_back(d[p * 16 + 8 + lane] & 16'hFFFF);
                    fv.push_back(d[p * 16 + 8 + lane] >> 16);
                end
            end
            r_c = circ_centroid(rv, K);
            f_c = circ_centroid(fv, K);
            if (run_len(fv) >= run_len(rv)) begin     // falling edge is the slower one
                rise_ns = r_c;
                fall_ns = far_end(fv, K, r_c);
            end else begin
                fall_ns = f_c;
                rise_ns = far_end(rv, K, f_c);
            end
        end
        $display("  rise errors centred at %.3f ns, fall errors at %.3f ns", rise_ns, fall_ns);
    endtask

    real w;
    real wr, wf;
    int  mid;
    logic [31:0] v;

    initial begin
        repeat (10) @(posedge refclk);
        rst = 0;
        wait (aresetn);
        repeat (10) @(posedge clk);

        axi_read1(R_ID, v);
        check("ID", v, 32'h101A_B001);

        $display("[1] static lane mapping (walking one)");
        for (int i = 0; i < 8; i++) begin
            write_reg(R_CONFIG, 4 << 4);        // static mode
            write_reg(R_STATIC, 1 << i);
            repeat (200) @(posedge clk);
            axi_read1(R_RX_A, v);
            check($sformatf("RX_A walking one lane %0d", i), v, 1 << i);
        end

        $display("[2] experiment A: data loopback, wall at T - D_data");
        sweep(0, 0, 2, w, mid);
        check_wall("A wall (single, lane 2)", w, T_NS - D_DATA);
        check("A errors mid-eye", mid, 0);
        sweep(0, 1, 5, w, mid);
        check_wall("A wall (all, lane 5)", w, T_NS - D_DATA);

        $display("[3] experiment B: forwarded-clock capture, wall at D_clk - D_data");
        sweep(1, 1, 0, w, mid);
        check_wall("B wall", w, D_CLK - D_DATA);
        check("B errors mid-eye", mid, 0);

        $display("[4] experiment B2: round trip, wall at D_clk + D_ret");
        sweep(2, 1, 0, w, mid);
        check_wall("B2 wall", w, D_CLK + D_RET);
        check("B2 errors mid-eye", mid, 0);

        $display("[5] lane 3 stuck at 0: the PRBS check passes, ONES flags it");
        stuck_mask = 8'b0000_1000;
        sweep(0, 1, 0, w, mid);
        axi_read1(R_ONES + 4 * 3, v);
        check("ONES lane 3 (stuck)", v, 0);
        axi_read1(R_ONES + 4 * 0, v);
        if (v < 16 || v > 48) begin errors++; $display("  FAIL ONES lane 0 = %0d (expected ~32 of 64)", v); end
        stuck_mask = 0;

        $display("[6] unequal edges (rise 4.0 ns, fall 6.0 ns): separate rise/fall walls");
        d_rise = 4.0; d_fall = 6.0;
        sweep_rf(1, wr, wf);
        check_wall("rising-edge wall (T - 4.0)", wr, T_NS - 4.0);
        check_wall("falling-edge wall (T - 6.0)", wf, T_NS - 6.0);
        d_rise = D_DATA; d_fall = D_DATA;

        if (errors == 0) $display("PASS: all tests passed");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #100ms;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

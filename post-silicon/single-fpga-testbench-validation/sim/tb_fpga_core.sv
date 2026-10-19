// Self-checking simulation of fpga_tb_core with a behavioral AXI4 master.
`timescale 1ns/1ps

module tb_fpga_core;

    parameter INIT_FILE  = "input_image_w32.hex";
    parameter IMAGE_FILE = "input_image.hex";
    parameter TESTCASE_ROOT = "../../testcases/5x5";

    localparam [31:0] IN_BASE   = 32'h0000_0000;
    localparam [31:0] CAP_BASE  = 32'h0001_0000;
    localparam [31:0] CTRL      = 32'h0002_0000;
    localparam [31:0] STATUS    = 32'h0002_0004;
    localparam [31:0] CAP_COUNT = 32'h0002_0008;
    localparam [31:0] ID        = 32'h0002_000C;
    localparam [31:0] CONFIG    = 32'h0002_0010;
    localparam [31:0] NORM      = 32'h0002_0014;
    localparam [31:0] GAP       = 32'h0002_0018;
    localparam [31:0] LINK      = 32'h0002_001C;
    localparam [31:0] KERNEL    = 32'h0002_0040;
    localparam [31:0] VIDEO     = 32'h0002_0024;
    localparam [31:0] RX_SIZE   = 32'h0002_0028;
    localparam [31:0] RX_FRAMES = 32'h0002_002C;
    localparam [31:0] LIVE_RUNS = 32'h0002_0030;
    localparam [31:0] LIVE_DROP = 32'h0002_0034;
    localparam [31:0] KSEL      = 32'h0002_0038;
    localparam NUM_PIXELS = 16384;
    localparam NUM_WORDS  = NUM_PIXELS / 4;

    logic clk = 0;
    always #10 clk = ~clk;  // 50 MHz

    logic aresetn = 0;
    logic start_sw = 0;
    logic btn_next = 0, btn_prev = 0;
    wire [3:0] kernel_index;
    wire       live_on;
    wire       st_bypass, st_ext, st_custom;
    wire [103:0] st_name;
    wire [7:0] st_fps;

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

    wire        busy, done, start_pulse, pixel_valid, dut_output_valid;
    wire [13:0] stream_addr;
    wire [7:0]  dut_dataout;
    wire [1:0]  dut_status;

    //==================================================
    // Behavioural HDMI-in source: 720p60 timing, deterministic RGB pattern
    //==================================================
    logic        rx_clk = 0;
    always #6.7 rx_clk = ~rx_clk;   // ~74.6 MHz, deliberately not the TX clock
    logic        rx_en = 0, rx_lock = 0;
    logic [23:0] rx_d = 0;          // {R, B, G}
    logic        rx_de = 0;
    int          rx_hc = 0, rx_vc = 0;
    int          rx_glitch_line = -1;   // one-shot: cut the second frame short here
    int          rx_frames_sent = 0;

    function automatic logic [23:0] rx_rgb(int x, int y);   // {R, G, B}
        logic [7:0] r, g, b;
        r = 8'(3 * x + y);
        g = 8'(x ^ y);
        b = 8'(x + 2 * y);
        return {r, g, b};
    endfunction

    always @(posedge rx_clk) begin
        if (!rx_en) begin
            rx_hc = 0; rx_vc = 0; rx_de <= 0; rx_frames_sent = 0;
        end else begin
            logic [23:0] c;
            c = rx_rgb(rx_hc, rx_vc);
            rx_de <= (rx_hc < 1280) && (rx_vc < 720);
            rx_d  <= {c[23:16], c[7:0], c[15:8]};
            rx_hc++;
            if (rx_hc == 1650) begin
                rx_hc = 0;
                if (rx_vc == 749) begin rx_vc = 0; rx_frames_sent++; end
                else rx_vc = rx_vc + 1;
                // Glitch: a partial frame, like a source (re)starting its link.
                // (The grabber ignores the first frame: it hasn't seen a
                // vertical blank yet.)
                if (rx_frames_sent == 1 && rx_vc == rx_glitch_line) begin
                    rx_vc = 720;
                    rx_glitch_line = -1;
                end
            end
        end
    end

    // Expected grabber output: gray of the centre 640x640, 5x5 box average
    function automatic logic [7:0] grab_model(int row, int col);
        int sum = 0;
        for (int j = 0; j < 5; j++)
            for (int i = 0; i < 5; i++) begin
                logic [23:0] c;
                c = rx_rgb(320 + 5 * col + i, 40 + 5 * row + j);
                sum += (54 * c[23:16] + 183 * c[15:8] + 18 * c[7:0]) >> 8;
            end
        return 8'((sum * 2621 + 32768) >> 16);
    endfunction

    // Display frame-buffer writes
    wire        disp_start, disp_done, disp_in_we, disp_out_we, disp_masked, video_pattern;
    wire [13:0] disp_in_addr, disp_out_addr;
    wire [7:0]  disp_in_data, disp_out_data;
    wire [14:0] disp_lo, disp_hi, disp_lo_p, disp_hi_p;
    wire        disp_masked_p;

    // Link pins (tester side)
    wire       t_clk, t_reset_n, t_kv, t_nv, t_pv, t_tm;
    wire [7:0] t_din;
    wire [7:0] t_dout;
    wire       t_ov;
    wire [1:0] t_st;

    fpga_tb_core #(
        .INIT_FILE(INIT_FILE),
        .ID_WIDTH(1)
    ) dut (
        .clk(clk), .aresetn(aresetn), .start_sw(start_sw),
        .btn_next(btn_next), .btn_prev(btn_prev),
        .kernel_index(kernel_index), .live_on(live_on),
        .st_bypass(st_bypass), .st_ext(st_ext), .st_custom(st_custom), .st_name(st_name), .st_fps(st_fps),
        .rx_clk(rx_clk), .rx_locked(rx_lock), .rx_data(rx_d), .rx_de(rx_de),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awburst(awburst),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(arsize), .s_axi_arburst(arburst),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .busy(busy), .done(done), .start_pulse(start_pulse),
        .stream_addr(stream_addr), .pixel_valid(pixel_valid),
        .dut_dataout(dut_dataout), .dut_output_valid(dut_output_valid), .dut_status(dut_status),
        .disp_start(disp_start), .disp_done(disp_done),
        .disp_in_we(disp_in_we), .disp_in_addr(disp_in_addr), .disp_in_data(disp_in_data),
        .disp_out_we(disp_out_we), .disp_out_addr(disp_out_addr), .disp_out_data(disp_out_data),
        .disp_masked(disp_masked), .disp_lo(disp_lo), .disp_hi(disp_hi),
        .video_pattern(video_pattern),
        .chip_clk(t_clk), .chip_reset_n(t_reset_n), .chip_kernel_valid(t_kv),
        .chip_normalization_valid(t_nv), .chip_pixel_valid(t_pv), .chip_test_mode(t_tm),
        .chip_datain(t_din), .chip_dataout(t_dout), .chip_output_valid(t_ov), .chip_status(t_st)
    );

    //==================================================
    // External DUT board, connected through board-to-board wire delays
    //==================================================
    localparam real WIRE_DELAY = 6.0;   // ns each way

    wire       d_clk, d_reset_n, d_kv, d_nv, d_pv, d_tm;
    wire [7:0] d_din;
    wire [7:0] d_dout;
    wire       d_ov;
    wire [1:0] d_st;

    assign #(WIRE_DELAY) {d_clk, d_reset_n, d_kv, d_nv, d_pv, d_tm, d_din} =
                         {t_clk, t_reset_n, t_kv, t_nv, t_pv, t_tm, t_din};
    assign #(WIRE_DELAY) {t_dout, t_ov, t_st} = {d_dout, d_ov, d_st};

    dut_board_core ext_board (
        .refclk(clk),
        .chip_clk(d_clk), .chip_reset_n(d_reset_n), .chip_kernel_valid(d_kv),
        .chip_normalization_valid(d_nv), .chip_pixel_valid(d_pv), .chip_test_mode(d_tm),
        .chip_datain(d_din), .chip_dataout(d_dout), .chip_output_valid(d_ov),
        .chip_status(d_st), .led()
    );

    //==================================================
    // HDMI picture path (without the TMDS serializer)
    //==================================================
    logic pclk = 0;
    always #6.734 pclk = ~pclk;   // 74.25 MHz
    logic prst = 1;

    wire        frame_start, has_frame;
    wire [13:0] rd_addr;
    wire [7:0]  rd_in, rd_out;
    wire [7:0]  vr, vg, vb;
    wire        vde, vhs, vvs;

    video_frame frames (
        .clk(clk), .aresetn(aresetn), .run_start(disp_start), .run_done(disp_done),
        .run_lo(disp_lo), .run_hi(disp_hi), .run_masked(disp_masked),
        .in_we(disp_in_we), .in_addr(disp_in_addr), .in_data(disp_in_data),
        .out_we(disp_out_we), .out_addr(disp_out_addr), .out_data(disp_out_data),
        .pclk(pclk), .prst(prst), .frame_start(frame_start),
        .rd_addr(rd_addr), .rd_in(rd_in), .rd_out(rd_out), .has_frame(has_frame),
        .disp_lo(disp_lo_p), .disp_hi(disp_hi_p), .disp_masked(disp_masked_p)
    );

    video_compositor comp (
        .pclk(pclk), .prst(prst), .frame_start(frame_start),
        .rd_addr(rd_addr), .rd_in(rd_in), .rd_out(rd_out),
        .has_frame(has_frame), .out_lo(disp_lo_p), .out_hi(disp_hi_p),
        .out_masked(disp_masked_p), .pattern(video_pattern),
        .st_live(live_on), .st_bypass(st_bypass), .st_ext(st_ext), .st_custom(st_custom),
        .st_name(st_name), .st_fps(st_fps),
        .r(vr), .g(vg), .b(vb), .de(vde), .hs(vhs), .vs(vvs)
    );

    // Checks every displayed pixel of one frame against v_in / v_out
    logic [7:0] v_in[16384];
    logic [7:0] v_out[16384];     // expected output, already at input positions
    logic       v_outvalid[16384];
    bit         v_check = 0;
    int         v_errors = 0, v_checked = 0, v_frames = 0;
    int         vx = 0, vy = 0;
    logic       vde_q = 0, vvs_q = 0;

    always @(posedge pclk) begin
        vde_q <= vde;
        vvs_q <= vvs;
        if (vvs && !vvs_q) begin vy = 0; v_frames++; end
        if (vde) begin
            logic [23:0] exp;
            bit          chk;
            int          idx;
            chk = 1;
            if (vx >= 85 && vx < 597 && vy >= 104 && vy < 616) begin
                idx = ((vy - 104) / 4) * 128 + (vx - 85) / 4;
                exp = {3{v_in[idx]}};
            end else if (vx >= 683 && vx < 1195 && vy >= 104 && vy < 616) begin
                idx = ((vy - 104) / 4) * 128 + (vx - 683) / 4;
                exp = v_outvalid[idx] ? {3{v_out[idx]}} : 24'h000000;
            end else begin
                chk = 0;   // borders and background
            end
            if (v_check && chk) begin
                v_checked++;
                if ({vr, vg, vb} !== exp) begin
                    v_errors++;
                    if (v_errors < 10) $display("  FAIL video (%0d,%0d): got %06h expected %06h", vx, vy, {vr, vg, vb}, exp);
                end
            end
            vx++;
        end
        if (!vde && vde_q) begin vx = 0; vy++; end
    end

    // Dump one whole output frame as a binary PPM (frame_dump_<n>.ppm in the sim dir)
    bit    dump_req = 0, dumping = 0;
    int    dump_fd, dump_n = 0;
    always @(posedge pclk) begin
        if (vvs && !vvs_q) begin
            if (dumping) begin
                $fclose(dump_fd);
                dumping  = 0;
                dump_req = 0;
            end else if (dump_req) begin
                dump_fd = $fopen($sformatf("frame_dump_%0d.ppm", dump_n), "wb");
                $fwrite(dump_fd, "P6\n1280 720\n255\n");
                dumping = 1;
                dump_n++;
            end
        end
        if (dumping && vde)
            $fwrite(dump_fd, "%c%c%c", vr, vg, vb);
    end

    task automatic dump_frame();
        dump_req = 1;
        wait (!dump_req);
    endtask

    int errors = 0;
    bit backpressure = 0;   // randomly stall W/B/R handshakes on the master side

    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            errors++;
            if (errors < 20) $display("  FAIL %s: got %08h, expected %08h", what, got, exp);
        end
    endtask

    task automatic stall();
        if (backpressure) repeat ($urandom_range(0, 3)) @(posedge clk);
    endtask

    // Burst write: data.size() beats starting at addr (all strobes set unless strb given)
    task automatic axi_write(input logic [31:0] addr, input logic [31:0] data[$],
                             input logic [3:0] strb = 4'hF);
        @(posedge clk);
        awaddr  <= addr;
        awlen   <= data.size() - 1;
        awvalid <= 1;
        do @(posedge clk); while (!awready);
        awvalid <= 0;
        foreach (data[i]) begin
            wvalid <= 0;
            stall();
            wdata  <= data[i];
            wstrb  <= strb;
            wlast  <= (i == data.size() - 1);
            wvalid <= 1;
            do @(posedge clk); while (!wready);
        end
        wvalid <= 0;
        stall();
        bready <= 1;
        do @(posedge clk); while (!bvalid);
        check("bresp", bresp, 2'b00);
        bready <= 0;
    endtask

    task automatic axi_read(input logic [31:0] addr, input int beats, output logic [31:0] data[$]);
        int n;
        data = {};
        @(posedge clk);
        araddr  <= addr;
        arlen   <= beats - 1;
        arvalid <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0;
        n = 0;
        while (n < beats) begin
            rready <= 0;
            stall();
            rready <= 1;
            do @(posedge clk); while (!rvalid);
            data.push_back(rdata);
            check("rresp", rresp, 2'b00);
            check($sformatf("rlast beat %0d", n), rlast, (n == beats - 1));
            n++;
        end
        rready <= 0;
    endtask

    task automatic axi_read1(input logic [31:0] addr, output logic [31:0] value);
        logic [31:0] d[$];
        axi_read(addr, 1, d);
        value = d[0];
    endtask

    // Read the whole input/capture RAM in 256-beat bursts
    task automatic read_image(input logic [31:0] base, output logic [7:0] img[NUM_PIXELS]);
        logic [31:0] d[$];
        for (int b = 0; b < NUM_WORDS / 256; b++) begin
            axi_read(base + b * 1024, 256, d);
            foreach (d[i])
                for (int k = 0; k < 4; k++)
                    img[(b * 256 + i) * 4 + k] = d[i][k*8 +: 8];
        end
    endtask

    task automatic write_image(input logic [31:0] base, input logic [7:0] img[NUM_PIXELS]);
        logic [31:0] d[$];
        for (int b = 0; b < NUM_WORDS / 256; b++) begin
            d = {};
            for (int i = 0; i < 256; i++) begin
                int p = (b * 256 + i) * 4;
                d.push_back({img[p+3], img[p+2], img[p+1], img[p]});
            end
            axi_write(base + b * 1024, d);
        end
    endtask

    task automatic compare_image(input string what, input logic [7:0] got[NUM_PIXELS],
                                 input logic [7:0] exp[NUM_PIXELS], input int n = NUM_PIXELS);
        int errs_before = errors;
        for (int i = 0; i < n; i++)
            check($sformatf("%s[%0d]", what, i), got[i], exp[i]);
        $display("  %s: %s", what, (errors == errs_before) ? "ok" : "MISMATCH");
    endtask

    task automatic wait_done();
        logic [31:0] st;
        int polls = 0;
        do begin
            repeat (500) @(posedge clk);
            axi_read1(STATUS, st);
            polls++;
        end while (!st[1] && polls < 200);
        check("status after stream", st, 32'h2);
    endtask

    task automatic write_reg(input logic [31:0] addr, input logic [31:0] value);
        logic [31:0] q[$];
        q = '{value};
        axi_write(addr, q);
    endtask

    // Run one testcase directory through the DUT and compare with its golden output
    task automatic run_testcase(input string name, input int norm, input bit tmode,
                                input int gap_every = 0, input int gap_cycles = 0,
                                input bit ext = 0);
        string       dir = {TESTCASE_ROOT, "/", name};
        logic [7:0]  in_img[NUM_PIXELS];
        logic [7:0]  exp_img[NUM_PIXELS];
        logic [7:0]  cap[NUM_PIXELS];
        logic [7:0]  kern[28];
        logic [31:0] q[$];
        logic [31:0] cnt;
        int          exp_count;

        foreach (exp_img[i]) exp_img[i] = 'x;
        foreach (kern[i]) kern[i] = 8'h00;
        $readmemh({dir, "/input_image.hex"}, in_img);
        $readmemh({dir, "/expected_output_image.hex"}, exp_img);
        $readmemh({dir, "/kernel.hex"}, kern, 0, 24);
        exp_count = 0;
        while (exp_count < NUM_PIXELS && !$isunknown(exp_img[exp_count])) exp_count++;

        write_image(IN_BASE, in_img);
        q = {};
        for (int j = 0; j < 7; j++)
            q.push_back({kern[4*j+3], kern[4*j+2], kern[4*j+1], kern[4*j]});
        axi_write(KERNEL, q);
        write_reg(NORM, norm);
        write_reg(CONFIG, {29'd0, ext, tmode, 1'b0});
        write_reg(GAP, {gap_every[15:0], gap_cycles[15:0]});

        write_reg(CTRL, 32'h1);
        wait_done();
        axi_read1(CAP_COUNT, cnt);
        check({name, " CAP_COUNT"}, cnt, exp_count);
        read_image(CAP_BASE, cap);
        compare_image($sformatf("%s (%s norm=%0d test_mode=%0d gap=%0d/%0d, %0d px)",
                                name, ext ? "ext" : "int", norm, tmode, gap_every, gap_cycles,
                                exp_count),
                      cap, exp_img, exp_count);
        write_reg(GAP, 32'h0);
    endtask

    // Run a testcase and check one full HDMI frame of both panes
    task automatic video_testcase(input string name, input int norm, input bit tmode);
        string      dir = {TESTCASE_ROOT, "/", name};
        logic [7:0] exp_img[NUM_PIXELS];
        int         ofs, n, f0;
        foreach (exp_img[i]) exp_img[i] = 'x;
        $readmemh({dir, "/input_image.hex"}, v_in);
        $readmemh({dir, "/expected_output_image.hex"}, exp_img);
        ofs = tmode ? 516 : 258;
        foreach (v_outvalid[i]) v_outvalid[i] = 0;
        n = 0;
        while (n < NUM_PIXELS && !$isunknown(exp_img[n])) n++;
        for (int k = 0; k < n; k++) begin
            int row = (k + ofs) / 128, col = (k + ofs) % 128;
            if (tmode || (row >= 2 && row <= 125 && col >= 2 && col <= 125)) begin
                v_out[k + ofs]      = exp_img[k];
                v_outvalid[k + ofs] = 1;
            end
        end
        run_testcase(name, norm, tmode);
        // The run's bank is shown from the next frame start; check the frame after
        f0 = v_frames;
        wait (v_frames == f0 + 2);
        v_errors = 0; v_checked = 0; v_check = 1;
        wait (v_frames == f0 + 3);
        v_check = 0;
        check({name, " video mismatches"}, v_errors, 0);
        check({name, " video pixels checked"}, v_checked, 2 * 512 * 512);
        $display("  %s on HDMI: %s (%0d pixels)", name, v_errors == 0 ? "ok" : "MISMATCH", v_checked);
    endtask

    // Count stream beats to make sure a held switch doesn't retrigger
    int stream_beats = 0;
    always @(posedge clk) if (pixel_valid) stream_beats++;

    logic [7:0]  golden[NUM_PIXELS];
    logic [7:0]  img[NUM_PIXELS];
    logic [7:0]  rnd[NUM_PIXELS];
    logic [31:0] v;
    logic [31:0] d[$];

    initial begin
        $readmemh(IMAGE_FILE, golden);
        foreach (rnd[i]) rnd[i] = $urandom;

        repeat (5) @(posedge clk);
        aresetn <= 1;
        prst    <= 0;
        repeat (5) @(posedge clk);

        $display("[1] ID register");
        axi_read1(ID, v);
        check("ID", v, 32'hC0F1_0005);
        axi_read1(KSEL, v);
        check("KSEL reset (emboss)", v, 1);
        axi_read1(NORM, v);
        check("NORM loaded from preset 1 (emboss)", v, 3277);
        axi_read1(STATUS, v);
        check("STATUS idle", v, 32'h0);

        $display("[2] input RAM initialized from file");
        read_image(IN_BASE, img);
        compare_image("init image", img, golden);

        $display("[3] burst write + readback (with backpressure)");
        backpressure = 1;
        write_image(IN_BASE, rnd);
        read_image(IN_BASE, img);
        compare_image("written image", img, rnd);
        backpressure = 0;

        $display("[4] partial byte-strobe write");
        d = '{32'hAABBCCDD};
        axi_write(IN_BASE + 32'h10, d, 4'b0101);
        axi_read1(IN_BASE + 32'h10, v);
        check("strobe write", v, {rnd[19], 8'hBB, rnd[17], 8'hDD});
        rnd[16] = 8'hDD;
        rnd[18] = 8'hBB;

        $display("[5] stream via CTRL.start (bypass)");
        write_reg(CONFIG, 32'h1);
        axi_read1(CONFIG, v);
        check("CONFIG readback", v, 32'h1);
        d = '{32'h1};
        axi_write(CTRL, d);
        wait_done();
        axi_read1(CAP_COUNT, v);
        check("CAP_COUNT", v, NUM_PIXELS);

        $display("[6] capture RAM matches input");
        read_image(CAP_BASE, img);
        compare_image("capture", img, rnd);

        $display("[7] stream via switch edge; holding it doesn't retrigger");
        write_image(IN_BASE, golden);
        d = '{32'h0};
        for (int i = 0; i < NUM_WORDS; i += 256) begin
            d = {};
            repeat (256) d.push_back(32'h0);
            axi_write(CAP_BASE + i * 4, d);
        end
        stream_beats = 0;
        start_sw <= 1;
        wait_done();
        repeat (NUM_PIXELS + 1000) @(posedge clk);
        check("stream beats with switch held", stream_beats, NUM_PIXELS);
        start_sw <= 0;
        axi_read1(CAP_COUNT, v);
        check("CAP_COUNT", v, NUM_PIXELS);
        read_image(CAP_BASE, img);
        compare_image("capture", img, golden);

        $display("[8] kernel/norm register readback");
        d = '{32'h04030201, 32'h08070605};
        axi_write(KERNEL, d);
        axi_read(KERNEL, 2, d);
        check("KERNEL[0]", d[0], 32'h04030201);
        check("KERNEL[1]", d[1], 32'h08070605);
        write_reg(NORM, 32'hFFFF_1234);
        axi_read1(NORM, v);
        check("NORM masked to 16 bits", v, 32'h1234);

        $display("[9] DUT testcases (5x5)");
        run_testcase("box_blur",      1311,  0);
        run_testcase("emboss",        3277,  0);
        run_testcase("gaussian_blur", 120,   0);
        run_testcase("identity",      32768, 0);
        run_testcase("outline",       32768, 0);
        run_testcase("sharpen",       32768, 0);
        run_testcase("sobel_x",       32768, 0);
        run_testcase("sobel_y",       32768, 0);
        run_testcase("test_mode",     1311,  1);

        $display("[10] DUT with pixel_valid gaps (3 idle cycles every 7 pixels)");
        run_testcase("emboss",        3277,  0, 7, 3);
        $display("[11] DUT with a gap after every pixel");
        run_testcase("sobel_x",       32768, 0, 1, 1);

        $display("[12] external DUT board over the link, 8.33 MHz (H=3, S=0)");
        axi_read1(LINK, v);
        check("LINK reset value", v, 32'h0003);
        run_testcase("emboss",        3277,  0, 0, 0, 1);
        run_testcase("test_mode",     1311,  1, 0, 0, 1);
        check("internal DUT held in reset in ext mode", dut.int_status, 2'd0);

        $display("[13] external DUT at 25 MHz (H=1, S=1)");
        write_reg(LINK, 32'h0101);
        run_testcase("sobel_x",       32768, 0, 0, 0, 1);

        $display("[14] external DUT with gaps (7/3), H=2, S=0");
        write_reg(LINK, 32'h0002);
        run_testcase("emboss",        3277,  0, 7, 3, 1);

        $display("[15] back to internal; link idles");
        write_reg(LINK, 32'h0003);
        run_testcase("sharpen",       32768, 0);
        check("link reset_n idle low", t_reset_n, 1'b0);
        check("link clock idle low",   t_clk,     1'b0);

        $display("[16] HDMI picture: input and DUT output panes, every pixel of a frame");
        video_testcase("emboss",    3277, 0);
        video_testcase("test_mode", 1311, 1);
        dump_frame();       // frame_dump_0: static image, custom (JTAG) kernel

        begin
            logic [7:0]  model[NUM_PIXELS];
            logic [7:0]  live_cap[NUM_PIXELS];
            logic [7:0]  static_cap[NUM_PIXELS];
            logic [7:0]  kern[28];
            logic [31:0] q[$];
            logic [31:0] runs0;
            int          errs0;

            for (int row = 0; row < 128; row++)
                for (int col = 0; col < 128; col++)
                    model[row * 128 + col] = grab_model(row, col);

            $display("[17] HDMI in -> 128x128 grabber, live mode with the DUT bypassed");
            $display("     (the second frame is cut short mid-crop; the grabber must resync)");
            rx_glitch_line = 333;
            rx_en = 1; rx_lock = 1;
            write_reg(CONFIG, 32'h11);              // live + bypass
            do begin repeat (20000) @(posedge clk); axi_read1(LIVE_RUNS, v); end while (v < 3);
            write_reg(CONFIG, 32'h01);              // stop live, keep bypass
            wait_done();
            axi_read1(RX_SIZE, v);
            check("RX_SIZE (720 << 16 | 1280)", v, {16'd720, 16'd1280});
            axi_read1(VIDEO, v);
            check("VIDEO locked", v[0], 1'b1);
            read_image(CAP_BASE, live_cap);
            compare_image("grabbed frame vs model", live_cap, model);

            $display("[18] live emboss through the DUT == the same frame run from JTAG");
            foreach (kern[i]) kern[i] = 8'h00;
            $readmemh({TESTCASE_ROOT, "/emboss/kernel.hex"}, kern, 0, 24);
            q = {};
            for (int j = 0; j < 7; j++) q.push_back({kern[4*j+3], kern[4*j+2], kern[4*j+1], kern[4*j]});
            axi_write(KERNEL, q);
            write_reg(NORM, 3277);
            axi_read1(LIVE_RUNS, runs0);
            write_reg(CONFIG, 32'h10);              // live, through the DUT
            do begin repeat (20000) @(posedge clk); axi_read1(LIVE_RUNS, v); end while (v < runs0 + 2);
            write_reg(CONFIG, 32'h00);
            wait_done();
            axi_read1(CAP_COUNT, v);
            check("live CAP_COUNT", v, 15867);
            read_image(CAP_BASE, live_cap);
            axi_read1(LIVE_DROP, v);
            check("live frames dropped", v, 0);

            write_image(IN_BASE, model);
            write_reg(CTRL, 32'h1);
            wait_done();
            read_image(CAP_BASE, static_cap);
            compare_image("live filtered vs JTAG-run filtered", live_cap, static_cap, 15867);
            rx_en = 0;
        end

        begin
            logic [7:0]  in_img[NUM_PIXELS];
            logic [7:0]  exp_img[NUM_PIXELS];
            logic [7:0]  cap[NUM_PIXELS];
            logic [7:0]  kern[28];
            logic [31:0] d2[$];

            $display("[19] filter presets: KSEL and the buttons load kernel_rom entries");
            write_reg(KSEL, 6);                         // sobel_x
            axi_read1(NORM, v);
            check("sobel_x preset NORM", v, 32768);
            axi_read1(CONFIG, v);
            check("preset clears bypass/test_mode", v & 32'h3, 0);
            foreach (kern[i]) kern[i] = 8'h00;
            $readmemh({TESTCASE_ROOT, "/sobel_x/kernel.hex"}, kern, 0, 24);
            axi_read(KERNEL, 7, d2);
            for (int j = 0; j < 7; j++)
                check($sformatf("sobel_x preset KERNEL[%0d]", j), d2[j],
                      {kern[4*j+3], kern[4*j+2], kern[4*j+1], kern[4*j]});
            // The preset kernel filters the testcase image to its golden output
            foreach (exp_img[i]) exp_img[i] = 'x;
            $readmemh({TESTCASE_ROOT, "/sobel_x/input_image.hex"}, in_img);
            $readmemh({TESTCASE_ROOT, "/sobel_x/expected_output_image.hex"}, exp_img);
            write_image(IN_BASE, in_img);
            write_reg(CTRL, 32'h1);
            wait_done();
            read_image(CAP_BASE, cap);
            compare_image("sobel_x via preset", cap, exp_img, 15867);

            // Button: held past the ~21 ms debounce steps to the next preset
            btn_next = 1;
            repeat (1100000) @(posedge clk);
            btn_next = 0;
            repeat (1100000) @(posedge clk);
            axi_read1(KSEL, v);
            check("BTN0 steps to sobel_y", v, 7);
            btn_prev = 1;
            repeat (1100000) @(posedge clk);
            btn_prev = 0;
            repeat (1100000) @(posedge clk);
            axi_read1(KSEL, v);
            check("BTN1 steps back to sobel_x", v, 6);
            write_reg(KSEL, 15);
            axi_read1(KSEL, v);
            check("KSEL clamps to the last preset", v, 8);
            write_reg(KSEL, 6);
            write_image(IN_BASE, in_img);
            write_reg(CTRL, 32'h1);
            wait_done();
            dump_frame();   // frame_dump_1: static image, sobel_x preset
        end

        if (errors == 0) $display("PASS: all tests passed");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #500ms;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

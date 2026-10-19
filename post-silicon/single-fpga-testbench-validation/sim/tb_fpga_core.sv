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
    localparam NUM_PIXELS = 16384;
    localparam NUM_WORDS  = NUM_PIXELS / 4;

    logic clk = 0;
    always #10 clk = ~clk;  // 50 MHz

    logic aresetn = 0;
    logic start_sw = 0;

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
        repeat (5) @(posedge clk);

        $display("[1] ID register");
        axi_read1(ID, v);
        check("ID", v, 32'hC0F1_0003);
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

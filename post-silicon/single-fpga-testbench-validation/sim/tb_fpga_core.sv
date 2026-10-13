// Self-checking simulation of fpga_tb_core with a behavioral AXI4 master.
`timescale 1ns/1ps

module tb_fpga_core;

    parameter INIT_FILE  = "input_image_w32.hex";
    parameter IMAGE_FILE = "input_image.hex";

    localparam [31:0] IN_BASE   = 32'h0000_0000;
    localparam [31:0] CAP_BASE  = 32'h0001_0000;
    localparam [31:0] CTRL      = 32'h0002_0000;
    localparam [31:0] STATUS    = 32'h0002_0004;
    localparam [31:0] CAP_COUNT = 32'h0002_0008;
    localparam [31:0] ID        = 32'h0002_000C;
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

    wire        busy, done, start_pulse, stream_valid;
    wire [13:0] stream_addr;
    wire [7:0]  stream_data;

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
        .stream_addr(stream_addr), .stream_data(stream_data), .stream_valid(stream_valid)
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
                                 input logic [7:0] exp[NUM_PIXELS]);
        int errs_before = errors;
        for (int i = 0; i < NUM_PIXELS; i++)
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

    // Count stream beats to make sure a held switch doesn't retrigger
    int stream_beats = 0;
    always @(posedge clk) if (stream_valid) stream_beats++;

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
        check("ID", v, 32'hC0F1_0001);
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

        $display("[5] stream via CTRL.start");
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

        if (errors == 0) $display("PASS: all tests passed");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #50ms;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

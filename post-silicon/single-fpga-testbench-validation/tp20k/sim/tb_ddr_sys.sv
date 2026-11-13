// System version of tb_ddr_arb: port 0 random reads (preview reader stand-in),
// port 1 the real preview_wr fed by a synthetic RGB565 camera, port 2 axi_ddr.
// Checks the AXI data while the camera writes. Derived from tb_ddr_arb.sv.
// ddr_arb + axi_ddr against a behavioural model of ddr3_ctrl's user side
// (rd / wr with wr_burst / refresh, busy, data_ready, dout_burst).
//   - port 0: random burst writes and reads (a stand-in for the video clients),
//     checked against a reference memory
//   - port 1: axi_ddr, driven by AXI transactions from the fabric clock like
//     the debug bridge: word writes with strobes, bursts, reads back
// Checks the data, that every refresh interval stays below 2 x 7.8 us, and
// that the controller never sees a request while busy.
`timescale 1ns/1ps

module tb_ddr_sys;

    localparam BA_W = 23;
    reg dclk = 0, clk = 0;
    always #5.29 dclk = ~dclk;           // 94.5 MHz
    always #10.77 clk = ~clk;            // 46.4 MHz
    reg drst = 1, aresetn = 0;

    //==================================================
    // Controller model
    //==================================================
    wire c_rd, c_wr, c_refresh;
    wire [BA_W+2:0] c_addr;
    wire [127:0] c_din_burst;
    wire [15:0]  c_be_burst;
    reg  c_busy = 0, c_data_ready = 0;
    reg  [127:0] c_dout_burst = 0;
    reg  [127:0] mem [0:(1<<19)-1];      // by burst address (the test stays below 8 MB)
    initial for (int i = 0; i < (1<<19); i++) mem[i] = 128'd0;
    int  errors = 0, n_ref = 0;
    time last_ref = 0, max_gap = 0;

    int  cnt = 0;
    reg  op_rd = 0;
    int  op_ba = 0;
    always @(posedge dclk) begin
        c_data_ready <= 0;
        if ((c_rd || c_wr || c_refresh) && c_busy) begin
            $display("  FAIL request while busy at %0t", $time); errors++;
        end
        if (c_busy) begin
            if (cnt == 0) begin
                c_busy <= 0;
                if (op_rd) begin
                    c_data_ready <= 1;
                    c_dout_burst <= mem[op_ba];
                end
            end else
                cnt <= cnt - 1;
        end else if (c_rd || c_wr || c_refresh) begin
            c_busy <= 1;
            cnt    <= c_refresh ? 12 : $urandom_range(10, 30);
            op_rd  <= c_rd;
            op_ba  <= c_addr[BA_W+2:3];
            if (c_refresh) begin
                if (last_ref != 0 && $time - last_ref > max_gap) max_gap = $time - last_ref;
                last_ref = $time;
                n_ref++;
            end
            if (c_wr) begin : wr
                reg [127:0] cur;
                cur = mem[c_addr[BA_W+2:3]];
                for (int b = 0; b < 16; b++)
                    if (c_be_burst[b]) cur[8*b +: 8] = c_din_burst[8*b +: 8];
                mem[c_addr[BA_W+2:3]] = cur;
            end
        end
    end

    //==================================================
    // DUT: arbiter, port 0 traffic generator, port 1 axi_ddr
    //==================================================
    reg  [1:0]  req = 0, we = 0;
    wire [2:0]  gnt, rvalid;
    wire [127:0] rdata;
    reg  [BA_W-1:0] p0_baddr = 0;
    reg  [127:0] p0_wdata = 0;
    wire d_req, d_we;
    wire [BA_W-1:0] d_baddr;
    wire [127:0] d_wdata;
    wire [15:0]  d_wbe;
    wire [31:0]  accesses;

    wire        pv_req;
    wire [BA_W-1:0] pv_baddr;
    wire [127:0] pv_wdata;
    ddr_arb #(.NP(3), .BA_W(BA_W), .REFRESH_CYC(737)) arb (
        .clk(dclk), .rst(drst), .ready(1'b1),
        .req({d_req, pv_req, req[0]}), .we({d_we, 1'b1, we[0]}),
        .baddr({d_baddr, pv_baddr, p0_baddr}), .wdata({d_wdata, pv_wdata, p0_wdata}),
        .wbe({d_wbe, 16'hFFFF, 16'hFFFF}),
        .gnt(gnt), .rvalid(rvalid), .rdata(rdata),
        .c_rd(c_rd), .c_wr(c_wr), .c_refresh(c_refresh), .c_addr(c_addr),
        .c_din_burst(c_din_burst), .c_be_burst(c_be_burst),
        .c_busy(c_busy), .c_data_ready(c_data_ready), .c_dout_burst(c_dout_burst),
        .accesses(accesses)
    );

    // Port 0: random bursts in the region 0x10000.. (bursts), its own reference
    reg [127:0] ref0 [0:63];             // port 0 bursts 0x10000..0x1003F
    initial for (int i = 0; i < 64; i++) ref0[i] = 128'd0;
    int  p0_done = 0, p0_reads = 0;
    reg  p0_run = 0;
    reg  p0_wait = 0;
    reg [BA_W-1:0] p0_rd_addr;
    always @(posedge dclk) begin
        if (gnt[0]) req[0] <= 0;
        if (rvalid[0]) begin
            reg [127:0] want;
            want = ref0[p0_rd_addr - 23'h50000];
            if (rdata !== want) begin
                if (errors < 5) $display("  FAIL port 0 read %h: got %h want %h", p0_rd_addr, rdata, want);
                errors++;
            end
            p0_reads++;
            p0_wait <= 0;
        end
        if (p0_run && !req[0] && !gnt[0] && !p0_wait && $urandom_range(0, 3) == 0) begin
            reg [BA_W-1:0] a;
            a = 23'h50000 + $urandom_range(0, 63);
            req[0] <= 1;
            p0_baddr <= a;
            if (0) begin
                reg [127:0] d;
                d = {$urandom, $urandom, $urandom, $urandom};
                we[0] <= 1; p0_wdata <= d; ref0[a - 23'h10000] = d;
            end else begin
                we[0] <= 0; p0_rd_addr <= a; p0_wait <= 1;
            end
            p0_done++;
        end
    end


    // camera -> pix565 -> preview_wr (port 1)
    reg pclk = 0;
    always #10.8 pclk = ~pclk;
    reg [7:0] cd = 0; reg chref = 0; reg [7:0] cd_q; reg chref_q;
    always @(posedge pclk) begin cd_q <= cd; chref_q <= chref; end
    initial begin
        @(negedge drst);
        forever begin
            repeat (9000) @(posedge pclk);
            for (int y = 0; y < 384; y++) begin
                for (int x = 0; x < 384; x++) begin
                    @(posedge pclk); chref <= 1; cd <= $urandom;
                    @(posedge pclk); cd <= $urandom;
                end
                @(posedge pclk); chref <= 0;
                repeat (600) @(posedge pclk);
            end
        end
    end
    wire ce, px_de, px_sol, px_sof; wire [15:0] px; wire [23:0] rbg;
    pix565 pix (.clk(pclk), .rst(drst), .d(cd_q), .de(chref_q), .ce(ce), .px_de(px_de),
                .px_sol(px_sol), .px_sof(px_sof), .px(px), .rgb_rbg(rbg));
    wire [1:0] rb; wire hf, ovf; wire [15:0] frs;
    preview_wr pvw (.rx_clk(pclk), .rx_rst(drst), .ce(ce), .px_de(px_de), .px_sol(px_sol), .px_sof(px_sof),
        .px(px), .freeze(1'b0), .overflow(ovf), .dclk(dclk), .drst(drst),
        .req(pv_req), .baddr(pv_baddr), .wdata(pv_wdata), .gnt(gnt[1]),
        .disp_bank(2'd0), .ready_bank(rb), .have_frame(hf), .frames(frs));

    // Port 2: AXI master tasks (fabric clock)
    reg  [31:0] awaddr = 0, araddr = 0, wdata = 0;
    reg  [7:0]  awlen = 0, arlen = 0;
    reg  [3:0]  wstrb = 0;
    reg  awvalid = 0, wvalid = 0, wlast = 0, bready = 1, arvalid = 0, rready = 1;
    wire awready, wready, bvalid, arready, rvalid_a, rlast;
    wire [31:0] rdata_a;
    wire [1:0] bresp, rresp;
    wire bid, rid;

    axi_ddr #(.AW(27)) ddr_axi (
        .clk(clk), .aresetn(aresetn),
        .s_axi_awid(1'b0), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awburst(2'b01),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(1'b0), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arburst(2'b01),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata_a), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid_a), .s_axi_rready(rready),
        .dclk(dclk), .drst(drst),
        .d_req(d_req), .d_we(d_we), .d_baddr(d_baddr), .d_wdata(d_wdata), .d_wbe(d_wbe),
        .d_gnt(gnt[2]), .d_rvalid(rvalid[2]), .d_rdata(rdata)
    );

    // bytes written over AXI: 0..0xFFFF, and 0x400000..0x4000FF
    reg [7:0] ref1 [0:'h100FF];
    initial for (int i = 0; i <= 'h100FF; i++) ref1[i] = 8'h00;
    function automatic int ri(input [31:0] a);
        ri = a >= 32'h400000 ? 'h10000 + (a - 32'h400000) : a - 32'h300000;
    endfunction

    task automatic axi_write(input [31:0] a, input [31:0] d [], input [3:0] s);
        @(posedge clk);
        awaddr <= a; awlen <= d.size() - 1; awvalid <= 1;
        @(posedge clk); while (!awready) @(posedge clk);
        awvalid <= 0;
        for (int i = 0; i < d.size(); i++) begin
            wdata <= d[i]; wstrb <= s; wlast <= i == d.size() - 1; wvalid <= 1;
            begin
                reg [31:0] w;
                w = d[i];
                for (int b = 0; b < 4; b++) if (s[b]) ref1[ri(a + 4*i + b)] = w[8*b +: 8];
            end
            @(posedge clk); while (!wready) @(posedge clk);
            wvalid <= 0;
        end
        while (!bvalid) @(posedge clk);
    endtask

    task automatic axi_read_check(input [31:0] a, input int n);
        @(posedge clk);
        araddr <= a; arlen <= n - 1; arvalid <= 1;
        @(posedge clk); while (!arready) @(posedge clk);
        arvalid <= 0;
        for (int i = 0; i < n; i++) begin
            reg [31:0] want;
            while (!rvalid_a) @(posedge clk);
            for (int b = 0; b < 4; b++)
                want[8*b +: 8] = ref1[ri(a + 4*i + b)];
            if (rdata_a !== want) begin
                if (errors < 5) $display("  FAIL AXI read %h: got %h want %h", a + 4*i, rdata_a, want);
                errors++;
            end
            if (rlast !== (i == n - 1)) begin $display("  FAIL rlast at beat %0d", i); errors++; end
            @(posedge clk);
        end
    endtask

    initial begin
        #30ms;
        $display("TIMEOUT: axi state %0d, d_req %b, arb busy %b, accesses %0d", ddr_axi.state, d_req, c_busy, accesses);
        $finish;
    end

    initial begin
        reg [31:0] d [];
        repeat (10) @(posedge dclk);
        drst <= 0;
        aresetn <= 1;
        p0_run <= 1;

        // single words at every offset within a burst, then partial strobes
        for (int i = 0; i < 8; i++) begin
            d = new[1]; d[0] = 32'hA5000000 + i;
            axi_write(32'h300100 + 4*i, d, 4'hF);
        end
        d = new[1]; d[0] = 32'h11223344; axi_write(32'h300104, d, 4'b0101);
        d = new[1]; d[0] = 32'hDEADBEEF; axi_write(32'h4_0000_0 + 12, d, 4'b1000);
        $display("singles done at %0t", $time);
        // a 64-beat burst across several DDR bursts
        d = new[64]; foreach (d[i]) d[i] = $urandom;
        axi_write(32'h302000, d, 4'hF);
        axi_read_check(32'h300100, 8);
        axi_read_check(32'h400000, 4);
        axi_read_check(32'h302000, 64);
        axi_read_check(32'h301FF8, 4);      // straddles written and unwritten bytes
        // 64 KB of random beats in 256-beat bursts while the camera writes
        for (int blk = 0; blk < 16; blk++) begin
            d = new[256]; foreach (d[i]) d[i] = $urandom;
            axi_write(32'h308000 + blk * 1024, d, 4'hF);
        end
        for (int blk = 0; blk < 16; blk++) axi_read_check(32'h308000 + blk * 1024, 256);

        // let port 0 run a while longer for the refresh statistics
        repeat (2000) @(posedge dclk);
        p0_run <= 0;
        repeat (200) @(posedge dclk);

        $display("accesses %0d (port 0: %0d issued, %0d reads checked), refreshes %0d, max refresh gap %0t",
                 accesses, p0_done, p0_reads, n_ref, max_gap);
        if (max_gap > 2 * 7800) begin $display("  FAIL refresh gap"); errors++; end
        if (n_ref < 20) begin $display("  FAIL too few refreshes"); errors++; end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule

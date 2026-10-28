// Behavioural AXI4 master tasks, included into a testbench module scope.
// The including module declares: clk, awaddr/awlen/awvalid/awready,
// wdata/wstrb/wlast/wvalid/wready, bready/bvalid/bresp, araddr/arlen/arvalid/
// arready, rready/rvalid/rdata/rresp/rlast. It gets `errors` and
// `backpressure` (randomly stall W/B/R handshakes on the master side).
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

    task automatic write_reg(input logic [31:0] addr, input logic [31:0] value);
        logic [31:0] q[$];
        q = '{value};
        axi_write(addr, q);
    endtask

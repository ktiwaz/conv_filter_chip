// sccb_init + cam_init_rom against an SCCB bus monitor acting as the camera.
// Checks the power-up order and timing, that every bus transaction is a
// 4-byte write to 0x78 carrying the next expected (address, data) from the
// register list (build/cam_init_expected.hex, from scripts/gen_cam_rom.py),
// and that done comes with no NACKs. A second pass with the camera not
// acknowledging must still finish, with NACKs counted.
`timescale 1ns/1ps

module tb_sccb_init;

    parameter EXPECTED = "build/cam_init_expected.hex";

    localparam CLK_HZ  = 1_000_000;      // 1 us per clock
    localparam SCCB_HZ = CLK_HZ / 16;    // 4 clocks per quarter bit
    localparam MS_DIV  = 50;             // "milliseconds" shortened to 50 clocks

    reg clk = 0, rst = 1;
    always #500 clk = ~clk;

    wire pwdn, rst_n, scl_low, sda_low, done;
    wire [7:0] nacks;
    reg  ack_en = 1;                     // camera acknowledges
    reg  slave_sda_low = 0;

    // Open-drain bus with pull-ups
    wire scl = !scl_low;
    wire sda = !(sda_low || slave_sda_low);

    sccb_init #(
        .CLK_HZ(CLK_HZ), .SCCB_HZ(SCCB_HZ), .MS_DIV(MS_DIV)
    ) dut (
        .clk(clk), .rst(rst),
        .pwdn(pwdn), .rst_n(rst_n), .scl_low(scl_low), .sda_low(sda_low),
        .sda_in(sda), .done(done), .nacks(nacks)
    );

    //==================================================
    // Expected writes
    //==================================================
    reg [23:0] exp_w [0:1023];
    int n_exp;
    initial begin
        for (int i = 0; i < 1024; i++) exp_w[i] = 24'hxxxxxx;
        $readmemh(EXPECTED, exp_w);
        n_exp = 0;
        while (n_exp < 1024 && exp_w[n_exp] !== 24'hxxxxxx) n_exp++;
    end

    //==================================================
    // SCCB monitor / camera model
    //==================================================
    int   errors = 0, n_txn = 0, n_bytes, bitn;
    reg [7:0]  shift;
    reg [7:0]  bytes [0:7];
    reg        in_txn = 0;

    // Start / stop: SDA changes while SCL is high
    always @(negedge sda) if (scl) begin
        in_txn = 1; n_bytes = 0; bitn = 0;
    end
    always @(posedge sda) if (scl && in_txn) begin
        in_txn = 0;
        if (n_bytes != 4 || bytes[0] !== 8'h78) begin
            if (errors < 5) $display("  FAIL transaction %0d: %0d bytes, first %02h", n_txn, n_bytes, bytes[0]);
            errors++;
        end else if (n_txn >= n_exp || {bytes[1], bytes[2], bytes[3]} !== exp_w[n_txn]) begin
            if (errors < 5) $display("  FAIL transaction %0d: wrote %02h%02h <- %02h, expected %06h",
                                     n_txn, bytes[1], bytes[2], bytes[3], exp_w[n_txn]);
            errors++;
        end
        n_txn++;
    end

    // Bits are sampled on SCL rising; the 9th clock of each byte is the ACK
    always @(posedge scl) if (in_txn) begin
        if (bitn < 8) shift = {shift[6:0], sda};
        bitn++;
    end
    always @(negedge scl) if (in_txn) begin
        if (bitn == 8) begin
            if (n_bytes < 8) bytes[n_bytes] = shift;
            n_bytes++;
            slave_sda_low = ack_en;      // drive ACK for the 9th clock
        end else if (bitn == 9) begin
            slave_sda_low = 0;
            bitn = 0;
        end
    end

    //==================================================
    // Power sequence checks
    //==================================================
    time t_pwdn_low, t_rst_high, t_first_start;
    initial begin
        t_pwdn_low = 0; t_rst_high = 0; t_first_start = 0;
        @(negedge pwdn) t_pwdn_low = $time;
        @(posedge rst_n) t_rst_high = $time;
    end
    always @(negedge sda) if (scl && t_first_start == 0) t_first_start = $time;

    //==================================================
    // Run
    //==================================================
    initial begin
        repeat (5) @(posedge clk);
        rst <= 0;
        wait (done);
        repeat (10) @(posedge clk);
        $display("pass 1 (camera acks): %0d transactions of %0d expected, %0d NACKs", n_txn, n_exp, nacks);
        if (n_txn != n_exp) begin $display("  FAIL transaction count"); errors++; end
        if (nacks != 0)     begin $display("  FAIL NACKs counted"); errors++; end
        if (!(t_pwdn_low > 0 && t_rst_high > t_pwdn_low && t_first_start > t_rst_high)) begin
            $display("  FAIL power order: pwdn low %0t, reset high %0t, first start %0t", t_pwdn_low, t_rst_high, t_first_start);
            errors++;
        end else if ((t_first_start - t_rst_high) < 30 * MS_DIV * 1000) begin
            $display("  FAIL first SCCB access %0t after reset release (< 30 ms)", t_first_start - t_rst_high);
            errors++;
        end
        if (!(pwdn == 0 && rst_n == 1)) begin $display("  FAIL camera not left powered and running"); errors++; end

        // Pass 2: nobody acknowledges; must still finish and count NACKs
        ack_en = 0;
        n_txn = 0;
        rst <= 1; repeat (3) @(posedge clk); rst <= 0;
        wait (!done);                    // cleared by the reset
        wait (done);
        $display("pass 2 (no camera): done with %0d NACKs (saturates at 255)", nacks);
        if (nacks != 8'hFF) begin $display("  FAIL NACK count"); errors++; end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule

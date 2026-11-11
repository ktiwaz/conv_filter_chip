// Tang Primer 20K top level driven through its UART, the way
// scripts/tb_host.py drives the board: dbg_bridge protocol, register map
// of fpga_tb_core, golden 5x5 testcases. Clock is 48 MHz straight in (SIM=1,
// no rPLL); the UART runs at 3 Mbaud to keep the run short.
`timescale 1ns/1ps

module tb_tp20k;

    parameter INIT_FILE = "input_image_w32.hex";
    parameter TESTCASES = "../../../../testcases/5x5";

    localparam CLK_HZ = 48_000_000;
    localparam BAUD   = 3_000_000;
    localparam real BIT_NS = 1.0e9 / BAUD;

    // fpga_tb_core register map (see rtl/fpga_tb_core.v)
    localparam [31:0] IN_BASE   = 32'h0000_0000;
    localparam [31:0] CAP_BASE  = 32'h0001_0000;
    localparam [31:0] CTRL      = 32'h0002_0000;
    localparam [31:0] STATUS    = 32'h0002_0004;
    localparam [31:0] CAP_COUNT = 32'h0002_0008;
    localparam [31:0] ID        = 32'h0002_000C;
    localparam [31:0] CONFIG    = 32'h0002_0010;
    localparam [31:0] NORM      = 32'h0002_0014;
    localparam [31:0] KSEL      = 32'h0002_0038;
    localparam [31:0] KERNEL    = 32'h0002_0040;
    // dbg_bridge built-in registers
    localparam [31:0] BR_GPIO   = 32'hF000_0000;
    localparam [31:0] BR_STS    = 32'hF000_0004;

    localparam NUM_PIXELS = 16384;
    localparam NUM_WORDS  = NUM_PIXELS / 4;
    localparam MAX_WORDS  = 63;          // 252 bytes per dbg_bridge request

    //==================================================
    // DUT
    //==================================================
    reg  clk = 0;
    always #(1.0e9 / CLK_HZ / 2) clk = ~clk;

    reg        rst_n = 0;
    reg        host_tx = 1;              // -> uart_rx
    wire       host_rx;                  // <- uart_tx
    wire [5:0] led_n;

    tp20k_top #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD),
        .INIT_FILE(INIT_FILE),
        .SIM(1)
    ) dut (
        .clk27(clk),
        .rst_n(rst_n),
        .btn_next_n(1'b1),
        .btn_prev_n(1'b1),
        .uart_rx(host_tx),
        .uart_tx(host_rx),
        .led_n(led_n)
    );

    //==================================================
    // Host UART model
    //==================================================
    integer errors = 0;

    task check(input [8*48-1:0] what, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %0s: got %08h expected %08h", what, got, exp);
            errors = errors + 1;
        end
    endtask

    task send_byte(input [7:0] b);
        integer i;
        begin
            host_tx = 0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                host_tx = b[i];
                #(BIT_NS);
            end
            host_tx = 1;
            #(BIT_NS);
        end
    endtask

    // Receiver: everything the board sends lands in rx_fifo
    reg [7:0] rx_fifo [0:4095];
    integer   rx_wr = 0, rx_rd = 0;

    initial begin : receiver
        integer i;
        reg [7:0] b;
        forever begin
            @(negedge host_rx);
            #(BIT_NS * 1.5);
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = host_rx;
                #(BIT_NS);
            end
            if (host_rx !== 1'b1) begin
                $display("  FAIL framing error from board");
                errors = errors + 1;
            end
            rx_fifo[rx_wr % 4096] = b;
            rx_wr = rx_wr + 1;
        end
    end

    task recv_byte(output [7:0] b);
        integer waited;
        begin
            waited = 0;
            while (rx_rd == rx_wr) begin
                #(BIT_NS);
                waited = waited + 1;
                if (waited > 100000) begin
                    $display("FAIL: timeout waiting for a byte from the board");
                    $finish;
                end
            end
            b = rx_fifo[rx_rd % 4096];
            rx_rd = rx_rd + 1;
        end
    endtask

    //==================================================
    // dbg_bridge protocol: cmd, length (bytes), address (big endian),
    // then data (little endian). Writes have no response.
    //==================================================
    reg [31:0] buf_w [0:NUM_WORDS-1];    // words to write / words read

    task bridge_hdr(input [7:0] cmd, input [7:0] len, input [31:0] addr);
        begin
            send_byte(cmd);
            send_byte(len);
            send_byte(addr[31:24]);
            send_byte(addr[23:16]);
            send_byte(addr[15:8]);
            send_byte(addr[7:0]);
        end
    endtask

    // Write n words from buf_w[0..n-1]
    task write_words(input [31:0] addr, input integer n);
        integer i, k, chunk;
        begin
            for (i = 0; i < n; i = i + chunk) begin
                chunk = (n - i > MAX_WORDS) ? MAX_WORDS : n - i;
                bridge_hdr(8'h10, chunk * 4, addr + i * 4);
                for (k = 0; k < chunk * 4; k = k + 1)
                    send_byte(buf_w[i + k / 4] >> (8 * (k % 4)));
            end
        end
    endtask

    // Read n words into buf_w[0..n-1]
    task read_words(input [31:0] addr, input integer n);
        integer i, k, chunk;
        reg [7:0] b;
        begin
            for (i = 0; i < n; i = i + chunk) begin
                chunk = (n - i > MAX_WORDS) ? MAX_WORDS : n - i;
                bridge_hdr(8'h11, chunk * 4, addr + i * 4);
                for (k = 0; k < chunk * 4; k = k + 1) begin
                    recv_byte(b);
                    buf_w[i + k / 4][8 * (k % 4) +: 8] = b;
                end
            end
        end
    endtask

    task write_reg(input [31:0] addr, input [31:0] value);
        begin
            buf_w[0] = value;
            write_words(addr, 1);
        end
    endtask

    task read_reg(input [31:0] addr, output [31:0] value);
        begin
            read_words(addr, 1);
            value = buf_w[0];
        end
    endtask

    //==================================================
    // Golden testcase, as tb_host.py run_testcase does it
    //==================================================
    reg [7:0] kern  [0:27];
    reg [7:0] img   [0:NUM_PIXELS-1];
    reg [7:0] exp_o [0:NUM_PIXELS-1];

    task run_testcase(input string name, input [31:0] norm, input tmode);
        reg [31:0] v, count;
        integer i, bad, n_exp;
        begin
            for (i = 0; i < 28; i = i + 1) kern[i] = 8'd0;
            for (i = 0; i < NUM_PIXELS; i = i + 1) exp_o[i] = 8'hxx;
            $readmemh($sformatf("%0s/%0s/kernel.hex", TESTCASES, name), kern, 0, 24);
            $readmemh($sformatf("%0s/%0s/input_image.hex", TESTCASES, name), img);
            $readmemh($sformatf("%0s/%0s/expected_output_image.hex", TESTCASES, name), exp_o);
            n_exp = 0;
            for (i = 0; i < NUM_PIXELS; i = i + 1) if (exp_o[i] !== 8'hxx) n_exp = i + 1;
            if (n_exp == 0) begin
                $display("FAIL: no expected output for %0s", name);
                $finish;
            end

            for (i = 0; i < 7; i = i + 1)
                buf_w[i] = {kern[4*i+3], kern[4*i+2], kern[4*i+1], kern[4*i]};
            write_words(KERNEL, 7);
            read_words(KERNEL, 7);
            for (i = 0; i < 7; i = i + 1)
                check("kernel readback", buf_w[i], {kern[4*i+3], kern[4*i+2], kern[4*i+1], kern[4*i]});
            write_reg(NORM, norm);
            write_reg(CONFIG, {30'd0, tmode, 1'b0});

            for (i = 0; i < NUM_WORDS; i = i + 1)
                buf_w[i] = {img[4*i+3], img[4*i+2], img[4*i+1], img[4*i]};
            write_words(IN_BASE, NUM_WORDS);
            write_reg(CTRL, 32'd1);

            i = 0;
            do begin
                read_reg(STATUS, v);
                i = i + 1;
            end while (!v[1] && i < 100);
            check("done", v[1], 1'b1);
            check("DUT not in ERROR", v[5:4] == 2'd3, 1'b0);

            read_reg(CAP_COUNT, count);
            check("CAP_COUNT", count, n_exp);
            read_words(CAP_BASE, (count + 3) / 4);
            bad = 0;
            for (i = 0; i < n_exp; i = i + 1)
                if (buf_w[i / 4][8 * (i % 4) +: 8] !== exp_o[i]) begin
                    if (bad < 5)
                        $display("  FAIL %0s pixel %0d: got %02h expected %02h",
                                 name, i, buf_w[i / 4][8 * (i % 4) +: 8], exp_o[i]);
                    bad = bad + 1;
                end
            check("pixel mismatches", bad, 0);
            $display("  %0s: %0d pixels, %0d mismatches", name, count, bad);
        end
    endtask

    //==================================================
    // Test sequence
    //==================================================
    reg [31:0] v;
    integer i;

    initial begin
        #(1000);
        rst_n = 1;
        #(2000);

        $display("[1] bridge status and the ID register");
        read_reg(BR_STS, v);
        check("bridge STS", v[31:16], 16'hCAFE);
        read_reg(ID, v);
        check("ID", v, 32'hC0F1_0005);
        read_reg(BR_GPIO, v);
        check("GPIO = filter preset (reset: emboss = 1)", v, 32'd1);

        $display("[2] multi-request write / read of the input RAM");
        for (i = 0; i < 200; i = i + 1) buf_w[i] = 32'hA500_0000 | (i * 32'h10101);
        write_words(IN_BASE + 32'h100, 200);
        for (i = 0; i < 200; i = i + 1) buf_w[i] = 32'd0;
        read_words(IN_BASE + 32'h100, 200);
        for (i = 0; i < 200; i = i + 1)
            check("RAM readback", buf_w[i], 32'hA500_0000 | (i * 32'h10101));

        $display("[3] resync after a truncated write request");
        bridge_hdr(8'h10, 8'd8, IN_BASE + 32'h800);   // the flush completes it harmlessly
        send_byte(8'h12);                      // 1 of 8 data bytes, then nothing
        for (i = 0; i < 260; i = i + 1) send_byte(8'h00);
        read_reg(ID, v);
        check("ID after resync", v, 32'hC0F1_0005);

        $display("[4] filter preset select");
        write_reg(KSEL, 32'd5);
        read_reg(BR_GPIO, v);
        check("GPIO = preset 5", v, 32'd5);
        check("LEDs show preset", {28'd0, ~led_n[5:2]}, 32'd5);

        $display("[5] golden testcases through the UART");
        run_testcase("emboss",    32'd3277, 1'b0);
        run_testcase("test_mode", 32'd1311, 1'b1);

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule

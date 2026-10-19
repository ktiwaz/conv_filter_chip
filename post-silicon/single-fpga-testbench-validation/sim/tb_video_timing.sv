// Checks video_timing against CEA 720p60: totals, active area, sync widths.
`timescale 1ns/1ps
module tb_video_timing;
    logic clk = 0, rst = 1;
    always #6.734 clk = ~clk;   // 74.25 MHz

    wire [11:0] x, y;
    wire de, hs, vs, fs;
    video_timing dut (.clk(clk), .rst(rst), .x(x), .y(y), .de(de), .hs(hs), .vs(vs), .frame_start(fs));

    int errors = 0;
    longint cyc = 0, de_cnt = 0, hs_cnt = 0, vs_lines = 0, frames = 0, frame_len = 0, last_fs = -1;
    int hs_w = 0, hs_w_max = 0;
    logic hs_q = 0, vs_q = 0;

    always @(posedge clk) if (!rst) begin
        cyc++;
        if (fs) begin
            if (last_fs >= 0) frame_len = cyc - last_fs;
            last_fs = cyc;
            frames++;
        end
        if (frames == 2) begin   // measure the second full frame
            if (de) de_cnt++;
            if (hs && !hs_q) hs_cnt++;
            if (vs && !vs_q) vs_lines = 0;
        end
        hs_w = hs ? hs_w + 1 : 0;
        if (hs_w > hs_w_max) hs_w_max = hs_w;
        hs_q <= hs;
        vs_q <= vs;
    end

    task automatic check(string what, longint got, longint exp);
        if (got != exp) begin errors++; $display("  FAIL %s: got %0d expected %0d", what, got, exp); end
        else $display("  ok   %s = %0d", what, got);
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 0;
        wait (frames == 3);
        check("cycles per frame", frame_len, 1650 * 750);
        check("active pixels", de_cnt, 1280 * 720);
        check("hsync pulses per frame", hs_cnt, 750);
        check("hsync width", hs_w_max, 40);
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule

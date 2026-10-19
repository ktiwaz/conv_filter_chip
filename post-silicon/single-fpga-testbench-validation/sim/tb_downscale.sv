// Standalone check of video_downscale across irregular input frames.
`timescale 1ns/1ps
module tb_downscale;
    logic clk = 0;  always #10 clk = ~clk;
    logic rx_clk = 0; always #6.7 rx_clk = ~rx_clk;
    logic rx_rst = 1;
    logic [23:0] rx_d = 0;
    logic rx_de = 0;
    int hc = 0, vc = 0, frame = 0;
    int cut_frame = 1, cut_line = 333;   // frame 1 is cut short at line 333

    wire tog, bank;
    wire [11:0] h, v;
    logic rd_en = 0, rd_bank = 0;
    logic [11:0] rd_addr = 0;
    wire [31:0] rd_data;

    video_downscale dut (.rx_clk(rx_clk), .rx_rst(rx_rst), .rx_data(rx_d), .rx_de(rx_de),
        .frame_toggle(tog), .frame_bank(bank), .h_active(h), .v_active(v),
        .clk(clk), .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr), .rd_data(rd_data));

    function automatic logic [23:0] rgb(int x, int y);
        logic [7:0] r, g, b;
        r = 8'(3 * x + y); g = 8'(x ^ y); b = 8'(x + 2 * y);
        return {r, b, g};   // dvi2rgb order {R, B, G}
    endfunction

    always @(posedge rx_clk) if (!rx_rst) begin
        rx_de <= hc < 1280 && vc < 720;
        rx_d  <= rgb(hc, vc);
        hc++;
        if (hc == 1650) begin
            hc = 0; vc++;
            if (frame == cut_frame && vc == cut_line) vc = 720;
            if (vc == 750) begin vc = 0; frame++; end
        end
    end

    logic tog_q = 0;
    always @(posedge rx_clk) begin
        if (hc == 0 && vc == 0)
            $display("frame %0d start: row=%0d sub_y=%0d", frame, dut.row, dut.sub_y);
        tog_q <= tog;
        if (tog != tog_q) $display("  published bank %0d during frame %0d at line %0d", bank, frame, vc);
    end

    // Every publication must happen at the end of the crop window (line 679)
    int bad = 0, pubs = 0;
    always @(posedge rx_clk) if (tog != tog_q) begin
        pubs++;
        if (vc != 679) bad++;
    end

    initial begin
        repeat (10) @(posedge rx_clk);
        rx_rst = 0;
        wait (frame == 4);
        if (bad == 0 && pubs >= 2) $display("PASS: %0d frames published, all at line 679", pubs);
        else $display("FAIL: %0d of %0d publications away from line 679", bad, pubs);
        $finish;
    end
endmodule

// rgb_grab + plane_dma through ddr_arb and a behavioural ddr3_ctrl: a
// synthetic RGB565 camera frame (pix565 at ~46 MHz) is averaged 3x3 into
// 128x128 R, G, B, Y in DDR3; then each channel is copied into the plane RAM
// and read back through its fabric-clock port, word by word, against a
// reference computed here from the same pixels (including the Y weights and
// rounding of rgb_grab).
`timescale 1ns/1ps

module tb_color_grab;

    localparam BA_W = 23;
    reg pclk = 0, dclk = 0, clk = 0;
    always #10.8 pclk = ~pclk;           // 46.3 MHz camera
    always #5.29 dclk = ~dclk;           // 94.5 MHz DDR3
    always #10.77 clk = ~clk;            // 46.4 MHz fabric
    reg rst = 1, drst = 1;

    // frame pixels: RGB565 from a hash of (x, y)
    function automatic [15:0] pixel(input int x, input int y);
        int h;
        h = (x * 7919 + y * 104729) ^ (x * y * 31);
        pixel = h[15:0];
    endfunction
    function automatic [7:0] e5(input [4:0] v); e5 = {v, v[4:2]}; endfunction
    function automatic [7:0] e6(input [5:0] v); e6 = {v, v[5:4]}; endfunction

    // reference: 128x128 x {R, G, B, Y}
    reg [7:0] ref_c [0:3][0:16383];
    initial begin
        for (int by = 0; by < 128; by++)
            for (int bx = 0; bx < 128; bx++) begin
                int sr, sg, sb; reg [25:0] p; reg [7:0] r, g, b; reg [15:0] l;
                sr = 0; sg = 0; sb = 0;
                for (int dy = 0; dy < 3; dy++)
                    for (int dx = 0; dx < 3; dx++) begin
                        reg [15:0] v; v = pixel(bx * 3 + dx, by * 3 + dy);
                        sr += e5(v[15:11]); sg += e6(v[10:5]); sb += e5(v[4:0]);
                    end
                p = sr * 7282 + 32768; r = p[23:16];
                p = sg * 7282 + 32768; g = p[23:16];
                p = sb * 7282 + 32768; b = p[23:16];
                l = 54 * r + 183 * g + 18 * b;
                ref_c[0][by * 128 + bx] = r; ref_c[1][by * 128 + bx] = g;
                ref_c[2][by * 128 + bx] = b; ref_c[3][by * 128 + bx] = l[15:8];
            end
    end

    // camera: two frames
    reg [7:0] d = 0; reg href = 0; reg [7:0] d_q; reg href_q;
    always @(posedge pclk) begin d_q <= d; href_q <= href; end
    int sent = 0;
    initial begin
        @(negedge rst);
        repeat (20) @(posedge pclk);
        for (int f = 0; f < 2; f++) begin
            repeat (9000) @(posedge pclk);
            for (int y = 0; y < 384; y++) begin
                for (int x = 0; x < 384; x++) begin
                    @(posedge pclk); href <= 1; d <= pixel(x, y) >> 8;
                    @(posedge pclk);            d <= pixel(x, y);
                end
                @(posedge pclk); href <= 0;
                repeat (600) @(posedge pclk);
            end
            sent++;
        end
    end
    wire ce, px_de, px_sol, px_sof; wire [15:0] px; wire [23:0] rbg;
    pix565 pix (.clk(pclk), .rst(rst), .d(d_q), .de(href_q), .ce(ce), .px_de(px_de),
                .px_sol(px_sol), .px_sof(px_sof), .px(px), .rgb_rbg(rbg));

    // DUT
    wire [1:0] req, gnt, rvalid; wire [127:0] rdata;
    wire [BA_W-1:0] g_baddr, d_baddr; wire [127:0] g_wdata;
    wire gr_toggle, gr_bank; wire [15:0] gr_frames; wire [11:0] hact, vact;
    rgb_grab grab (.rx_clk(pclk), .rx_rst(rst), .ce(ce), .px_de(px_de), .px_sol(px_sol), .px_sof(px_sof),
        .px(px), .h_active(hact), .v_active(vact), .dclk(dclk), .drst(drst),
        .req(req[0]), .baddr(g_baddr), .wdata(g_wdata), .gnt(gnt[0]),
        .frame_toggle(gr_toggle), .frame_bank(gr_bank), .frames(gr_frames));

    reg  dma_bank = 0; reg [1:0] dma_ch = 0; reg dma_req_t = 0; wire dma_done_t;
    reg  rd_en = 0; reg [11:0] rd_addr = 0; wire [31:0] rd_data;
    plane_dma dma (.clk(clk), .bank(dma_bank), .ch(dma_ch), .req_t(dma_req_t), .done_t(dma_done_t),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data),
        .dclk(dclk), .drst(drst), .req(req[1]), .baddr(d_baddr), .gnt(gnt[1]),
        .rvalid(rvalid[1]), .rdata(rdata));

    wire c_rd, c_wr, c_refresh; wire [BA_W+2:0] c_addr; wire [127:0] c_din; wire [15:0] c_be;
    reg  c_busy = 0, c_dr = 0; reg [127:0] c_dout = 0; wire [31:0] acc;
    ddr_arb #(.NP(2), .BA_W(BA_W), .REFRESH_CYC(737)) arb (
        .clk(dclk), .rst(drst), .ready(1'b1),
        .req(req), .we(2'b01), .baddr({d_baddr, g_baddr}), .wdata({128'd0, g_wdata}),
        .wbe({16'd0, 16'hFFFF}), .gnt(gnt), .rvalid(rvalid), .rdata(rdata),
        .c_rd(c_rd), .c_wr(c_wr), .c_refresh(c_refresh), .c_addr(c_addr),
        .c_din_burst(c_din), .c_be_burst(c_be), .c_busy(c_busy), .c_data_ready(c_dr),
        .c_dout_burst(c_dout), .accesses(acc));

    // controller model (as tb_ddr_arb), memory for the grab banks only
    reg [127:0] mem [0:8191];            // bursts 0x20000 .. 0x21FFF
    int cnt = 0; reg op_rd = 0; int op_ba = 0;
    always @(posedge dclk) begin
        c_dr <= 0;
        if (c_busy) begin
            if (cnt == 0) begin
                c_busy <= 0;
                if (op_rd) begin c_dr <= 1; c_dout <= mem[op_ba]; end
            end else cnt <= cnt - 1;
        end else if (c_rd || c_wr || c_refresh) begin
            c_busy <= 1; cnt <= c_refresh ? 12 : $urandom_range(15, 30);
            op_rd <= c_rd; op_ba <= c_addr[BA_W+2:3] - 'h20000;
            if (c_wr) mem[c_addr[BA_W+2:3] - 'h20000] = c_din;
        end
    end

    // fabric side: after each grabbed frame, DMA all four channels and check
    int errors = 0, checked = 0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] ft = 0, dd = 0;
    always @(posedge clk) begin ft <= {ft[1:0], gr_toggle}; dd <= {dd[1:0], dma_done_t}; end
    initial begin
        repeat (5) @(posedge clk);
        rst <= 0; drst <= 0;
        for (int f = 0; f < 2; f++) begin
            @(posedge clk); while (ft[2] == ft[1]) @(posedge clk);
            dma_bank <= gr_bank;
            for (int c = 0; c < 4; c++) begin
                @(posedge clk); dma_ch <= c; dma_req_t <= !dma_req_t;
                @(posedge clk); while (dd[2] == dd[1]) @(posedge clk);
                for (int w = 0; w < 4096; w++) begin
                    @(posedge clk); rd_en <= 1; rd_addr <= w;
                    @(posedge clk); rd_en <= 0;
                    @(posedge clk);
                    for (int j = 0; j < 4; j++)
                        if (rd_data[8 * j +: 8] !== ref_c[c][4 * w + j]) begin
                            if (errors < 8) $display("  FAIL frame %0d ch %0d px %0d: got %0d want %0d",
                                                     f, c, 4 * w + j, rd_data[8 * j +: 8], ref_c[c][4 * w + j]);
                            errors++;
                        end
                    checked += 4;
                end
            end
            $display("frame %0d (bank %0d): 4 channels checked", f, dma_bank);
        end
        $display("%0d pixels checked, %0d frames grabbed, measured %0dx%0d", checked, gr_frames, hact, vact);
        if (hact != 384 || vact != 384) begin $display("  FAIL frame size"); errors++; end
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule

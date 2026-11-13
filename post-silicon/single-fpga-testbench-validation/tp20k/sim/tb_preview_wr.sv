// pix565 + preview_wr: a synthetic DVP RGB565 camera (2 bytes per pixel,
// line and frame blanking) at ~46 MHz into the writer, whose DDR port is
// granted after a random delay (as ddr_arb would with other traffic). Every
// written burst must carry the 8 pixels of its address, each frame must use a
// bank other than ready and displayed, and complete frames must be published.
`timescale 1ns/1ps

module tb_preview_wr;

    localparam W = 384, H = 384, LINE_STRIDE = 64, BANK = 23'h8000;
    reg pclk = 0, dclk = 0;
    always #10.8 pclk = ~pclk;           // 46.3 MHz
    always #4.63 dclk = ~dclk;           // 108 MHz
    reg rst = 1, drst = 1;

    // camera: frame f, pixel (x, y) = {f[1:0], y[6:0], x[6:0]}
    reg [7:0] d = 0;
    reg       href = 0;
    function automatic [15:0] pixval(input int f, input int x, input int y);
        pixval = {f[1:0], y[6:0], x[6:0]};
    endfunction
    int frames_sent = 0;
    initial begin
        @(negedge rst);
        repeat (20) @(posedge pclk);
        for (int f = 0; f < 3; f++) begin
            repeat (9000) @(posedge pclk);                       // vertical blank
            for (int y = 0; y < H; y++) begin
                for (int x = 0; x < W; x++) begin
                    @(posedge pclk); href <= 1; d <= pixval(f, x, y) >> 8;
                    @(posedge pclk);            d <= pixval(f, x, y);
                end
                @(posedge pclk); href <= 0;
                repeat (600) @(posedge pclk);                    // horizontal blank
            end
            frames_sent++;
        end
    end

    wire ce, px_de, px_sol, px_sof;
    wire [15:0] px;
    wire [23:0] rbg;
    reg  [7:0] d_q; reg href_q;
    always @(posedge pclk) begin d_q <= d; href_q <= href; end
    pix565 pix (.clk(pclk), .rst(rst), .d(d_q), .de(href_q),
                .ce(ce), .px_de(px_de), .px_sol(px_sol), .px_sof(px_sof), .px(px), .rgb_rbg(rbg));

    wire req, have_frame, overflow;
    wire [22:0] baddr;
    wire [127:0] wdata;
    wire [1:0] ready_bank;
    wire [15:0] frames;
    reg  gnt = 0;
    reg  [1:0] disp_bank = 2'd0;

    preview_wr #(.BANK_STRIDE(BANK), .LINE_STRIDE(LINE_STRIDE)) dut (
        .rx_clk(pclk), .rx_rst(rst), .ce(ce), .px_de(px_de), .px_sol(px_sol), .px_sof(px_sof),
        .px(px), .freeze(1'b0), .overflow(overflow),
        .dclk(dclk), .drst(drst), .req(req), .baddr(baddr), .wdata(wdata), .gnt(gnt),
        .disp_bank(disp_bank), .ready_bank(ready_bank), .have_frame(have_frame), .frames(frames)
    );

    // grant after 0..40 cycles; check the burst at the grant
    int errors = 0, bursts = 0, wait_left = -1;
    int frame_of_bank [3];
    always @(posedge dclk) begin
        gnt <= 0;
        if (req && !gnt) begin
            if (wait_left < 0) wait_left = $urandom_range(0, 40);
            else if (wait_left == 0) begin
                int bank, y, bx, f;
                gnt <= 1; wait_left = -1; bursts++;
                bank = baddr / BANK; y = (baddr % BANK) / LINE_STRIDE; bx = baddr % LINE_STRIDE;
                f = wdata[15:14];
                if (bank == ready_bank && have_frame || bank == disp_bank || bank > 2) begin
                    if (errors < 5) $display("  FAIL burst into bank %0d (ready %0d, disp %0d)", bank, ready_bank, disp_bank);
                    errors++;
                end
                for (int k = 0; k < 8; k++) begin
                    reg [15:0] want;
                    want = pixval(f, bx * 8 + k, y);
                    if (wdata[16*k +: 16] !== want) begin
                        if (errors < 5) $display("  FAIL bank %0d y %0d bx %0d word %0d: %h, want %h", bank, y, bx, k, wdata[16*k +: 16], want);
                        errors++;
                    end
                end
            end else wait_left--;
        end
    end

    // the display follows the newest frame now and then
    always @(posedge dclk) if (have_frame && $urandom_range(0, 200000) == 0) disp_bank <= ready_bank;

    initial begin
        repeat (5) @(posedge pclk);
        rst <= 0; drst <= 0;
        wait (frames_sent == 3);
        repeat (2000) @(posedge dclk);
        $display("%0d bursts checked, %0d frames published, overflow %b", bursts, frames, overflow);
        if (bursts != 3 * H * W / 8) begin $display("  FAIL burst count (want %0d)", 3 * H * W / 8); errors++; end
        if (frames != 3) begin $display("  FAIL frames published"); errors++; end
        if (overflow) begin $display("  FAIL FIFO overflow"); errors++; end
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule

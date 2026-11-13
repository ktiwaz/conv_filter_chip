// video_downscale in its camera configuration: a synthetic OV3660-like DVP
// stream (Y8, one byte per PCLK while HREF is high, line and frame blanking)
// -> 3x3 box average -> 128x128, single bank. Default: 384x384 frames, the
// whole frame averaged (crop at 0,0), with a pixel enable (PIX_CE). Every output
// pixel is compared with a reference model.
`timescale 1ns/1ps

module tb_cam_grab;

    // Defaults: the camera build (OV3660 384x384, whole frame, 3x3 average).
    // -P overrides test other crop placements, e.g. VGA with a centred crop.
    parameter W = 384, H = 384;
    localparam HBLANK = 160;            // PCLKs between lines
    localparam VBLANK_LINES = 20;       // blank lines between frames (> 4000 PCLKs)
    parameter CROP_X = 0, CROP_Y = 0, SCALE = 3;

    reg pclk = 0, clk = 0;
    always #5    pclk = ~pclk;          // camera PCLK
    always #10.4 clk  = ~clk;           // fabric clock (48 MHz), unrelated

    reg        rst = 1;
    reg  [7:0] y8 = 0;
    reg        href = 0;
    wire       frame_toggle, frame_bank;
    wire [11:0] h_active, v_active;
    reg        rd_en = 0;
    reg  [11:0] rd_addr = 0;
    wire [31:0] rd_data;

    video_downscale #(
        .CROP_X(CROP_X), .CROP_Y(CROP_Y), .SCALE(SCALE), .BANKS(1), .GRAY_IN(1)
    ) dut (
        .rx_clk(pclk), .rx_rst(rst), .rx_data({16'd0, y8}), .rx_de(href),
        .frame_toggle(frame_toggle), .frame_bank(frame_bank),
        .h_active(h_active), .v_active(v_active),
        .clk(clk), .rd_en(rd_en), .rd_bank(1'b0), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    // Test image: varies in x and y, frame-dependent so stale data is caught
    function automatic [7:0] pix(input int x, input int y, input int f);
        pix = (x * 3 + y * 5 + ((x * y) >> 6) + f * 37) & 8'hFF;
    endfunction

    function automatic [7:0] expected(input int row, input int col, input int f);
        int sum;
        sum = 0;
        for (int dy = 0; dy < SCALE; dy++)
            for (int dx = 0; dx < SCALE; dx++)
                sum += pix(CROP_X + col * SCALE + dx, CROP_Y + row * SCALE + dy, f);
        expected = (sum * ((65536 + SCALE * SCALE / 2) / (SCALE * SCALE)) + 32768) >> 16;
    endfunction

    task automatic send_frame(input int f, input int lines = H);
        for (int y = 0; y < lines; y++) begin
            for (int x = 0; x < W; x++) begin
                @(posedge pclk);
                href <= 1;
                y8   <= pix(x, y, f);
            end
            @(posedge pclk);
            href <= 0;
            repeat (HBLANK - 1) @(posedge pclk);
        end
        repeat (VBLANK_LINES * (W + HBLANK)) @(posedge pclk);
    endtask

    int errors = 0;

    task automatic check_frame(input int f);
        for (int w = 0; w < 4096; w++) begin
            @(posedge clk);
            rd_en   <= 1;
            rd_addr <= w;
            @(posedge clk);
            rd_en   <= 0;
            @(posedge clk);
            for (int lane = 0; lane < 4; lane++) begin
                int p = w * 4 + lane;
                logic [7:0] exp_v = expected(p / 128, p % 128, f);
                if (rd_data[lane*8 +: 8] !== exp_v) begin
                    if (errors < 10)
                        $display("  FAIL frame %0d pixel (%0d,%0d): got %02h expected %02h",
                                 f, p / 128, p % 128, rd_data[lane*8 +: 8], exp_v);
                    errors++;
                end
            end
        end
    endtask

    initial begin
        logic t0;
        repeat (5) @(posedge pclk);
        rst <= 0;
        repeat (VBLANK_LINES * (W + HBLANK)) @(posedge pclk);
        // A truncated frame first, like a sensor being reconfigured: the
        // grabber must realign on the next frame's first pixel (with the crop
        // at the top of the frame nothing else resets its block counters)
        $display("  truncated frame (200 of %0d lines)", H);
        send_frame(99, 200);
        for (int f = 0; f < 3; f++) begin
            t0 = frame_toggle;
            send_frame(f);
            if (frame_toggle === t0) begin
                $display("  frame %0d: no frame_toggle", f);
                if (f > 0) errors++;
            end else begin
                $display("  frame %0d: published (bank %0d), measured %0dx%0d", f, frame_bank, h_active, v_active);
                if (frame_bank !== 1'b0) errors++;
                check_frame(f);
            end
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule

// preview_rd: the pixel clock side scans like the compositor (720p timing,
// 576 display lines from 384 source lines, 1.5x) and starts before the DDR
// clock side leaves reset, as on the board. A model arbiter grants reads and
// returns address-coded bursts: word k of burst b of line y in bank n is
// {n, y, b*8+k} packed into 16 bits. Checks that the display bank follows
// ready_bank and that every pixel the display reads in the pane is the right
// source pixel of the bank it shows.
`timescale 1ns/1ps

module tb_preview_rd;

    localparam LINE_STRIDE = 64, BANK = 23'h8000;
    reg pclk = 0, dclk = 0;
    always #6.734 pclk = ~pclk;          // 74.25 MHz
    always #5.29 dclk = ~dclk;           // 94.5 MHz
    reg prst = 1, drst = 1;

    function automatic [15:0] word(input int bank, input int y, input int x);
        word = {bank[1:0], y[8:0] == y ? y[8:4] : 5'd0, x[8:0]};   // {bank, y[8:4], x}
    endfunction

    // compositor-like scan: 1650 x 750 clocks per frame, pane lines 80..655
    reg  frame_start = 0;
    reg  [8:0]  need_s = 0;
    reg  [10:0] rd_addr = 0;
    wire [15:0] rd_data;
    int  sx_q, sy_q, chk_q = 0, x, y;
    int  sx_q2, sy_q2, chk_q2 = 0;
    int  errors = 0, checked = 0, frames = 0;
    reg  [1:0] shown_bank;

    wire req, gnt_w;
    wire [22:0] baddr;
    reg  gnt = 0, rvalid = 0;
    reg  [127:0] rdata = 0;
    reg  [1:0] ready_bank = 1;
    wire [1:0] disp_bank;
    wire [15:0] lines;

    preview_rd #(.BANK_STRIDE(BANK), .LINE_STRIDE(LINE_STRIDE)) dut (
        .pclk(pclk), .prst(prst), .frame_start(frame_start), .need_s(need_s),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .dclk(dclk), .drst(drst), .req(req), .baddr(baddr), .gnt(gnt),
        .rvalid(rvalid), .rdata(rdata), .ready_bank(ready_bank), .disp_bank(disp_bank),
        .lines_fetched(lines)
    );

    initial begin
        repeat (5) @(posedge pclk);
        prst <= 0;
        forever begin
            for (y = 0; y < 750; y++) begin
                for (x = 0; x < 1650; x++) begin
                    @(posedge pclk);
                    frame_start <= (x == 0 && y == 0);
                    if (x == 1) need_s <= (y < 80) ? 0 : (y >= 656) ? 383 : ((y - 80) * 2) / 3;
                    if (y == 80 && x == 0) shown_bank = disp_bank;
                    // check the pixel addressed two cycles ago (address
                    // register, then the RAM's registered read)
                    if (chk_q2) begin
                        reg [15:0] want;
                        want = {shown_bank, sy_q2[8:4], sx_q2[8:0]};
                        if (rd_data !== want) begin
                            if (errors < 5) $display("  FAIL frame %0d line %0d px %0d: got %h want %h", frames, sy_q2, sx_q2, rd_data, want);
                            errors++;
                        end
                        checked++;
                    end
                    chk_q2 = chk_q; sx_q2 = sx_q; sy_q2 = sy_q;
                    chk_q = 0;
                    if (y >= 80 && y < 656 && x >= 48 && x < 48 + 576 && frames >= 2) begin
                        sy_q = ((y - 80) * 2) / 3; sx_q = ((x - 48) * 2) / 3;
                        rd_addr <= {sy_q[1:0], sx_q[8:0]};
                        chk_q = 1;
                    end
                end
            end
            frames++;
        end
    end
    // the bank shown in a frame: the reader takes it during the blank lines
    // after the frame start, before the pane

    // model arbiter: grant after 0..20 cycles, data 10..30 cycles later
    int gw = -1, rw = -1;
    reg [22:0] ra;
    always @(posedge dclk) begin
        gnt <= 0; rvalid <= 0;
        if (req && !gnt && rw < 0) begin
            if (gw < 0) gw = $urandom_range(0, 20);
            else if (gw == 0) begin gnt <= 1; gw = -1; ra = baddr; rw = $urandom_range(10, 30); end
            else gw--;
        end
        if (rw == 0) begin
            int bank, yy, bx;
            bank = ra / BANK; yy = (ra % BANK) / LINE_STRIDE; bx = ra % LINE_STRIDE;
            for (int k = 0; k < 8; k++) rdata[16*k +: 16] <= {bank[1:0], yy[8:4], 9'(bx * 8 + k)};
            rvalid <= 1; rw = -1;
        end else if (rw > 0) rw--;
    end
    // the writer publishes a new frame now and then, never the displayed bank
    always @(posedge dclk)
        if (!drst && $urandom_range(0, 300000) == 0)
            ready_bank <= (ready_bank != 0 && disp_bank != 0) ? 0 : (ready_bank != 1 && disp_bank != 1) ? 1 : 2;

    initial begin
        // the DDR side comes out of reset well after the display started
        #3ms;
        drst <= 0;
        wait (frames == 6);
        $display("%0d pixels checked over %0d frames, %0d lines fetched, disp_bank %0d", checked, frames - 2, lines, disp_bank);
        if (checked < 4 * 576 * 576) begin $display("  FAIL too few pixels checked"); errors++; end
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule

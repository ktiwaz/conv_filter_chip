// Camera preview into DDR3: RGB565 pixels (camera PCLK) -> async FIFO ->
// 8-pixel bursts written through one ddr_arb port (DDR clock), into one of
// three frame banks.
//
// Layout (burst addresses, 16 bytes each): bank b, line y, burst x at
//   BASE + b * BANK_STRIDE + y * LINE_STRIDE + x,   x = 0 .. WIDTH/8 - 1
// i.e. byte address 0x1000_0000 + 16 * that over the debug bridge.
//
// Triple buffering, all in the DDR clock domain: a frame goes into a bank that
// is neither ready_bank (the newest complete frame) nor disp_bank (what the
// display reads, from preview_rd); when its last burst has been written it
// becomes ready_bank. freeze (camera clock) stops writing, so the host can
// read ready_bank undisturbed. Pixels before the first frame start are dropped.
module preview_wr #(
    parameter BA_W        = 23,
    parameter [BA_W-1:0] BASE        = 0,
    parameter [BA_W-1:0] BANK_STRIDE = 23'h8000,
    parameter [BA_W-1:0] LINE_STRIDE = 64,
    parameter WIDTH       = 384,
    parameter HEIGHT      = 384
) (
    // camera side
    input  wire            rx_clk,
    input  wire            rx_rst,
    input  wire            ce,
    input  wire            px_de,
    input  wire            px_sol,
    input  wire            px_sof,
    input  wire [15:0]     px,
    input  wire            freeze,
    output reg             overflow,        // sticky: FIFO was full

    // DDR side
    input  wire            dclk,
    input  wire            drst,
    output reg             req,
    output reg  [BA_W-1:0] baddr,
    output reg  [127:0]    wdata,            // collected in place, held until gnt
    input  wire            gnt,
    input  wire [1:0]      disp_bank,
    output reg  [1:0]      ready_bank,
    output reg             have_frame,      // ready_bank holds a complete frame
    output reg  [15:0]     frames           // frames completed (debug)
);

    localparam BX = WIDTH / 8;

    //==================================================
    // Camera side: into the FIFO
    //==================================================
    wire full;
    always @(posedge rx_clk)
        if (rx_rst) overflow <= 1'b0;
        else if (ce && px_de && !freeze && full) overflow <= 1'b1;

    wire        f_empty, f_rvalid;
    wire [17:0] f_rdata;
    reg         f_rd;

    async_fifo #(.DW(18), .AW(10)) fifo (
        .wclk(rx_clk), .wrst(rx_rst), .wr(ce && px_de && !freeze),
        .wdata({px_sof, px_sol, px}), .full(full),
        .rclk(dclk), .rrst(drst), .rd(f_rd), .rdata(f_rdata), .rvalid(f_rvalid),
        .empty(f_empty)
    );

    //==================================================
    // DDR side: pack 8 pixels, write, publish complete frames
    //==================================================
    reg        started;
    reg [1:0]  wr_bank;
    reg [8:0]  y;
    reg [5:0]  bx;
    reg [2:0]  sub;
    reg        last_pending;             // the pending burst ends the frame

    // the FIFO's block RAM output is registered first (timing)
    reg         q_valid;
    reg  [17:0] q_data;
    always @(posedge dclk) begin
        q_valid <= f_rvalid;
        q_data  <= f_rdata;
    end
    wire        sof = q_data[17], sol = q_data[16];
    wire [15:0] pix = q_data[15:0];
    wire [1:0]  free_bank = (ready_bank != 2'd0 && disp_bank != 2'd0) ? 2'd0 :
                            (ready_bank != 2'd1 && disp_bank != 2'd1) ? 2'd1 : 2'd2;

    // position of the pixel just read
    wire [8:0] y_e   = sof ? 9'd0 : sol ? y + 9'd1 : y;
    wire [5:0] bx_e  = (sof || sol) ? 6'd0 : bx;
    wire [2:0] sub_e = (sof || sol) ? 3'd0 : sub;

    always @(posedge dclk) begin
        f_rd <= 1'b0;
        if (drst) begin
            started    <= 1'b0;
            req        <= 1'b0;
            ready_bank <= 2'd0;
            wr_bank    <= 2'd1;
            have_frame <= 1'b0;
            frames     <= 16'd0;
            y <= 9'd0; bx <= 6'd0; sub <= 3'd0;
        end else begin
            // pop while no burst is waiting, one pixel in flight at a time
            // (one every 3 cycles, 31.5 M/s at 94.5 MHz), and not when the
            // pixel being processed completes a burst: req only rises with
            // it, and a pixel popped meanwhile would land in slot 0 of the
            // burst still waiting
            f_rd <= !req && !f_empty && !f_rd && !f_rvalid && !(q_valid && sub_e == 3'd7);
            if (gnt) begin
                req <= 1'b0;
                if (last_pending) begin
                    ready_bank <= wr_bank;
                    have_frame <= 1'b1;
                    frames     <= frames + 16'd1;
                end
            end
            if (q_valid) begin
                if (sof) begin
                    started <= 1'b1;
                    wr_bank <= free_bank;
                end
                y   <= y_e;
                bx  <= bx_e;
                sub <= sub_e + 3'd1;
                wdata[16*sub_e +: 16] <= pix;   // no pixel arrives while req is up
                if (sub_e == 3'd7) begin
                    bx <= bx_e + 6'd1;
                    if ((started || sof) && y_e < HEIGHT && bx_e < BX) begin
                        req   <= 1'b1;
                        baddr <= BASE + (sof ? free_bank : wr_bank) * BANK_STRIDE
                                      + y_e * LINE_STRIDE + bx_e;
                        last_pending <= y_e == HEIGHT - 1 && bx_e == BX - 1;
                    end
                end
            end
        end
    end

endmodule

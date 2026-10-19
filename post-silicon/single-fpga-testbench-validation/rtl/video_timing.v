// CEA-861 video timing generator. Defaults are 1280x720 @ 60 Hz (74.25 MHz):
//   H: 1280 active, 110 front porch, 40 sync, 220 back porch = 1650 total
//   V:  720 active,   5 front porch,  5 sync,  20 back porch =  750 total
// Sync polarity is positive. x/y count from the top-left active pixel; de is
// high during the active area; frame_start pulses at x = 0, y = 0.
module video_timing #(
    parameter H_ACTIVE = 1280,
    parameter H_FP     = 110,
    parameter H_SYNC   = 40,
    parameter H_BP     = 220,
    parameter V_ACTIVE = 720,
    parameter V_FP     = 5,
    parameter V_SYNC   = 5,
    parameter V_BP     = 20
) (
    input  wire        clk,
    input  wire        rst,
    output reg  [11:0] x,
    output reg  [11:0] y,
    output reg         de,
    output reg         hs,
    output reg         vs,
    output reg         frame_start
);

    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    reg [11:0] hc, vc;

    always @(posedge clk) begin
        if (rst) begin
            hc <= 12'd0;
            vc <= 12'd0;
        end else if (hc == H_TOTAL - 1) begin
            hc <= 12'd0;
            vc <= (vc == V_TOTAL - 1) ? 12'd0 : vc + 12'd1;
        end else begin
            hc <= hc + 12'd1;
        end
    end

    always @(posedge clk) begin
        x           <= hc;
        y           <= vc;
        de          <= (hc < H_ACTIVE) && (vc < V_ACTIVE);
        hs          <= (hc >= H_ACTIVE + H_FP) && (hc < H_ACTIVE + H_FP + H_SYNC);
        vs          <= (vc >= V_ACTIVE + V_FP) && (vc < V_ACTIVE + V_FP + V_SYNC);
        frame_start <= (hc == 0) && (vc == 0);
    end

endmodule

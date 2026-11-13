// DVP RGB565 byte pairs -> pixels, on the camera's PCLK. The OV3660 in
// format 0x61 sends {R[4:0], G[5:3]} then {G[2:0], B[4:0]} while HREF is high.
//
// ce marks the cycle in which a pixel completes and keeps toggling every
// other cycle in the blanking too (video_downscale with PIX_CE needs that to
// see line ends); the phase restarts with each line, so the first byte after
// HREF rises is always a high byte.
//
// Frames: a gap of more than FRAME_GAP cycles between lines is the vertical
// blank, so sof marks the first pixel after one (sync polarities don't
// matter, as in video_downscale). sol marks the first pixel of every line.
module pix565 #(
    parameter FRAME_GAP = 8000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  d,               // registered DVP data
    input  wire        de,              // registered HREF (after any inversion)

    output reg         ce,              // pixel slot (every other cycle)
    output reg         px_de,           // the slot carries a pixel (HREF was high)
    output reg         px_sol,          // first pixel of a line
    output reg         px_sof,          // first pixel of a frame
    output reg  [15:0] px,              // RGB565
    output wire [23:0] rgb_rbg          // {R, B, G}, 8 bits each (video_downscale order)
);

    reg        phase, de_q, line_first;
    reg [7:0]  hi;
    reg [13:0] gap;
    reg        frame_next;

    always @(posedge clk) begin
        ce     <= 1'b0;
        px_sol <= 1'b0;
        px_sof <= 1'b0;
        if (rst) begin
            phase <= 1'b0;
            de_q  <= 1'b0;
            gap   <= 14'd0;
            frame_next <= 1'b0;
            line_first <= 1'b0;
            px_de <= 1'b0;
        end else begin
            de_q <= de;
            if (de && !de_q) begin
                // first (high) byte of a line
                hi    <= d;
                phase <= 1'b1;
                line_first <= 1'b1;
                if (gap > FRAME_GAP) frame_next <= 1'b1;
            end else begin
                phase <= !phase;
                if (phase) begin
                    ce    <= 1'b1;
                    px_de <= de;
                    if (de) begin
                        px         <= {hi, d};
                        px_sol     <= line_first;
                        px_sof     <= line_first && frame_next;
                        line_first <= 1'b0;
                        frame_next <= 1'b0;
                    end
                end else
                    hi <= d;
            end
            if (de) gap <= 14'd0;
            else if (gap != 14'h3FFF) gap <= gap + 14'd1;
        end
    end

    // 5/6 bits -> 8 bits by replicating the top bits
    wire [4:0] r5 = px[15:11];
    wire [5:0] g6 = px[10:5];
    wire [4:0] b5 = px[4:0];
    assign rgb_rbg = {r5, r5[4:2], b5, b5[4:2], g6, g6[5:4]};

endmodule

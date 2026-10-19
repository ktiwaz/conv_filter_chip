// One line of overlay text at a fixed position, using the 5x7 font scaled
// 3x (6x8 character cells -> 18x24 pixels).
//
// Three pipeline stages from (x, y) to on: cell position (c1), character and
// glyph coordinates (c2), font bit (c3). Divisions by the cell size use
// reciprocal multiplies that are exact over the ranges used here:
//   dx / 18 = (dx * 3641) >> 16        for dx < 32768
//   n / 3   = (n * 11) >> 5            for n < 24
module text_line #(
    parameter X0  = 0,
    parameter Y0  = 0,
    parameter LEN = 16                  // characters
) (
    input  wire              pclk,
    input  wire [11:0]       x,
    input  wire [11:0]       y,
    input  wire [LEN*8-1:0]  text,      // ASCII, first character in the top byte
    output reg               on
);

    localparam CW = 18;                 // cell width in pixels
    localparam CH = 24;                 // cell height in pixels

    // c0 -> c1: which character cell
    wire        in_box = (x >= X0) && (x < X0 + LEN * CW) && (y >= Y0) && (y < Y0 + CH);
    wire [11:0] dx     = x - X0;
    wire [11:0] dy     = y - Y0;
    wire [27:0] q      = dx * 28'd3641;
    wire [11:0] chr    = q[27:16];

    reg        c1_in;
    reg [11:0] c1_chr;
    reg [4:0]  c1_sub;                  // pixel within the cell, 0..17
    reg [4:0]  c1_dy;                   // pixel row, 0..23

    always @(posedge pclk) begin
        c1_in  <= in_box;
        c1_chr <= chr;
        c1_sub <= dx - chr * CW;
        c1_dy  <= dy[4:0];
    end

    // c1 -> c2: character code and glyph column/row
    wire [9:0] col11 = c1_sub * 10'd11;
    wire [9:0] row11 = c1_dy  * 10'd11;

    reg       c2_in;
    reg [7:0] c2_ch;
    reg [2:0] c2_col;                   // 0..5 (5 = spacing column)
    reg [2:0] c2_row;                   // 0..7 (7 = spacing row)

    always @(posedge pclk) begin
        c2_in  <= c1_in;
        c2_ch  <= (c1_chr < LEN) ? text[(LEN - 1 - c1_chr) * 8 +: 8] : 8'h20;
        c2_col <= col11[7:5];
        c2_row <= row11[7:5];
    end

    // c2 -> c3: font bit
    wire [4:0] bits;
    font_rom font (.ch(c2_ch), .row(c2_row), .bits(bits));

    always @(posedge pclk)
        on <= c2_in && (c2_col < 3'd5) && bits[3'd4 - c2_col];

endmodule

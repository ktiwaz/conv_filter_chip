// DVI 1.0 TMDS encoder: 8b data -> 10b DC-balanced symbol, or a control
// symbol during blanking. Two pipeline registers (2 cycles of latency for
// data and control symbols alike, so the three channels stay aligned):
//   stage 1: transition minimization (XOR / XNOR chain) and its ones count
//   stage 2: DC balance against the running disparity
// Doing both in one cycle missed 74.25 MHz (720p) on GW2A by ~1 %.
// Checked against a reference decoder (tp20k/sim/tb_tmds.sv: random pixels,
// zero errors, running disparity bounded).
module tmds_encoder (
    input  wire       clk,
    input  wire       rst,
    input  wire       de,
    input  wire [7:0] data,
    input  wire [1:0] c,
    output reg  [9:0] sym
);

    function [3:0] ones8;
        input [7:0] v;
        integer k;
        begin
            ones8 = 4'd0;
            for (k = 0; k < 8; k = k + 1) ones8 = ones8 + v[k];
        end
    endfunction

    //==================================================
    // Stage 1: transition minimization
    //==================================================
    wire [3:0] n1d    = ones8(data);
    wire       use_xn = (n1d > 4'd4) || (n1d == 4'd4 && !data[0]);
    reg  [8:0] qm_c;
    integer j;
    always @(*) begin
        qm_c[0] = data[0];
        for (j = 1; j < 8; j = j + 1)
            qm_c[j] = use_xn ? !(qm_c[j-1] ^ data[j]) : (qm_c[j-1] ^ data[j]);
        qm_c[8] = !use_xn;
    end

    reg  [8:0]        qm;
    reg  signed [4:0] diff;         // (ones - zeros) / 2 of qm[7:0]
    reg               de1;
    reg  [1:0]        c1;
    always @(posedge clk) begin
        qm   <= qm_c;
        diff <= $signed({1'b0, ones8(qm_c[7:0])}) - 5'sd4;
        de1  <= de && !rst;
        c1   <= c;
    end

    //==================================================
    // Stage 2: DC balance against the running disparity
    //==================================================
    reg signed [4:0] cnt;           // in half units: (ones - zeros) / 2

    always @(posedge clk) begin
        if (rst) begin
            cnt <= 5'sd0;
            sym <= 10'b1101010100;
        end else if (!de1) begin
            cnt <= 5'sd0;
            case (c1)
                2'b00:   sym <= 10'b1101010100;
                2'b01:   sym <= 10'b0010101011;
                2'b10:   sym <= 10'b0101010100;
                default: sym <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || diff == 0) begin
            sym <= {!qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
            sym <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + {4'd0, qm[8]} - diff;       // spec: + 2*qm[8] (cnt is in half units)
        end else begin
            sym <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - {4'd0, !qm[8]} + diff;      // spec: - 2*~qm[8]
        end
    end

endmodule

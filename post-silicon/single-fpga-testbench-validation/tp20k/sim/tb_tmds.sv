// tmds_encoder against a reference TMDS decoder: random pixels with a
// blanking interval every line (control symbols on c), including runs of
// 0x00 / 0xFF that stress the DC balance. Checks every data symbol decodes
// back to its pixel, every blanking symbol is the right control code, and
// the running disparity over each active line stays bounded.
`timescale 1ns/1ps

module tb_tmds;

    localparam LATENCY = 2;         // tmds_encoder pipeline depth
    localparam N = 200000;

    reg        clk = 0, rst = 1, de = 0;
    reg  [7:0] data = 0;
    reg  [1:0] c = 0;
    wire [9:0] sym;

    tmds_encoder dut (.clk(clk), .rst(rst), .de(de), .data(data), .c(c), .sym(sym));
    always #5 clk = ~clk;

    function automatic [7:0] decode(input [9:0] s);
        reg [7:0] d;
        begin
            d = s[9] ? ~s[7:0] : s[7:0];
            decode[0] = d[0];
            for (int k = 1; k < 8; k++)
                decode[k] = s[8] ? (d[k] ^ d[k-1]) : ~(d[k] ^ d[k-1]);
        end
    endfunction

    function automatic [9:0] ctrl(input [1:0] cc);
        case (cc)
            2'b00:   ctrl = 10'b1101010100;
            2'b01:   ctrl = 10'b0010101011;
            2'b10:   ctrl = 10'b0101010100;
            default: ctrl = 10'b1010101011;
        endcase
    endfunction

    // Inputs of the last LATENCY cycles, oldest first
    reg       h_de   [0:LATENCY-1];
    reg [7:0] h_data [0:LATENCY-1];
    reg [1:0] h_c    [0:LATENCY-1];

    int errors = 0, checked = 0, disp = 0, max_disp = 0, ones;

    initial begin
        for (int k = 0; k < LATENCY; k++) begin h_de[k] = 0; h_data[k] = 0; h_c[k] = 0; end
        repeat (4) @(posedge clk);
        rst = 0;
        for (int i = 0; i < N; i++) begin
            @(negedge clk);
            // sym now reflects the inputs applied LATENCY cycles ago
            if (i >= LATENCY) begin
                if (h_de[0]) begin
                    ones = $countones(sym);
                    if (decode(sym) !== h_data[0]) begin
                        if (errors < 5) $display("  FAIL %0d: sent %02h decoded %02h", i, h_data[0], decode(sym));
                        errors++;
                    end
                    disp += ones - (10 - ones);
                    if (disp > max_disp) max_disp = disp;
                    if (-disp > max_disp) max_disp = -disp;
                end else begin
                    if (sym !== ctrl(h_c[0])) begin
                        if (errors < 5) $display("  FAIL %0d: control %b expected %b", i, sym, ctrl(h_c[0]));
                        errors++;
                    end
                    disp = 0;
                end
                checked++;
            end
            // next inputs: 640 active pixels, then 160 blanking cycles
            de   = (i % 800) < 640;
            data = ((i / 37) % 9 == 0) ? 8'hFF : ((i / 53) % 11 == 0) ? 8'h00 : $urandom;
            c    = $urandom;
            for (int k = 0; k < LATENCY - 1; k++) begin
                h_de[k] = h_de[k+1]; h_data[k] = h_data[k+1]; h_c[k] = h_c[k+1];
            end
            h_de[LATENCY-1] = de; h_data[LATENCY-1] = data; h_c[LATENCY-1] = c;
        end
        $display("checked %0d symbols, %0d errors, max |running disparity| %0d bits", checked, errors, max_disp);
        if (errors == 0 && max_disp <= 20) $display("PASS");
        else                              $display("FAIL");
        $finish;
    end

endmodule

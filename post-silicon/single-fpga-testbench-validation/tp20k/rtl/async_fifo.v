// Dual-clock FIFO: block RAM, Gray-coded pointers through two flip-flops.
// Write: wr when !full. Read: rd when !empty pops the head; its data is on
// rdata in the next cycle (rvalid). Resets are per side; reset both together.
module async_fifo #(
    parameter DW = 18,
    parameter AW = 10                    // 2^AW entries
) (
    input  wire          wclk,
    input  wire          wrst,
    input  wire          wr,
    input  wire [DW-1:0] wdata,
    output wire          full,

    input  wire          rclk,
    input  wire          rrst,
    input  wire          rd,
    output reg  [DW-1:0] rdata,
    output reg           rvalid,
    output wire          empty
);

    (* ram_style = "block" *)
    reg [DW-1:0] mem [0:(1<<AW)-1];

    reg  [AW:0] wbin = 0, wgray = 0, rbin = 0, rgray = 0;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_w1 = 0, rgray_w2 = 0;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_r1 = 0, wgray_r2 = 0;

    wire [AW:0] wbin_n  = wbin + 1'b1;
    wire [AW:0] rbin_n  = rbin + 1'b1;

    // full: the write pointer is one lap ahead of the read pointer
    assign full  = wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]};
    assign empty = rgray == wgray_r2;

    always @(posedge wclk) begin
        rgray_w1 <= rgray;
        rgray_w2 <= rgray_w1;
        if (wrst) begin
            wbin  <= 0;
            wgray <= 0;
        end else if (wr && !full) begin
            mem[wbin[AW-1:0]] <= wdata;
            wbin  <= wbin_n;
            wgray <= wbin_n ^ (wbin_n >> 1);
        end
    end

    always @(posedge rclk) begin
        wgray_r1 <= wgray;
        wgray_r2 <= wgray_r1;
        rvalid <= 1'b0;
        if (rrst) begin
            rbin  <= 0;
            rgray <= 0;
        end else if (rd && !empty) begin
            rdata  <= mem[rbin[AW-1:0]];
            rvalid <= 1'b1;
            rbin   <= rbin_n;
            rgray  <= rbin_n ^ (rbin_n >> 1);
        end
    end

endmodule

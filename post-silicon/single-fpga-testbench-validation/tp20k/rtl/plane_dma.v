// One channel of a grabbed frame (rgb_grab's layout in DDR3) into the DUT's
// input RAM: 4096 burst reads, byte `ch` of each of the 4 pixels of a burst
// packed into one 32-bit word (pixel 4k + j in byte j, as the input RAM and
// the sequencer expect), at word k.
//
// Request (fabric clock): set bank and ch, flip req_t; done_t flips when the
// whole plane is in the RAM. The RAM's read port (fabric clock, 1-cycle
// latency) is the sequencer's live read port (fpga_tb_core ext_rd_*).
module plane_dma #(
    parameter BA_W = 23,
    parameter [BA_W-1:0] BASE        = 23'h020000,
    parameter [BA_W-1:0] BANK_STRIDE = 23'h001000
) (
    // fabric clock side
    input  wire            clk,
    input  wire            bank,
    input  wire [1:0]      ch,                // 0 R, 1 G, 2 B, 3 Y
    input  wire            req_t,             // flip to request (bank, ch stable)
    output wire            done_t,            // flips when done
    input  wire            rd_en,
    input  wire [11:0]     rd_addr,
    output reg  [31:0]     rd_data,

    // DDR side
    input  wire            dclk,
    input  wire            drst,
    output reg             req,
    output reg  [BA_W-1:0] baddr,
    input  wire            gnt,
    input  wire            rvalid,
    input  wire [127:0]    rdata
);

    //==================================================
    // Plane RAM: 4096 x 32, written on the DDR clock, read on the fabric clock
    //==================================================
    (* ram_style = "block" *)
    reg [31:0] mem [0:4095];
    reg        m_we;
    reg [11:0] m_wa;
    reg [31:0] m_wd;
    always @(posedge dclk)
        if (m_we) mem[m_wa] <= m_wd;
    always @(posedge clk)
        if (rd_en) rd_data <= mem[rd_addr];

    //==================================================
    // DDR side
    //==================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] req_s = 3'b000;
    reg        ack = 1'b0;
    assign done_t = ack;
    wire       start = req_s[2] != req_s[1];

    reg        busy;
    reg [12:0] sent, got;                // bursts requested / received
    reg        d_bank;
    reg [1:0]  d_ch;

    function [31:0] pick(input [127:0] b, input [1:0] c);
        integer j;
        begin
            for (j = 0; j < 4; j = j + 1)
                pick[8 * j +: 8] = b[32 * j + 8 * c +: 8];
        end
    endfunction

    always @(posedge dclk) begin
        req_s <= {req_s[1:0], req_t};
        m_we  <= 1'b0;
        if (drst) begin
            busy <= 1'b0;
            req  <= 1'b0;
        end else begin
            if (start && !busy) begin
                busy   <= 1'b1;
                d_bank <= bank;              // stable since the toggle
                d_ch   <= ch;
                sent   <= 13'd0;
                got    <= 13'd0;
            end
            if (gnt) begin
                req  <= 1'b0;
                sent <= sent + 13'd1;
            end
            // keep one read queued behind the one in the controller
            if (busy && !req && !gnt && sent < 13'd4096 && sent - got < 13'd2) begin
                req   <= 1'b1;
                baddr <= BASE + (d_bank ? BANK_STRIDE : {BA_W{1'b0}}) + sent[11:0];
            end
            if (rvalid && busy) begin
                m_we <= 1'b1;
                m_wa <= got[11:0];
                m_wd <= pick(rdata, d_ch);
                got  <= got + 13'd1;
                if (got == 13'd4095) begin
                    busy <= 1'b0;
                    ack  <= !ack;
                end
            end
        end
    end

endmodule

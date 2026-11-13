// Colour display buffer for the DUT output: one 128x128 frame of R, G and B,
// 5 bits each (the top bits of the DUT's 8-bit output), written by the runs
// (fabric clock) and read for HDMI (pixel clock). A colour frame takes three
// runs, one per channel (ch_we = 001, 010, 100); a gray run writes all three
// (ch_we = 111). Single-buffered like video_frame with BANKS = 1: a run that
// overlaps the scan-out may show for part of a frame.
//
// Each bit plane is its own 16K x 1 memory, so every channel takes exactly
// five block RAMs (15 in all).
//
// The run's valid output range and mask (as in video_frame) are taken by the
// pixel clock side at the next frame start after a run completed.
module color_frame (
    // fabric clock side
    input  wire        clk,
    input  wire        aresetn,
    input  wire [2:0]  ch_we,           // channels the current run writes
    input  wire        run_done,        // pulse: a run completed
    input  wire [14:0] run_lo,          // output pixels written by the run: [run_lo, run_hi)
    input  wire [14:0] run_hi,
    input  wire        run_masked,
    input  wire        out_we,
    input  wire [13:0] out_addr,
    input  wire [7:0]  out_data,

    // pixel clock side (reads: 1-cycle latency)
    input  wire        pclk,
    input  wire        prst,
    input  wire        frame_start,
    input  wire [13:0] rd_addr,
    output wire [4:0]  rd_r,
    output wire [4:0]  rd_g,
    output wire [4:0]  rd_b,
    output reg         has_frame,
    output reg  [14:0] disp_lo,
    output reg  [14:0] disp_hi,
    output reg         disp_masked
);

    //==================================================
    // Run metadata into the pixel clock domain
    //==================================================
    reg [14:0] ready_lo, ready_hi;
    reg        ready_masked, ready_toggle, publish;
    always @(posedge clk) begin
        if (!aresetn) begin
            ready_toggle <= 1'b0;
            publish      <= 1'b0;
        end else begin
            publish <= 1'b0;
            if (run_done) begin
                ready_lo     <= run_lo;
                ready_hi     <= run_hi;
                ready_masked <= run_masked;
                publish      <= 1'b1;
            end
            if (publish) ready_toggle <= ~ready_toggle;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [2:0] toggle_s;
    reg        seen_toggle;
    reg [14:0] ready_lo_p, ready_hi_p;
    reg        ready_masked_p;
    always @(posedge pclk) begin
        if (prst) begin
            toggle_s    <= 3'd0;
            seen_toggle <= 1'b0;
            has_frame   <= 1'b0;
            disp_lo     <= 15'd0;
            disp_hi     <= 15'd0;
            disp_masked <= 1'b0;
        end else begin
            toggle_s <= {toggle_s[1:0], ready_toggle};
            if (toggle_s[2] != seen_toggle) begin
                seen_toggle    <= toggle_s[2];
                ready_lo_p     <= ready_lo;
                ready_hi_p     <= ready_hi;
                ready_masked_p <= ready_masked;
                has_frame      <= 1'b1;
            end
            if (frame_start) begin
                disp_lo     <= ready_lo_p;
                disp_hi     <= ready_hi_p;
                disp_masked <= ready_masked_p;
            end
        end
    end

    //==================================================
    // 15 bit planes: channel c, bit b = out_data[3 + b]
    //==================================================
    wire [14:0] rd_bits;
    genvar c, b;
    generate
        for (c = 0; c < 3; c = c + 1) begin : g_ch
            for (b = 0; b < 5; b = b + 1) begin : g_bit
                bit_plane plane (
                    .clk_a(clk), .we(out_we && ch_we[c]), .waddr(out_addr), .din(out_data[3 + b]),
                    .clk_b(pclk), .raddr(rd_addr), .dout(rd_bits[5 * c + b])
                );
            end
        end
    endgenerate
    assign rd_r = rd_bits[4:0];
    assign rd_g = rd_bits[9:5];
    assign rd_b = rd_bits[14:10];

endmodule

// 16384 x 1 simple dual-port, dual-clock block RAM
module bit_plane (
    input  wire        clk_a,
    input  wire        we,
    input  wire [13:0] waddr,
    input  wire        din,
    input  wire        clk_b,
    input  wire [13:0] raddr,
    output reg         dout
);

    (* ram_style = "block" *)
    reg mem [0:16383];

    integer k;
    initial for (k = 0; k < 16384; k = k + 1) mem[k] = 1'b0;

    always @(posedge clk_a)
        if (we) mem[waddr] <= din;

    always @(posedge clk_b)
        dout <= mem[raddr];

endmodule

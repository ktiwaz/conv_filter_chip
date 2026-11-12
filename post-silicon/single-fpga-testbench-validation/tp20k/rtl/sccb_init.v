// Camera power-up and SCCB register initialization from a ROM
// (cam_init_rom, generated from cam/*.txt by scripts/gen_cam_rom.py), so the
// camera pipeline runs without a PC.
//
// Sequence after reset:
//   PWDN high, RESET low for PWR_MS1; PWDN low for PWR_MS2; RESET released,
//   then PWR_MS3 before the first SCCB access (the OV3660 needs >= 20 ms);
//   then every ROM entry in order: a register write (start, 0x78, address
//   high, address low, data, stop) or a delay in milliseconds; then done.
//
// SCCB runs at about SCCB_HZ in four quarter-period phases per bit. SCL and
// SDA are open drain: *_low = 1 pulls the line low, 0 releases it. ACK bits
// are sampled and NACKs counted (nacks saturates) but not retried: a
// missing camera shows up as nacks != 0 rather than a hang.
module sccb_init #(
    parameter CLK_HZ   = 46_406_250,
    parameter SCCB_HZ  = 100_000,
    parameter MS_DIV   = CLK_HZ / 1000,     // clocks per millisecond (tests shrink it)
    parameter PWR_MS1  = 10,
    parameter PWR_MS2  = 5,
    parameter PWR_MS3  = 30
) (
    input  wire       clk,
    input  wire       rst,               // synchronous, active high: restart the sequence
    output reg        pwdn,
    output reg        rst_n,
    output wire       scl_low,
    output wire       sda_low,
    input  wire       sda_in,            // synchronized SDA, for ACK sampling
    output reg        done,
    output reg  [7:0] nacks
);

    localparam [7:0] DEV_W = 8'h78;      // OV3660 / OV5640 SCCB write address

    //==================================================
    // Timebases: quarter SCCB bit periods and milliseconds
    //==================================================
    localparam integer QDIV = (CLK_HZ / (4 * SCCB_HZ)) > 0 ? CLK_HZ / (4 * SCCB_HZ) : 1;
    reg [15:0] qcnt;
    wire       qtick = (qcnt == QDIV - 1);
    always @(posedge clk)
        qcnt <= (rst || qtick) ? 16'd0 : qcnt + 16'd1;

    reg [23:0] mcnt;                     // clocks within the current millisecond
    reg [23:0] ms_left;                  // milliseconds still to wait
    wire       mtick = (mcnt == MS_DIV - 1);

    //==================================================
    // ROM
    //==================================================
    reg  [9:0]  idx;
    wire [31:0] entry;
    cam_init_rom rom (.clk(clk), .addr(idx), .data(entry));

    //==================================================
    // Sequencer
    //==================================================
    localparam [3:0] S_PWR1  = 4'd0,
                     S_PWR2  = 4'd1,
                     S_PWR3  = 4'd2,
                     S_FETCH = 4'd3,     // ROM address presented
                     S_DEC   = 4'd4,     // ROM data valid
                     S_WAIT  = 4'd5,     // delay entry
                     S_START = 4'd6,
                     S_BIT   = 4'd7,
                     S_STOP  = 4'd8,
                     S_DONE  = 4'd9;

    reg [3:0]  state;
    reg [1:0]  q;                        // quarter within a bit / start / stop
    reg [31:0] cur;                      // current ROM entry
    reg [1:0]  byte_i;                   // 0: device, 1: addr high, 2: addr low, 3: data
    reg [3:0]  bit_i;                    // 0..7 data (MSB first), 8: ACK
    reg        scl_r, sda_r;             // 1 = released

    assign scl_low = !scl_r;
    assign sda_low = !sda_r;

    wire [7:0] cur_byte = (byte_i == 2'd0) ? DEV_W :
                          (byte_i == 2'd1) ? cur[23:16] :
                          (byte_i == 2'd2) ? cur[15:8]  : cur[7:0];

    // Start a millisecond wait of n ms in the next state
    task wait_ms;
        input [23:0] n;
        begin
            ms_left <= n;
            mcnt    <= 24'd0;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state  <= S_PWR1;
            pwdn   <= 1'b1;
            rst_n  <= 1'b0;
            scl_r  <= 1'b1;
            sda_r  <= 1'b1;
            done   <= 1'b0;
            nacks  <= 8'd0;
            idx    <= 10'd0;
            q      <= 2'd0;
            byte_i <= 2'd0;
            bit_i  <= 4'd0;
            cur    <= 32'd0;
            wait_ms(PWR_MS1);
        end else begin
            // millisecond countdown, used by the power and delay states
            if (ms_left != 24'd0) begin
                if (mtick) begin
                    mcnt    <= 24'd0;
                    ms_left <= ms_left - 24'd1;
                end else begin
                    mcnt <= mcnt + 24'd1;
                end
            end

            case (state)
                S_PWR1: if (ms_left == 24'd0) begin
                    pwdn  <= 1'b0;
                    state <= S_PWR2;
                    wait_ms(PWR_MS2);
                end
                S_PWR2: if (ms_left == 24'd0) begin
                    rst_n <= 1'b1;
                    state <= S_PWR3;
                    wait_ms(PWR_MS3);
                end
                S_PWR3: if (ms_left == 24'd0)
                    state <= S_FETCH;

                S_FETCH: state <= S_DEC;            // ROM read latency

                S_DEC: begin
                    cur <= entry;
                    case (entry[31:30])
                        2'b00: begin                // register write
                            byte_i <= 2'd0;
                            bit_i  <= 4'd0;
                            q      <= 2'd0;
                            state  <= S_START;
                        end
                        2'b01: begin                // delay
                            state <= S_WAIT;
                            wait_ms(entry[23:0]);
                        end
                        default: state <= S_DONE;   // end
                    endcase
                end

                S_WAIT: if (ms_left == 24'd0) begin
                    idx   <= idx + 10'd1;
                    state <= S_FETCH;
                end

                // Start: SDA falls while SCL is high, then SCL low
                S_START: if (qtick) begin
                    q <= q + 2'd1;
                    case (q)
                        2'd0: begin scl_r <= 1'b1; sda_r <= 1'b1; end
                        2'd1: sda_r <= 1'b0;
                        2'd2: scl_r <= 1'b0;
                        2'd3: state <= S_BIT;
                    endcase
                end

                // Each bit: set SDA with SCL low, SCL high, sample, SCL low
                S_BIT: if (qtick) begin
                    q <= q + 2'd1;
                    case (q)
                        2'd0: sda_r <= (bit_i == 4'd8) ? 1'b1 : cur_byte[3'd7 - bit_i[2:0]];
                        2'd1: scl_r <= 1'b1;
                        2'd2: if (bit_i == 4'd8 && sda_in && nacks != 8'hFF)
                                  nacks <= nacks + 8'd1;
                        2'd3: begin
                            scl_r <= 1'b0;
                            if (bit_i == 4'd8) begin
                                bit_i <= 4'd0;
                                if (byte_i == 2'd3) state <= S_STOP;
                                byte_i <= byte_i + 2'd1;
                            end else begin
                                bit_i <= bit_i + 4'd1;
                            end
                        end
                    endcase
                end

                // Stop: SDA low, SCL high, then SDA rises
                S_STOP: if (qtick) begin
                    q <= q + 2'd1;
                    case (q)
                        2'd0: sda_r <= 1'b0;
                        2'd1: scl_r <= 1'b1;
                        2'd2: sda_r <= 1'b1;
                        2'd3: begin
                            idx   <= idx + 10'd1;
                            state <= S_FETCH;
                        end
                    endcase
                end

                S_DONE: done <= 1'b1;

                default: state <= S_DONE;
            endcase
        end
    end

endmodule

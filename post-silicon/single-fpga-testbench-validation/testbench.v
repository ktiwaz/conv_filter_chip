module testbench (
    input  wire refclk_125,
    input  wire [1:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led
);

    wire clk;
    wire rst;
    assign rst = sw[0];

    clk_wiz_0 instance_name
    (
        // Clock out ports
        .clk_out1(clk),     // output clk_out1
        // Status and control signals
        .reset(rst), // input reset
        .locked(led[0]),       // output locked
        // Clock in ports
        .clk_in1(refclk_125)      // input clk_in1
    );

    reg [25:0] counter = 0;
    reg led_reg;
    assign led[1] = led_reg;

    // Flash LED to show that clock is running
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            led_reg <= 0;
            counter <= 0;
        end 
        else if (counter == 49_999_999) begin
            counter <= 0;
            led_reg <= ~led_reg;
        end
        else begin
            counter <= counter + 1'b1;
        end
    end

    // RAM Initialization test

    wire start;
    assign start = sw[1];
    reg [13:0] addr, addr_d;

    localparam IDLE   = 1'd0,
               STREAM = 1'd1;
    reg state, state_d;

    always @(*) begin
        addr_d = addr;
        state_d = state;

        case(state)
            IDLE: begin
                if(start) begin
                    state_d = STREAM;
                end
            end
            STREAM: begin
                if(addr == 14'd16383) begin
                    state_d = IDLE;
                    addr_d = 14'd0;
                end else begin
                    addr_d = addr + 14'd1;
                end
            end
            default: begin
                state_d = IDLE;
                addr_d  = 14'd0;
            end
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            addr <= 0;
            state <= IDLE;
        end 
        else begin
            state <= state_d;
            addr  <= addr_d;
        end
    end

    reg [7:0] rom [0:16383];
    reg [7:0] dout;

    initial begin
        $readmemh("input_image.hex", rom);
    end

    always @(posedge clk) begin
        dout <= rom[addr];
    end


ila_0 your_instance_name (
	.clk(clk), // input wire clk


	.probe0(dout), // input wire [7:0]  probe0  
	.probe1(start), // input wire [0:0]  probe1 
	.probe2(state), // input wire [0:0]  probe2 
	.probe3(addr) // input wire [13:0]  probe3
);


endmodule 

// This is just a sanity check (non-exhaustive).
// I stream values in sequentially (1, 2, 3, etc), checking for the correct pattern on the output. 
// This module will be testbenched more extensively when integrated into the entire filter core. 

module tb_window_dot_product;

// Parameters
localparam int NUMBER_OF_LINES = 3;
localparam int LINE_WIDTH = 128;
localparam int DATA_DEPTH = 8;
localparam int ACC_WIDTH = DATA_DEPTH + DATA_DEPTH + $clog2(NUMBER_OF_LINES * NUMBER_OF_LINES) + 1;

//Ports
reg clk = 1'b0;
reg rst_n = 1'b1;
reg input_valid = 1'b0;
reg [DATA_DEPTH-1:0] datain = '0;
wire [DATA_DEPTH-1:0] window [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1];
wire window_output_valid;
wire dot_product_output_valid;

wire signed [ACC_WIDTH-1:0] dot_product;

reg signed [DATA_DEPTH-1:0] kernel [0:NUMBER_OF_LINES-1][0:NUMBER_OF_LINES-1];

initial begin
    kernel[0][0] = 1; kernel[0][1] = 0; kernel[0][2] = 1;
    kernel[1][0] = 0; kernel[1][1] = 1; kernel[1][2] = 0;
    kernel[2][0] = 1; kernel[2][1] = 0; kernel[2][2] = 1;
end

sliding_window # (
  .NUMBER_OF_LINES(NUMBER_OF_LINES),
  .LINE_WIDTH(LINE_WIDTH),
  .DATA_DEPTH(DATA_DEPTH)
)
sliding_window_inst (
  .clk(clk),
  .rst_n(rst_n),
  .input_valid(input_valid),
  .datain(datain),
  .dataout(window),
  .output_valid(window_output_valid)
);

window_dot_product # (
    .NUMBER_OF_LINES(NUMBER_OF_LINES),
    .DATA_WIDTH(DATA_DEPTH),
    .KERNEL_WIDTH(DATA_DEPTH)
  )
  dut (
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(window_output_valid),
    .window(window),
    .kernel(kernel),
    .output_valid(dot_product_output_valid),
    .dot_product(dot_product)
  );

// Clock driver
always #5  clk = ! clk ;

// Test Pattern Generator
integer i;
initial begin
    
    #57;

    // Reset generator
    @(posedge clk) rst_n = 1'b0;
    #20;
    @(posedge clk) rst_n = 1'b1;

    #40;

    // Set enable
    @(posedge clk) input_valid = 1'b1;
    
    // Inject 3 times the buffer size worth of data. 
    for(i = 0; i < 3*NUMBER_OF_LINES*LINE_WIDTH; i = i + 1) begin

        datain = i % 256;
        @(posedge clk);
    end

    @(posedge clk) input_valid = 1'b0;

    $finish();

end

always @(posedge clk) begin
    if (window_output_valid) begin
        $display("window @ t=%0t", $time);
        $display("%0d %0d %0d",
            window[0][0],
            window[0][1],
            window[0][2]);
        $display("%0d %0d %0d",
            window[1][0],
            window[1][1],
            window[1][2]);
        $display("%0d %0d %0d",
            window[2][0],
            window[2][1],
            window[2][2]);
        $display("");
    end

    if(dot_product_output_valid) begin
        $display("dot product @ t=%0t", $time);
        $display("dot product: = %0d", dot_product);
    end
end

endmodule

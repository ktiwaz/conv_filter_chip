// Gowin timing constraints for tp20k_cam_top. The rPLL / CLKDIV outputs are
// derived by the tool from the 27 MHz input.
create_clock -name clk27     -period 37.037 [get_ports {clk27}]
create_clock -name cmos_pclk -period 41.667 [get_ports {cmos_pclk}]
set_clock_groups -asynchronous -group [get_clocks {cmos_pclk}]

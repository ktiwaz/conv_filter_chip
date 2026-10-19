# Generate all vendor IP for the non-project flow into ip/.
# Usage: vivado -mode batch -source tcl/gen_ip.tcl   (run from the testbench root)

set root [file normalize [file dirname [info script]]/..]
source $root/tcl/common.tcl

set ip_dir $root/ip
file mkdir $ip_dir
create_project -in_memory -part $part

proc make_ip {name vlnv cfg} {
    global ip_dir
    if {[file exists $ip_dir/$name]} { file delete -force $ip_dir/$name }
    create_ip -vlnv $vlnv -module_name $name -dir $ip_dir
    set_property -dict $cfg [get_ips $name]
    generate_target all [get_ips $name]
    synth_ip [get_ips $name]
}

# 125 MHz board clock -> 50 MHz fabric clock
make_ip clk_wiz_0 xilinx.com:ip:clk_wiz:6.0 {
    CONFIG.PRIM_IN_FREQ {125.000}
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000}
    CONFIG.USE_LOCKED {true}
    CONFIG.USE_RESET {true}
    CONFIG.RESET_TYPE {ACTIVE_HIGH}
}

# probe0: DUT dataout, probe1: DUT output_valid, probe2: pixel_valid, probe3: stream addr
make_ip ila_0 xilinx.com:ip:ila:6.2 {
    CONFIG.C_NUM_OF_PROBES {4}
    CONFIG.C_PROBE0_WIDTH {8}
    CONFIG.C_PROBE1_WIDTH {1}
    CONFIG.C_PROBE2_WIDTH {1}
    CONFIG.C_PROBE3_WIDTH {14}
    CONFIG.C_EN_STRG_QUAL {1}
    CONFIG.C_ADV_TRIGGER {true}
}

# JTAG -> AXI4 master, 32-bit data/address
make_ip jtag_axi_0 xilinx.com:ip:jtag_axi:1.2 {
    CONFIG.PROTOCOL {0}
    CONFIG.M_AXI_DATA_WIDTH {32}
    CONFIG.M_AXI_ADDR_WIDTH {32}
}

# DUT board: oversample all 25 link pins at 125 MHz
#   probe0 [13:0] = {datain, test_mode, pixel_valid, normalization_valid, kernel_valid, reset_n, clk}
#   probe1 [10:0] = {status, output_valid, dataout}
make_ip ila_dut xilinx.com:ip:ila:6.2 {
    CONFIG.C_NUM_OF_PROBES {2}
    CONFIG.C_PROBE0_WIDTH {14}
    CONFIG.C_PROBE1_WIDTH {11}
    CONFIG.C_DATA_DEPTH {4096}
    CONFIG.C_EN_STRG_QUAL {1}
    CONFIG.C_ADV_TRIGGER {true}
}

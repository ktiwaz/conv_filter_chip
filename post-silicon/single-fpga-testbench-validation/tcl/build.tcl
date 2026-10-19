# Non-project synthesis -> implementation -> bitstream.
# Usage: vivado -mode batch -source tcl/build.tcl -tclargs tester|dut
# (IP must be generated first: tcl/gen_ip.tcl)
#   tester: testbench.v -> build/tester/testbench.{bit,ltx}
#   dut:    dut_board.v -> build/dut/dut_board.{bit,ltx}

set root [file normalize [file dirname [info script]]/..]
source $root/tcl/common.tcl
source $root/tcl/link_pins.tcl

set role [build_role]
set top  $role_top($role)
set out  $root/build/$role
file mkdir $out/reports

set_part $part
read_verilog [list $root/$top.v {*}[lsort [glob $root/rtl/*.v]]]
read_verilog -sv [dut_sources $root]
# Board pins (clock, switches, LEDs) are the same on both boards
read_xdc $root/testbench.xdc
foreach ip $role_ips($role) {
    read_ip $root/ip/$ip/$ip.xci
}

if {$role eq "tester"} {
    # Absolute path so $readmemh doesn't depend on Vivado's working directory
    set init_file $root/input_image_w32.hex
    synth_design -top $top -part $part -generic "INIT_FILE=\"$init_file\""
} else {
    synth_design -top $top -part $part
}
link_constraints $role
write_checkpoint -force $out/post_synth.dcp
report_utilization -file $out/reports/utilization_synth.rpt

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $out/post_route.dcp

report_utilization     -file $out/reports/utilization.rpt
report_timing_summary  -file $out/reports/timing_summary.rpt
report_drc             -file $out/reports/drc.rpt
report_ram_utilization -file $out/reports/ram_utilization.rpt
report_io              -file $out/reports/io.rpt

write_bitstream    -force $out/$top.bit
write_debug_probes -force $out/$top.ltx

set iob_regs [llength [get_cells -hier -filter {IOB == TRUE && IS_PRIMITIVE}]]
puts "IOB: $iob_regs registers packed into IOBs"
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "TIMING: WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met"
    exit 1
}

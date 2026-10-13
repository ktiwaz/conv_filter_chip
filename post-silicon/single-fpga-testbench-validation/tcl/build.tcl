# Non-project synthesis -> implementation -> bitstream.
# Usage: vivado -mode batch -source tcl/build.tcl   (IP must be generated first: tcl/gen_ip.tcl)

set root [file normalize [file dirname [info script]]/..]
source $root/tcl/common.tcl

set out $root/build
file mkdir $out/reports

set_part $part
read_verilog [list $root/testbench.v {*}[lsort [glob $root/rtl/*.v]]]
read_xdc $root/testbench.xdc
foreach ip $ip_names {
    read_ip $root/ip/$ip/$ip.xci
}

# Absolute path so $readmemh doesn't depend on Vivado's working directory
set init_file $root/input_image_w32.hex
synth_design -top $top -part $part -generic "INIT_FILE=\"$init_file\""
write_checkpoint -force $out/post_synth.dcp
report_utilization -file $out/reports/utilization_synth.rpt

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $out/post_route.dcp

report_utilization    -file $out/reports/utilization.rpt
report_timing_summary -file $out/reports/timing_summary.rpt
report_drc            -file $out/reports/drc.rpt
report_ram_utilization -file $out/reports/ram_utilization.rpt

write_bitstream    -force $out/$top.bit
write_debug_probes -force $out/$top.ltx

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "TIMING: WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met"
    exit 1
}

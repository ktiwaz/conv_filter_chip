# Program the PYNQ-Z2 PL with build/testbench.bit (+ debug probes).
# Usage: vivado -mode batch -source tcl/program.tcl

set root [file normalize [file dirname [info script]]/..]
source $root/tcl/common.tcl

open_hw_manager
connect_hw_server
open_hw_target

set dev [lindex [get_hw_devices xc7z020*] 0]
current_hw_device $dev
set_property PROGRAM.FILE     $root/build/$top.bit $dev
set_property PROBES.FILE      $root/build/$top.ltx $dev
set_property FULL_PROBES.FILE $root/build/$top.ltx $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "Programmed $dev; hw_axi cores: [get_hw_axis]"

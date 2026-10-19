# Program a board's PL.
# Usage: vivado -mode batch -source tcl/program.tcl -tclargs tester|dut
#   tester: build/tester/testbench.bit on the board with tester_serial
#   dut:    build/dut/dut_board.bit    on the board with dut_serial

set root [file normalize [file dirname [info script]]/..]
source $root/tcl/common.tcl
source $root/tcl/boards.tcl

set role [build_role]
set top  $role_top($role)
set serial [expr {$role eq "tester" ? $tester_serial : $dut_serial}]

set dev [open_board $serial]
set_property PROGRAM.FILE     $root/build/$role/$top.bit $dev
set_property PROBES.FILE      $root/build/$role/$top.ltx $dev
set_property FULL_PROBES.FILE $root/build/$role/$top.ltx $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "Programmed $role ($top) on [current_hw_target]; hw_axi cores: [get_hw_axis -quiet]"

# Print every connected JTAG target and which role (if any) it is assigned.
set root [file normalize [file dirname [info script]]/..]
source $root/tcl/boards.tcl
list_boards

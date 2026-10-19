# Which physical board is which. Both PYNQ-Z2s look identical to hw_server;
# they are told apart by the Digilent JTAG serial in the hw_target name
# (e.g. localhost:3121/xilinx_tcf/Digilent/003017A6FB2CA).
#
# Run `make list-boards`, then put the serials in boards.local.tcl (not in git):
#   set tester_serial 003017A6FB2CA
#   set dut_serial    003017A6FB3DB
set tester_serial ""
set dut_serial    ""

set _boards_local [file normalize [file dirname [info script]]/../boards.local.tcl]
if {[file exists $_boards_local]} { source $_boards_local }

proc boards_connect_server {} {
    if {[llength [get_hw_servers -quiet]] == 0} {
        catch {open_hw_manager}
        connect_hw_server
    }
}

# Open the hw_target whose name contains serial and make its xc7z020 the
# current device. An empty serial is allowed when exactly one board is connected.
proc open_board {serial} {
    boards_connect_server
    set targets [get_hw_targets -quiet]
    if {$serial eq ""} {
        if {[llength $targets] != 1} {
            error "[llength $targets] boards connected but no serial given; set tester_serial/dut_serial in boards.local.tcl (see make list-boards)"
        }
        set target [lindex $targets 0]
    } else {
        set target [lsearch -inline -glob $targets "*$serial*"]
        if {$target eq ""} { error "no connected board with serial $serial (connected: $targets)" }
    }

    set cur [current_hw_target -quiet]
    if {$cur ne "" && $cur ne $target && [get_property IS_OPENED $cur]} {
        close_hw_target $cur
    }
    if {![get_property IS_OPENED [get_hw_targets $target]]} {
        open_hw_target [get_hw_targets $target]
    }
    set dev [lindex [get_hw_devices xc7z020*] 0]
    current_hw_device $dev
    refresh_hw_device -quiet $dev
    return $dev
}

proc list_boards {} {
    global tester_serial dut_serial
    boards_connect_server
    if {[catch {get_hw_targets} targets]} {
        puts "ERROR: $targets"
        puts "ERROR: close any other Vivado Hardware Manager / make hw session and retry"
        return
    }
    set names {}
    foreach t $targets { lappend names [file tail $t] }
    if {[llength [lsort -unique $names]] != [llength $names]} {
        puts "WARNING: boards share a JTAG serial; they can only be told apart after one gets a unique FTDI serial (Vivado: program_ftdi -help)"
    }
    foreach t $targets {
        set role ""
        if {$tester_serial ne "" && [string match "*$tester_serial*" $t]} { set role "  <- tester" }
        if {$dut_serial    ne "" && [string match "*$dut_serial*"    $t]} { set role "  <- dut" }
        puts "$t$role"
    }
}

# Shared settings for the non-project flow
set part xc7z020clg400-1

# Build roles: tester (JTAG-AXI testbench, internal DUT + link) and dut (DUT board)
set roles {tester dut}
array set role_top {tester testbench dut dut_board}
array set role_ips {tester {clk_wiz_0 ila_0 jtag_axi_0} dut {ila_dut}}
set ip_names {clk_wiz_0 ila_0 jtag_axi_0 ila_dut}

# DUT (chip RTL) sources listed in dut_sources.f, as absolute paths
proc dut_sources {root} {
    set f [open $root/dut_sources.f r]
    set srcs {}
    foreach line [split [read $f] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        lappend srcs [file normalize $root/$line]
    }
    close $f
    return $srcs
}

# Role from -tclargs (default tester)
proc build_role {} {
    global roles
    set role tester
    if {[info exists ::argv] && [llength $::argv] > 0} { set role [lindex $::argv 0] }
    if {$role ni $roles} { error "unknown role '$role' (expected one of: $roles)" }
    return $role
}

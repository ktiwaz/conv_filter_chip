# Shared settings for the non-project flow
set part xc7z020clg400-1

# Build roles: tester (JTAG-AXI testbench, internal DUT + link) and dut (DUT board)
set roles {tester dut iolab}
array set role_top {tester testbench dut dut_board iolab iolab}
array set role_ips {tester {clk_wiz_0 clk_wiz_1 ila_0 jtag_axi_0} dut {ila_dut} iolab {jtag_axi_0}}
set ip_names {clk_wiz_0 clk_wiz_1 ila_0 jtag_axi_0 ila_dut}

# Digilent HDMI TMDS sources (third_party/fetch_digilent.sh), compiled into
# their own VHDL libraries because both IPs ship files with the same entities
proc digilent_sources {root ip} {
    set dir $root/third_party/vivado-library/ip/$ip/src
    if {![file isdirectory $dir]} { error "missing $dir; run third_party/fetch_digilent.sh" }
    return [lsort [glob $dir/*.vhd]]
}

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

# I/O lab variant from -tclargs: iolab <wiring> <MHz> (defaults pmod8 25)
proc iolab_variant {} {
    set wiring pmod8
    set mhz 25
    if {[info exists ::argv] && [llength $::argv] > 1} { set wiring [lindex $::argv 1] }
    if {[info exists ::argv] && [llength $::argv] > 2} { set mhz [lindex $::argv 2] }
    return [list $wiring $mhz]
}

# Build output directory for a role (and the I/O lab variant)
proc role_dir {root role} {
    if {$role eq "iolab"} {
        lassign [iolab_variant] wiring mhz
        return $root/build/iolab_${wiring}_${mhz}
    }
    return $root/build/$role
}

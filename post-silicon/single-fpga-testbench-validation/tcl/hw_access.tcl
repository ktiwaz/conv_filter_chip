# Hardware Manager helpers for the single-FPGA testbench (JTAG-to-AXI).
#
# Source after the device is programmed (make hw does this for you):
#   jtb_connect                     open hw_server/target if not already open
#   jtb_id                          read ID register (expect C0F10001)
#   jtb_selftest                    ramp write/readback of the input RAM; also
#                                   checks burst beat ordering
#   jtb_write_image <in.hex8>       load an image into the input RAM
#   jtb_start                       start a stream (same as flipping sw[1] up)
#   jtb_wait_done ?timeout_ms?      poll STATUS.done
#   jtb_status                      print STATUS / CAP_COUNT
#   jtb_read_capture <out.hex8>     dump CAP_COUNT bytes of the capture RAM
#   jtb_read_input <out.hex8>       dump the input RAM
#   jtb_run <in.hex8> <out.hex8>    write_image + start + wait_done + read_capture
#
# Relative file paths are relative to the testbench root (the Makefile dir).

namespace eval jtb {
    variable IN_BASE   0x00000000
    variable CAP_BASE  0x00010000
    variable CTRL      0x00020000
    variable STATUS    0x00020004
    variable CAP_COUNT 0x00020008
    variable ID        0x0002000C
    variable NUM_PIXELS 16384
    variable BURST      256
    # Order of beats in create_hw_axi_txn -data / DATA strings.
    # 1: first beat is the rightmost word. jtb_selftest checks this.
    variable first_beat_rightmost 1
    variable txn_seq 0
    # Relative file paths are resolved against the testbench root, not
    # Vivado's working directory (make hw runs from build/).
    variable root [file normalize [file dirname [info script]]/..]
}

proc jtb::path {p} {
    variable root
    return [file normalize [file join $root $p]]
}

proc jtb::axi {} {
    set axis [get_hw_axis]
    if {[llength $axis] == 0} {
        error "no hw_axi found; is the device programmed and refreshed?"
    }
    return [lindex $axis 0]
}

proc jtb::txn_name {} {
    variable txn_seq
    incr txn_seq
    return "jtb_txn_$txn_seq"
}

proc jtb::words_to_data {words} {
    variable first_beat_rightmost
    if {$first_beat_rightmost} { set words [lreverse $words] }
    set s ""
    foreach w $words { append s [format %08x [expr {$w & 0xFFFFFFFF}]] }
    return $s
}

proc jtb::data_to_words {data n} {
    variable first_beat_rightmost
    set data [string map {_ ""} $data]
    set words {}
    for {set i 0} {$i < $n} {incr i} {
        lappend words [scan [string range $data [expr {$i * 8}] [expr {$i * 8 + 7}]] %x]
    }
    if {$first_beat_rightmost} { set words [lreverse $words] }
    return $words
}

# Write a list of 32-bit words starting at byte address addr (one burst, <= 256 beats)
proc jtb::write {addr words} {
    set name [txn_name]
    set len [llength $words]
    create_hw_axi_txn $name [axi] -type write -address [format %08x $addr] \
        -len $len -burst INCR -data [words_to_data $words]
    run_hw_axi -quiet [get_hw_axi_txns $name]
    delete_hw_axi_txn [get_hw_axi_txns $name]
}

# Read n 32-bit words starting at byte address addr (one burst, <= 256 beats)
proc jtb::read {addr n} {
    set name [txn_name]
    create_hw_axi_txn $name [axi] -type read -address [format %08x $addr] \
        -len $n -burst INCR
    run_hw_axi -quiet [get_hw_axi_txns $name]
    set data [get_property DATA [get_hw_axi_txns $name]]
    delete_hw_axi_txn [get_hw_axi_txns $name]
    return [data_to_words $data $n]
}

proc jtb::read1 {addr} {
    return [lindex [read $addr 1] 0]
}

proc jtb::read_hex8 {path} {
    set f [open $path r]
    set pixels {}
    foreach tok [regexp -all -inline {\S+} [::read $f]] {
        lappend pixels [expr {[scan $tok %x] & 0xFF}]
    }
    close $f
    return $pixels
}

proc jtb::write_hex8 {path pixels} {
    set f [open $path w]
    foreach p $pixels { puts $f [format %02x $p] }
    close $f
}

proc jtb::write_pixels {base pixels} {
    variable BURST
    while {[llength $pixels] % 4} { lappend pixels 0 }
    set words {}
    foreach {p0 p1 p2 p3} $pixels {
        lappend words [expr {$p0 | ($p1 << 8) | ($p2 << 16) | ($p3 << 24)}]
    }
    for {set i 0} {$i < [llength $words]} {incr i $BURST} {
        write [expr {$base + $i * 4}] [lrange $words $i [expr {$i + $BURST - 1}]]
    }
}

proc jtb::read_pixels {base count} {
    variable BURST
    set nwords [expr {($count + 3) / 4}]
    set pixels {}
    for {set i 0} {$i < $nwords} {incr i $BURST} {
        set n [expr {min($BURST, $nwords - $i)}]
        foreach w [read [expr {$base + $i * 4}] $n] {
            lappend pixels [expr {$w & 0xFF}] [expr {($w >> 8) & 0xFF}] \
                           [expr {($w >> 16) & 0xFF}] [expr {($w >> 24) & 0xFF}]
        }
    }
    return [lrange $pixels 0 [expr {$count - 1}]]
}

#--------------------------------------------------
# User commands
#--------------------------------------------------
proc jtb_connect {} {
    # current_hw_server/current_hw_target only warn and return "" when nothing
    # is open, so check the returned objects rather than catching errors.
    if {[llength [get_hw_servers -quiet]] == 0} {
        catch {open_hw_manager}
        connect_hw_server
    }
    set tgt [current_hw_target -quiet]
    if {$tgt eq "" || ![get_property IS_OPENED $tgt]} {
        open_hw_target
    }
    set dev [lindex [get_hw_devices xc7z020*] 0]
    current_hw_device $dev
    refresh_hw_device -quiet $dev
    reset_hw_axi [jtb::axi]
    puts "Connected: $dev, [jtb::axi]"
}

proc jtb_id {} {
    set id [format %08X [jtb::read1 $jtb::ID]]
    puts "ID = $id"
    return $id
}

proc jtb_status {} {
    set st  [jtb::read1 $jtb::STATUS]
    set cnt [jtb::read1 $jtb::CAP_COUNT]
    puts [format "busy=%d done=%d cap_count=%d" [expr {$st & 1}] [expr {($st >> 1) & 1}] $cnt]
    return [list $st $cnt]
}

proc jtb_start {} {
    jtb::write $jtb::CTRL {1}
}

proc jtb_wait_done {{timeout_ms 5000}} {
    set t0 [clock milliseconds]
    while {!(([jtb::read1 $jtb::STATUS] >> 1) & 1)} {
        if {[clock milliseconds] - $t0 > $timeout_ms} { error "timeout waiting for done" }
        after 10
    }
}

proc jtb_write_image {path} {
    set path [jtb::path $path]
    set pixels [jtb::read_hex8 $path]
    if {[llength $pixels] > $jtb::NUM_PIXELS} { error "$path has more than $jtb::NUM_PIXELS pixels" }
    jtb::write_pixels $jtb::IN_BASE $pixels
    puts "Wrote [llength $pixels] pixels from $path"
}

proc jtb_read_input {path} {
    set path [jtb::path $path]
    jtb::write_hex8 $path [jtb::read_pixels $jtb::IN_BASE $jtb::NUM_PIXELS]
    puts "Wrote input RAM to $path"
}

proc jtb_read_capture {path} {
    set path [jtb::path $path]
    set count [jtb::read1 $jtb::CAP_COUNT]
    if {$count == 0} { puts "WARNING: CAP_COUNT is 0"; return }
    jtb::write_hex8 $path [jtb::read_pixels $jtb::CAP_BASE $count]
    puts "Wrote $count captured pixels to $path"
}

proc jtb_run {in_path out_path} {
    jtb_write_image $in_path
    jtb_start
    jtb_wait_done
    jtb_read_capture $out_path
}

# Writes a ramp to the input RAM with bursts, checks a few words with
# single-beat reads (unambiguous) to confirm beat ordering, then checks the
# whole burst readback. Overwrites the input RAM.
proc jtb_selftest {} {
    set id [jtb_id]
    if {$id ne "C0F10001"} { error "bad ID $id" }

    set words {}
    for {set i 0} {$i < $jtb::BURST} {incr i} {
        lappend words [expr {0xA5000000 | ($i * 0x10101) & 0xFFFFFF}]
    }
    jtb::write $jtb::IN_BASE $words

    set w0 [jtb::read1 $jtb::IN_BASE]
    if {$w0 != [lindex $words 0]} {
        if {$w0 == [lindex $words end]} {
            puts "Burst beat order is reversed from the assumption; flipping it"
            set jtb::first_beat_rightmost [expr {!$jtb::first_beat_rightmost}]
            jtb::write $jtb::IN_BASE $words
        } else {
            error [format "selftest: word 0 = %08x, expected %08x" $w0 [lindex $words 0]]
        }
    }

    foreach i {0 1 2 127 255} {
        set got [jtb::read1 [expr {$jtb::IN_BASE + $i * 4}]]
        if {$got != [lindex $words $i]} {
            error [format "selftest: single read word %d = %08x, expected %08x" $i $got [lindex $words $i]]
        }
    }
    set back [jtb::read $jtb::IN_BASE $jtb::BURST]
    if {$back ne $words} { error "selftest: burst readback mismatch" }
    puts "SELFTEST PASS (first_beat_rightmost = $jtb::first_beat_rightmost)"
}

# `vivado -mode tcl -source tcl/hw_access.tcl -tclargs connect` (make hw) connects right away
if {[info exists ::argv] && "connect" in $::argv} {
    jtb_connect
}

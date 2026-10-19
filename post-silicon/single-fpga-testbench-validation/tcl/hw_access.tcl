# Hardware Manager helpers for the single-FPGA testbench (JTAG-to-AXI).
#
# Source after the device is programmed (make hw does this for you):
#   jtb_connect                     open the tester board (tester_serial in
#                                   boards.local.tcl when two boards are connected)
#   jtb_id                          read ID register (expect C0F10003)
#   jtb_selftest                    ramp write/readback of the input RAM; also
#                                   checks burst beat ordering
#   jtb_write_image <in.hex8>       load an image into the input RAM
#   jtb_start                       start a run (same as flipping sw[1] up)
#   jtb_wait_done ?timeout_ms?      poll STATUS.done
#   jtb_status                      print STATUS / CAP_COUNT / DUT status / config
#   jtb_read_capture <out.hex8>     dump CAP_COUNT bytes of the capture RAM
#   jtb_read_input <out.hex8>       dump the input RAM
#   jtb_run <in.hex8> <out.hex8>    write_image + start + wait_done + read_capture
#                                   (uses the current kernel/norm/config)
#
# DUT configuration (applied on every start: DUT reset, kernel, norm, pixels):
#   jtb_set_kernel <kernel.hex>     25 signed bytes, row-major (testcases format)
#   jtb_set_norm <value>            16-bit Q1.15 normalization value
#   jtb_config ?-bypass 0|1? ?-test_mode 0|1? ?-ext 0|1?
#                                   bypass=1 captures the raw pixel stream (no DUT)
#                                   ext=1 uses the DUT board over the RPi-header link
#   jtb_link ?-half H? ?-sample S?  link clock 25/H MHz; sample DUT outputs S fabric
#                                   cycles (20 ns) after the link rising edge
#                                   (-half alone also resets S to the measured
#                                   default: 0 for H >= 3, 1 for H <= 2)
#   jtb_sweep_sample <testcase>     run a testcase at every sample phase (timing eye)
#   jtb_set_gap <every> <cycles>    insert <cycles> idle cycles after every <every>
#                                   pixels (0 0 = no gaps)
#
# Golden testcases (<repo>/testcases):
#   jtb_run_testcase <name|dir> ?out.hex8?
#                                   e.g. 5x5/emboss; reads config.yml, kernel.hex,
#                                   input_image.hex, compares with expected_output_image.hex
#   jtb_run_all ?group?             every testcase in <group> (default 5x5), with a summary
#
# Relative file paths are relative to the testbench root (the Makefile dir).

source [file normalize [file dirname [info script]]]/boards.tcl

namespace eval jtb {
    variable IN_BASE   0x00000000
    variable CAP_BASE  0x00010000
    variable CTRL      0x00020000
    variable STATUS    0x00020004
    variable CAP_COUNT 0x00020008
    variable ID        0x0002000C
    variable CONFIG    0x00020010
    variable NORM      0x00020014
    variable GAP       0x00020018
    variable KERNEL    0x00020040
    variable LINK      0x0002001C
    variable ID_VALUE  C0F10003
    variable KERNEL_WORDS 25
    variable NUM_PIXELS 16384
    variable BURST      256
    # Order of beats in create_hw_axi_txn -data / DATA strings.
    # 1: first beat is the rightmost word. jtb_selftest checks this.
    variable first_beat_rightmost 1
    variable txn_seq 0
    # Relative file paths are resolved against the testbench root, not
    # Vivado's working directory (make hw runs from build/).
    variable root [file normalize [file dirname [info script]]/..]
    variable testcases [file normalize $root/../../testcases]
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
    set dev [open_board $::tester_serial]
    reset_hw_axi [jtb::axi]
    puts "Connected: [current_hw_target] $dev, [jtb::axi]"
}

proc jtb_id {} {
    set id [format %08X [jtb::read1 $jtb::ID]]
    puts "ID = $id"
    return $id
}

proc jtb_status {} {
    set st  [jtb::read1 $jtb::STATUS]
    set cnt [jtb::read1 $jtb::CAP_COUNT]
    set cfg [jtb::read1 $jtb::CONFIG]
    set gap [jtb::read1 $jtb::GAP]
    set link [jtb::read1 $jtb::LINK]
    set dut [lindex {IDLE LOAD_KERNEL LOAD_NORM ERROR} [expr {($st >> 4) & 3}]]
    set h [expr {max(1, $link & 0xFF)}]
    puts [format "busy=%d done=%d cap_count=%d dut=%s mode=%s bypass=%d test_mode=%d norm=%d gap=%d/%d link=%.2fMHz H=%d S=%d" \
        [expr {$st & 1}] [expr {($st >> 1) & 1}] $cnt $dut \
        [expr {($cfg >> 2) & 1 ? "ext" : "int"}] \
        [expr {$cfg & 1}] [expr {($cfg >> 1) & 1}] [jtb::read1 $jtb::NORM] \
        [expr {$gap >> 16}] [expr {$gap & 0xFFFF}] \
        [expr {25.0 / $h}] $h [expr {($link >> 8) & 0xFF}]]
    return [list $st $cnt]
}

proc jtb_set_kernel {path} {
    set path [jtb::path $path]
    set k [jtb::read_hex8 $path]
    if {[llength $k] != $jtb::KERNEL_WORDS} {
        error "$path has [llength $k] values, expected $jtb::KERNEL_WORDS"
    }
    while {[llength $k] % 4} { lappend k 0 }
    set words {}
    foreach {b0 b1 b2 b3} $k {
        lappend words [expr {$b0 | ($b1 << 8) | ($b2 << 16) | ($b3 << 24)}]
    }
    jtb::write $jtb::KERNEL $words
    if {[jtb::read $jtb::KERNEL [llength $words]] ne $words} { error "kernel readback mismatch" }
}

proc jtb_set_norm {value} {
    if {$value < 0 || $value > 0xFFFF} { error "norm must fit in 16 bits" }
    jtb::write $jtb::NORM [list $value]
}

proc jtb_config {args} {
    set cfg [jtb::read1 $jtb::CONFIG]
    foreach {opt val} $args {
        switch -- $opt {
            -bypass    { set cfg [expr {($cfg & ~1) | ($val ? 1 : 0)}] }
            -test_mode { set cfg [expr {($cfg & ~2) | ($val ? 2 : 0)}] }
            -ext       { set cfg [expr {($cfg & ~4) | ($val ? 4 : 0)}] }
            default    { error "usage: jtb_config ?-bypass 0|1? ?-test_mode 0|1? ?-ext 0|1?" }
        }
    }
    jtb::write $jtb::CONFIG [list $cfg]
}

proc jtb_link {args} {
    set link [jtb::read1 $jtb::LINK]
    set h [expr {$link & 0xFF}]
    set s [expr {($link >> 8) & 0xFF}]
    set s_given 0
    foreach {opt val} $args {
        switch -- $opt {
            -half   { set h $val }
            -sample { set s $val; set s_given 1 }
            default { error "usage: jtb_link ?-half H? ?-sample S?" }
        }
    }
    if {$h < 1 || $h > 255} { error "half period must be 1..255" }
    if {!$s_given && [dict exists $args -half]} { set s [expr {$h >= 3 ? 0 : 1}] }
    if {$s > 2 * $h - 1} { error "sample phase must be 0..[expr {2 * $h - 1}] for H=$h" }
    jtb::write $jtb::LINK [list [expr {($s << 8) | $h}]]
    puts [format "link %.2f MHz (H=%d), sampling %d ns after the rising edge (S=%d)" \
        [expr {25.0 / $h}] $h [expr {$s * 20}] $s]
}

# Run one testcase at every sample phase of the current link clock and print
# which phases pass. Restores the original sample phase afterwards.
proc jtb_sweep_sample {name} {
    set link [jtb::read1 $jtb::LINK]
    set h [expr {max(1, $link & 0xFF)}]
    set orig [expr {($link >> 8) & 0xFF}]
    set eye {}
    for {set s 0} {$s < 2 * $h} {incr s} {
        jtb::write $jtb::LINK [list [expr {($s << 8) | $h}]]
        puts -nonewline [format "S=%-3d (%4d ns)  " $s [expr {$s * 20}]]
        lappend eye [expr {[jtb_run_testcase $name] ? "PASS" : "FAIL"}]
    }
    jtb::write $jtb::LINK [list [expr {($orig << 8) | $h}]]
    puts "sample phase sweep at [format %.2f [expr {25.0 / $h}]] MHz: $eye"
    return $eye
}

proc jtb_set_gap {every cycles} {
    if {$every > 0xFFFF || $cycles > 0xFFFF} { error "gap fields are 16 bits" }
    jtb::write $jtb::GAP [list [expr {($every << 16) | $cycles}]]
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
    if {$id ne $jtb::ID_VALUE} { error "bad ID $id (expected $jtb::ID_VALUE; old bitstream?)" }

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

proc jtb::testcase_dir {name} {
    variable testcases
    if {[file isdirectory $name]} { return [file normalize $name] }
    set d [file join $testcases $name]
    if {[file isdirectory $d]} { return [file normalize $d] }
    set d [jtb::path $name]
    if {[file isdirectory $d]} { return $d }
    error "testcase $name not found (looked in $testcases)"
}

# Runs one golden testcase through the DUT. Returns 1 on PASS, 0 on FAIL.
proc jtb_run_testcase {name {out_path ""}} {
    set dir [jtb::testcase_dir $name]
    set f [open $dir/config.yml r]
    set cfg [::read $f]
    close $f
    if {![regexp {NORMALIZATION_VALUE=(\d+)} $cfg -> norm]} {
        error "no NORMALIZATION_VALUE in $dir/config.yml"
    }
    set tmode [regexp {TEST_MODE=1} $cfg]

    jtb_set_kernel $dir/kernel.hex
    jtb_set_norm $norm
    jtb_config -bypass 0 -test_mode $tmode   ;# keeps the current -ext setting
    jtb::write_pixels $jtb::IN_BASE [jtb::read_hex8 $dir/input_image.hex]
    jtb_start
    jtb_wait_done

    set st [jtb::read1 $jtb::STATUS]
    set count [jtb::read1 $jtb::CAP_COUNT]
    set mode [expr {([jtb::read1 $jtb::CONFIG] >> 2) & 1 ? "ext" : "int"}]
    set got [jtb::read_pixels $jtb::CAP_BASE $count]
    if {$out_path ne ""} {
        jtb::write_hex8 [jtb::path $out_path] $got
    }

    set exp [jtb::read_hex8 $dir/expected_output_image.hex]
    set label "[file tail [file dirname $dir]]/[file tail $dir]"
    set problems {}
    if {(($st >> 4) & 3) == 3} { lappend problems "DUT in ERROR state" }
    if {$count != [llength $exp]} {
        lappend problems "count $count, expected [llength $exp]"
    }
    set n [expr {min($count, [llength $exp])}]
    set bad 0
    set first -1
    for {set i 0} {$i < $n} {incr i} {
        if {[lindex $got $i] != [lindex $exp $i]} {
            if {$first < 0} { set first $i }
            incr bad
        }
    }
    if {$bad} {
        lappend problems [format "%d mismatches, first at %d: got %02x expected %02x" \
            $bad $first [lindex $got $first] [lindex $exp $first]]
    }
    if {[llength $problems] == 0} {
        puts [format "PASS %-20s %s norm=%-5d test_mode=%d %d px" $label $mode $norm $tmode $count]
        return 1
    }
    puts [format "FAIL %-20s %s %s" $label $mode [join $problems "; "]]
    return 0
}

proc jtb_run_all {{group 5x5}} {
    set root [jtb::testcase_dir $group]
    set pass 0
    set total 0
    foreach dir [lsort [glob -type d $root/*]] {
        if {![file exists $dir/config.yml]} continue
        incr total
        incr pass [jtb_run_testcase $dir]
    }
    puts "$pass / $total testcases passed"
    return [expr {$pass == $total}]
}

# `vivado -mode tcl -source tcl/hw_access.tcl -tclargs connect` (make hw) connects right away
if {[info exists ::argv] && "connect" in $::argv} {
    jtb_connect
}

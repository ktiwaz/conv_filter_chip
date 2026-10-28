# Hardware Manager commands for the I/O timing lab (role "iolab").
# make hw-iolab connects to the tester_serial board and loads this file.
#
#   iol_info                        frequency, phase-step size, wiring, looped-back clock
#   iol_check_wiring                walking-one lane mapping (catches a flipped strip)
#   iol_sweep <A|B|B2> ?-mode single|all|sso|aggressor? ?-lane n? ?-samples log2n?
#                                   one full-period phase sweep -> build/iolab/<name>.csv
#   iol_suite                       the step-1/step-2 experiment set for this build
#
# Then: python3 scripts/iolab_report.py build/iolab   (summary, eye maps, bathtubs)

source [file normalize [file dirname [info script]]]/hw_access.tcl

namespace eval iol {
    variable ID      0x101AB001
    variable CTRL    0x04
    variable STATUS  0x08
    variable CONFIG  0x0C
    variable STEP    0x10
    variable POINTS  0x14
    variable LOG2N   0x18
    variable STATIC  0x1C
    variable RX_A    0x20
    variable RX_B    0x24
    variable PHASE   0x28
    variable INFO    0x2C
    variable WIRING  0x30
    variable RCLK_HZ 0x34
    variable ONES    0x40
    variable RESULTS 0x20000
    variable wirings {pmod8 pmod_fwd jumper pmod8_rev jumper_rev jumper_check}
    variable modes   {single all sso aggressor static}
    variable exps    {A B B2}
    variable outdir  [file normalize [file dirname [info script]]/../build/iolab]
}

proc iol::info_dict {} {
    set info [jtb::read1 $iol::INFO]
    set div   [expr {$info & 0xFF}]
    set lanes [expr {($info >> 8) & 0xFF}]
    set vco   [expr {($info >> 16) & 0xFFFF}]
    set wiring [lindex $iol::wirings [jtb::read1 $iol::WIRING]]
    return [dict create div $div lanes $lanes vco_mhz $vco wiring $wiring \
        mhz [expr {double($vco) / $div}] step_ps [expr {1.0e6 / $vco / 56.0}] \
        steps_per_period [expr {56 * $div}]]
}

proc iol_info {} {
    set id [format %08X [jtb::read1 0x00]]
    if {"0x$id" != [format 0x%08X $iol::ID]} { error "not the I/O lab bitstream (ID $id)" }
    set d [iol::info_dict]
    puts [format "I/O lab: %s wiring, %d lanes, %.2f MHz (VCO %d MHz / %d), phase step %.2f ps, %d steps/period" \
        [dict get $d wiring] [dict get $d lanes] [dict get $d mhz] [dict get $d vco_mhz] \
        [dict get $d div] [dict get $d step_ps] [dict get $d steps_per_period]]
    puts [format "looped-back clock (rclk): %.3f MHz" [expr {[jtb::read1 $iol::RCLK_HZ] / 1.0e6}]]
    return $d
}

proc iol_check_wiring {} {
    set d [iol::info_dict]
    set lanes [dict get $d lanes]
    set ok 1
    set rclk [expr {[jtb::read1 $iol::RCLK_HZ] > 0}]
    jtb::write $iol::CONFIG [list [expr {4 << 4}]]
    puts "lane  sent  RX_A (clk_ref)  RX_B (rclk)"
    for {set i 0} {$i < $lanes} {incr i} {
        jtb::write $iol::STATIC [list [expr {1 << $i}]]
        after 20
        set a [jtb::read1 $iol::RX_A]
        set b [jtb::read1 $iol::RX_B]
        set mask [expr {(1 << $lanes) - 1}]
        set exp [expr {1 << $i}]
        set note ""
        if {($a & $mask) != $exp} { set ok 0; set note "  <- RX_A mismatch" }
        if {$rclk && ($b & $mask) != $exp} { set ok 0; append note "  <- RX_B mismatch" }
        if {$rclk} { set bcol [format "0x%02x" [expr {$b & $mask}]] } else { set bcol "(no rclk)" }
        puts [format "%3d   0x%02x  0x%02x            %s%s" $i $exp [expr {$a & $mask}] $bcol $note]
    }
    jtb::write $iol::STATIC {0}
    puts [expr {$ok ? "WIRING OK" : "WIRING MISMATCH: check strip orientation / jumpers"}]
    return $ok
}

# One full-period sweep. Returns the CSV path.
proc iol_sweep {exp args} {
    set e [lsearch -exact $iol::exps $exp]
    if {$e < 0} { error "experiment must be one of: $iol::exps" }
    set mode all
    set lane 0
    set log2n 16
    set name ""
    foreach {opt val} $args {
        switch -- $opt {
            -mode    { set mode $val }
            -lane    { set lane $val }
            -samples { set log2n $val }
            -name    { set name $val }
            default  { error "usage: iol_sweep <A|B|B2> ?-mode m? ?-lane n? ?-samples log2n? ?-name label?" }
        }
    }
    set m [lsearch -exact $iol::modes $mode]
    if {$m < 0 || $m > 3} { error "mode must be one of: single all sso aggressor" }

    set d [iol::info_dict]
    set spp [dict get $d steps_per_period]
    set k [expr {$spp > 2048 ? 2 : 1}]
    set points [expr {$spp / $k}]
    if {$name eq ""} { set name "[dict get $d wiring]_[expr {int([dict get $d mhz])}]MHz_${exp}_${mode}_lane$lane" }

    set phase0 [jtb::read1 $iol::PHASE]
    jtb::write $iol::CONFIG [list [expr {($lane << 8) | ($m << 4) | $e}]]
    jtb::write $iol::STEP   [list $k]
    jtb::write $iol::POINTS [list $points]
    jtb::write $iol::LOG2N  [list $log2n]
    set t0 [clock milliseconds]
    jtb::write $iol::CTRL {1}
    while {1} {
        after 200
        set st [jtb::read1 $iol::STATUS]
        if {!($st & 1)} break
    }
    if {$st & 4} { puts "WARNING: some points timed out (no clock in that domain? exp B/B2 need the clock loopback)" }

    set words {}
    set total [expr {$points * 16}]
    for {set w 0} {$w < $total} {incr w 256} {
        set n [expr {min(256, $total - $w)}]
        lappend words {*}[jtb::read [expr {$iol::RESULTS + $w * 4}] $n]
    }
    set ones {}
    for {set l 0} {$l < 8} {incr l} { lappend ones [jtb::read1 [expr {$iol::ONES + 4 * $l}]] }

    file mkdir $iol::outdir
    set path $iol::outdir/$name.csv
    set f [open $path w]
    puts $f "# iolab sweep"
    foreach key {wiring lanes mhz div vco_mhz step_ps steps_per_period} { puts $f "# $key=[dict get $d $key]" }
    puts $f "# exp=$exp"
    puts $f "# mode=$mode"
    puts $f "# lane=$lane"
    puts $f "# samples=[expr {1 << $log2n}]"
    puts $f "# step_k=$k"
    puts $f "# phase_start=[expr {$phase0 % $spp}]"
    puts $f "# ones_last_point=[join $ones ,]"
    puts $f "point,[join [lmap l {0 1 2 3 4 5 6 7} {set _ lane$l}] ,],[join [lmap l {0 1 2 3 4 5 6 7} {set _ rise$l}] ,],[join [lmap l {0 1 2 3 4 5 6 7} {set _ fall$l}] ,]"
    for {set p 0} {$p < $points} {incr p} {
        set base [expr {$p * 16}]
        set tot  [lrange $words $base [expr {$base + 7}]]
        set rise {}
        set fall {}
        foreach w [lrange $words [expr {$base + 8}] [expr {$base + 15}]] {
            if {$w == 0xFFFFFFFF} { lappend rise $w; lappend fall $w; continue }
            lappend rise [expr {$w & 0xFFFF}]
            lappend fall [expr {($w >> 16) & 0xFFFF}]
        }
        puts $f "$p,[join $tot ,],[join $rise ,],[join $fall ,]"
    }
    close $f
    puts [format "%s: %d points x %d steps in %.1f s -> %s" $name $points $k \
        [expr {([clock milliseconds] - $t0) / 1000.0}] $path]
    return $path
}

# The experiment set for this build's wiring
proc iol_suite {} {
    set d [iol_info]
    if {![iol_check_wiring]} { error "fix the wiring first" }
    set lanes [dict get $d lanes]
    set wiring [dict get $d wiring]
    for {set l 0} {$l < $lanes} {incr l} { iol_sweep A -mode single -lane $l }
    foreach mode {all sso aggressor} { iol_sweep A -mode $mode -lane 0 }
    if {$wiring ne "pmod8"} {
        if {[jtb::read1 $iol::RCLK_HZ] == 0} { error "no looped-back clock: check the clock wire" }
        iol_sweep B  -mode single -lane 0
        iol_sweep B  -mode all
        iol_sweep B2
    }
    puts "Suite done. Report: python3 scripts/iolab_report.py $iol::outdir"
}

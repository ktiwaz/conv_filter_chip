# I/O lab wirings (role "iolab"). Each maps the iolab top-level ports to
# package pins; "label" says where the wire goes. Pins from the official TUL
# "PYNQ-Z2 v1.0.xdc" (ja/jb, rpio_NN_r).
#
#   pmod8    exp A only: 8 lanes JB -> JA over two 6-wire strips (JBn <-> JAn).
#   pmod8_rev  the same 8 wires driven the other way, JA -> JB (exp A only), to
#            tell whether slow edges belong to the JB drivers or the JA receivers.
#   pmod_fwd exp A/B/B2: 6 lanes JB -> JA, forwarded clock JB7 -> JA7 (U18 is
#            clock-capable; JB has no clock-capable pins), return bit JA8 -> JB8.
#   jumper   exp A/B/B2 on the RPi header, on the real two-board link's pins:
#            lanes chip_datain -> chip_dataout pins, clock pin 11 -> 40, return 8 -> 37.
#            (A clock input must be the P side of a clock-capable pair: Y9 is
#            IO_L14P_T2_SRCC_13; Y6, the N side of L13, is rejected by Vivado.)
#            PMOD JA must be unplugged (it shares U18/U19/Y19 with the header).
#
#   jumper_rev the same 10 jumpers driven the other way: lanes 24..36 -> 12..23,
#            clock 40 -> 11 (U7, IO_L11P_SRCC), return 37 -> 8. Measures the pins the
#            DUT board receives on (chip_datain, chip_pixel_valid) as receivers.
#
#   jumper_check 3 lanes to check receivers for the reordered link pinout:
#            15 -> 8, 16 -> 10, 18 -> 13 (13 = GPIO27, V7, not in the official XDC).
#            Spare outputs go to PMOD JB (unplugged) so they can't drive into
#            any jumpers still on the header.
#
# Ports listed as "spare" are constrained to unused RPi-header pins so every
# port has a location; nothing is wired to them in that wiring.

#                      port          pin   label
set iolab_wirings(pmod8) {
    lane_out[0] W14  JB1      lane_in[0] Y18  JA1
    lane_out[1] Y14  JB2      lane_in[1] Y19  JA2
    lane_out[2] T11  JB3      lane_in[2] Y16  JA3
    lane_out[3] T10  JB4      lane_in[3] Y17  JA4
    lane_out[4] V16  JB7      lane_in[4] U18  JA7
    lane_out[5] W16  JB8      lane_in[5] U19  JA8
    lane_out[6] V12  JB9      lane_in[6] W18  JA9
    lane_out[7] W13  JB10     lane_in[7] W19  JA10
    fclk_out    U7   spare    fclk_in    Y9   spare
    ret_out     V6   spare    ret_in     W9   spare
}
set iolab_wirings(pmod8_rev) {
    lane_out[0] Y18  JA1      lane_in[0] W14  JB1
    lane_out[1] Y19  JA2      lane_in[1] Y14  JB2
    lane_out[2] Y16  JA3      lane_in[2] T11  JB3
    lane_out[3] Y17  JA4      lane_in[3] T10  JB4
    lane_out[4] U18  JA7      lane_in[4] V16  JB7
    lane_out[5] U19  JA8      lane_in[5] W16  JB8
    lane_out[6] W18  JA9      lane_in[6] V12  JB9
    lane_out[7] W19  JA10     lane_in[7] W13  JB10
    fclk_out    U7   spare    fclk_in    Y9   spare
    ret_out     V6   spare    ret_in     W9   spare
}
set iolab_wirings(pmod_fwd) {
    lane_out[0] W14  JB1      lane_in[0] Y18  JA1
    lane_out[1] Y14  JB2      lane_in[1] Y19  JA2
    lane_out[2] T11  JB3      lane_in[2] Y16  JA3
    lane_out[3] T10  JB4      lane_in[3] Y17  JA4
    lane_out[4] V12  JB9      lane_in[4] W18  JA9
    lane_out[5] W13  JB10     lane_in[5] W19  JA10
    lane_out[6] C20  spare    lane_in[6] F19  spare
    lane_out[7] U8   spare    lane_in[7] B20  spare
    fclk_out    V16  JB7      fclk_in    U18  JA7
    ret_out     U19  JA8      ret_in     W16  JB8
}
set iolab_wirings(jumper) {
    lane_out[0] C20  RPi12    lane_in[0] F19  RPi24
    lane_out[1] U8   RPi15    lane_in[1] U19  RPi26
    lane_out[2] W6   RPi16    lane_in[2] Y19  RPi29
    lane_out[3] Y7   RPi18    lane_in[3] U18  RPi31
    lane_out[4] V8   RPi19    lane_in[4] B20  RPi32
    lane_out[5] V10  RPi21    lane_in[5] W8   RPi33
    lane_out[6] F20  RPi22    lane_in[6] Y8   RPi35
    lane_out[7] W10  RPi23    lane_in[7] B19  RPi36
    fclk_out    U7   RPi11    fclk_in    Y9   RPi40
    ret_out     V6   RPi8     ret_in     W9   RPi37
}
set iolab_wirings(jumper_rev) {
    lane_out[0] F19  RPi24    lane_in[0] C20  RPi12
    lane_out[1] U19  RPi26    lane_in[1] U8   RPi15
    lane_out[2] Y19  RPi29    lane_in[2] W6   RPi16
    lane_out[3] U18  RPi31    lane_in[3] Y7   RPi18
    lane_out[4] B20  RPi32    lane_in[4] V8   RPi19
    lane_out[5] W8   RPi33    lane_in[5] V10  RPi21
    lane_out[6] Y8   RPi35    lane_in[6] F20  RPi22
    lane_out[7] B19  RPi36    lane_in[7] W10  RPi23
    fclk_out    Y9   RPi40    fclk_in    U7   RPi11
    ret_out     W9   RPi37    ret_in     V6   RPi8
}
set iolab_wirings(jumper_check) {
    lane_out[0] U8   RPi15    lane_in[0] V6   RPi8
    lane_out[1] W6   RPi16    lane_in[1] Y6   RPi10
    lane_out[2] Y7   RPi18    lane_in[2] V7   RPi13
    lane_out[3] W14  spare    lane_in[3] W18  spare
    lane_out[4] Y14  spare    lane_in[4] W19  spare
    lane_out[5] T11  spare    lane_in[5] Y18  spare
    lane_out[6] T10  spare    lane_in[6] Y16  spare
    lane_out[7] V12  spare    lane_in[7] Y17  spare
    fclk_out    V16  spare    fclk_in    Y9   spare
    ret_out     W16  spare    ret_in     W13  spare
}
array set iolab_wiring_id {pmod8 0 pmod_fwd 1 jumper 2 pmod8_rev 3 jumper_rev 4 jumper_check 5}
array set iolab_lanes     {pmod8 8 pmod_fwd 6 jumper 8 pmod8_rev 8 jumper_rev 8 jumper_check 3}
# Supported frequencies (MHz) and their divider from the 1000 MHz VCO
array set iolab_div {25 40 50 20 62 16 83 12 100 10}

proc iolab_constraints {wiring div} {
    global iolab_wirings
    foreach {p1 pin1 l1 p2 pin2 l2} $iolab_wirings($wiring) {
        foreach {port pin} [list $p1 $pin1 $p2 $pin2] {
            set_property PACKAGE_PIN $pin [get_ports $port]
            set_property IOSTANDARD LVCMOS33 [get_ports $port]
        }
    }
    # Same I/O settings as the two-board link (tcl/link_pins.tcl)
    set data_out [get_ports {lane_out[*] ret_out}]
    set_property DRIVE 12 $data_out
    set_property SLEW FAST $data_out
    set_property DRIVE 8 [get_ports fclk_out]
    set_property SLEW SLOW [get_ports fclk_out]
    set_property PULLDOWN true [get_ports {lane_in[*] ret_in fclk_in}]

    # The measurement replaces timing analysis on the loopback paths
    set_false_path -to   [get_ports {lane_out[*] ret_out fclk_out}]
    set_false_path -from [get_ports {lane_in[*] ret_in}]

    set period [expr {$div * 1.0}]
    create_clock -name rclk -period $period [get_ports fclk_in]
    set_clock_groups -asynchronous \
        -group [get_clocks -of_objects [get_pins board/mmcm/CLKOUT0]] \
        -group [get_clocks -of_objects [get_pins board/mmcm/CLKOUT1]] \
        -group [get_clocks -of_objects [get_pins board/mmcm/CLKOUT2]] \
        -group [get_clocks rclk]
}

# Wiring table for one wiring (used by make iolab-pinout)
proc iolab_pinout {wiring} {
    global iolab_wirings
    puts "I/O lab wiring '$wiring' (connect each 'from' to its 'to'):"
    puts [format "  %-12s %-6s -> %-12s %-6s" "from port" "at" "to port" "at"]
    foreach {p1 pin1 l1 p2 pin2 l2} $iolab_wirings($wiring) {
        if {$l1 eq "spare"} continue
        if {[string match ret_out $p1] && $wiring eq "pmod_fwd"} {
            puts [format "  %-12s %-6s -> %-12s %-6s (the wire is the same strip position)" $p1 $l1 $p2 $l2]
        } else {
            puts [format "  %-12s %-6s -> %-12s %-6s" $p1 $l1 $p2 $l2]
        }
    }
}

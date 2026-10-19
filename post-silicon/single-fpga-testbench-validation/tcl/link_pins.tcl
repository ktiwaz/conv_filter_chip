# Board-to-board link pin map (PYNQ-Z2 Raspberry Pi header, both boards).
#
# The same header pin is used on both boards: wire pin N on the tester to
# pin N on the DUT board with a female-female jumper, plus GND. Never connect
# the 3V3/5V pins (1, 2, 4, 17). Package pins come from the official TUL
# "PYNQ-Z2 v1.0.xdc" (rpio_NN_r). GPIO17 (U7) is clock-capable (SRCC).
#
#   signal                    BCM GPIO  header pin  package pin  direction (tester view)
set link_pins {
    chip_clk                  17        11          U7           out
    chip_reset_n              2         3           W18          out
    chip_kernel_valid         3         5           W19          out
    chip_normalization_valid  4         7           Y18          out
    chip_pixel_valid          14        8           V6           out
    chip_test_mode            15        10          Y6           out
    chip_datain[0]            18        12          C20          out
    chip_datain[1]            22        15          U8           out
    chip_datain[2]            23        16          W6           out
    chip_datain[3]            24        18          Y7           out
    chip_datain[4]            10        19          V8           out
    chip_datain[5]            9         21          V10          out
    chip_datain[6]            25        22          F20          out
    chip_datain[7]            11        23          W10          out
    chip_dataout[0]           8         24          F19          in
    chip_dataout[1]           7         26          U19          in
    chip_dataout[2]           5         29          Y19          in
    chip_dataout[3]           6         31          U18          in
    chip_dataout[4]           12        32          B20          in
    chip_dataout[5]           13        33          W8           in
    chip_dataout[6]           19        35          Y8           in
    chip_dataout[7]           16        36          B19          in
    chip_output_valid         26        37          W9           in
    chip_status[0]            20        38          A20          in
    chip_status[1]            21        40          Y9           in
}

# Header GND pins to wire between the boards (use at least 4, spread out)
set link_gnd_pins {6 9 14 20 25 30 34 39}

# Apply pin constraints for role "tester" or "dut" to the current design
proc link_constraints {role} {
    global link_pins
    foreach {sig gpio hdr pkg dir} $link_pins {
        set port [get_ports $sig]
        set_property PACKAGE_PIN $pkg $port
        set_property IOSTANDARD LVCMOS33 $port
        set is_input [expr {($role eq "dut") == ($dir eq "out")}]
        if {$is_input} {
            # An unwired or idle link holds the DUT in reset with no valids
            set_property PULLDOWN true $port
        } elseif {$sig eq "chip_clk"} {
            # Slow edges on the forwarded clock: ringing on an unterminated
            # jumper could double-clock the DUT board
            set_property DRIVE 8 $port
            set_property SLEW SLOW $port
        } else {
            set_property DRIVE 12 $port
            set_property SLEW FAST $port
        }
    }

    set dut_in  [get_ports {chip_kernel_valid chip_normalization_valid chip_pixel_valid
                            chip_test_mode chip_datain[*]}]
    set dut_out [get_ports {chip_dataout[*] chip_output_valid chip_status[*]}]

    if {$role eq "tester"} {
        # All link signals are in IOB flops, so their pin timing is fixed by
        # the silicon; margin comes from the link scheme (rtl/link_phy.v) and
        # the adjustable sample phase.
        set_false_path -to   [get_ports {chip_clk chip_reset_n}]
        set_false_path -to   $dut_in
        set_false_path -from $dut_out
    } else {
        # DUT board: constrain the pin paths so the router keeps them short.
        # Worst-case link clock is 25 MHz (40 ns).
        create_clock -name chip_clk -period 40.000 [get_ports chip_clk]
        set_clock_groups -asynchronous -group [get_clocks chip_clk] -group [get_clocks sys_clk_pin]

        # Inputs are launched by the tester's IOB flops on the link falling
        # edge: ~4-8 ns of tester clock-to-pad plus wire.
        set in_dly_max 8.0
        set_input_delay -clock chip_clk -clock_fall -max $in_dly_max $dut_in
        set_input_delay -clock chip_clk -clock_fall -min 2.0 $dut_in

        # Clock-to-out (including the clock pin -> BUFG insertion) must fit in
        # 40 - 25 = 15 ns. In test_mode, output_valid is a counter compare
        # feeding the pin through LUTs, which needs ~14.5 ns.
        set out_dly_max 25.0
        set_output_delay -clock chip_clk -max $out_dly_max $dut_out
        set_output_delay -clock chip_clk -min 0.0  $dut_out

        # test_mode makes output_valid/dataout combinational from the inputs
        # (pixel_valid, test_mode): keep that pin-to-pin path short. The port
        # input/output delays still count against a -datapath_only max delay,
        # so they are added to the pin-to-pin budget.
        set pin_to_pin 12.0
        set_max_delay -datapath_only -from $dut_in -to $dut_out \
            [expr {$in_dly_max + $out_dly_max + $pin_to_pin}]

        # The DUT synchronizes reset internally
        set_false_path -from [get_ports chip_reset_n]
    }
}

# Print the wiring table
proc link_pinout {} {
    global link_pins link_gnd_pins
    puts [format "%-26s %-10s %-6s  %s" "signal" "RPi pin" "GPIO" "direction"]
    foreach {sig gpio hdr pkg dir} $link_pins {
        set arrow [expr {$dir eq "out" ? "tester -> DUT" : "DUT -> tester"}]
        puts [format "%-26s %-10s %-6s  %s" $sig $hdr "GPIO$gpio" $arrow]
    }
    puts [format "%-26s %-10s" "GND" [join $link_gnd_pins ", "]]
    puts "Wire each RPi header pin to the same pin number on the other board."
    puts "Do NOT connect pins 1, 2, 4, 17 (3V3/5V)."
}

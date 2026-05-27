# ============================================================
# Exact pin placement to match pad frame coordinates
# ============================================================

# ------------------------------------------------------------
# Pad geometry
# ------------------------------------------------------------

set pad_width 47.0
set pin_shift [expr {$pad_width / 2.0}]

# ------------------------------------------------------------
# Physical pad coordinate database
#
# These are the original pad coordinate locations used for
# Innovus pin assignment.
#
# Naming convention:
#   B0..B7 = bottom row, left to right
#   R0..R7 = right side, bottom to top
#   T0..T7 = top row, left to right
#   L0..L7 = left side, bottom to top
#
# Format:
#   pad_db(PAD_ID) = {side x y}
# ------------------------------------------------------------

array set pad_db {
    # Bottom row: left to right
    #B0 {bottom 185.325 19.14} #This is the original, technically correct location
    #I shifted this by 50 um to avoid the rectangular notch
    B0 {bottom 235.325 19.14}
    B1 {bottom 268.09  19.14}
    B2 {bottom 350.855 19.14}
    B3 {bottom 433.62  19.14}
    B4 {bottom 516.38  19.14}
    B5 {bottom 599.145 19.14}
    B6 {bottom 681.91  19.14}
    B7 {bottom 764.675 19.14}

    # Right side: bottom to top
    R0 {right 930.86 185.325}
    R1 {right 930.86 268.09}
    R2 {right 930.86 350.855}
    R3 {right 930.86 433.62}
    R4 {right 930.86 516.38}
    R5 {right 930.86 599.145}
    R6 {right 930.86 681.91}
    R7 {right 930.86 764.675}

    # Top row: left to right
    T0 {top 185.325 930.86}
    T1 {top 268.09  930.86}
    T2 {top 350.855 930.86}
    T3 {top 433.62  930.86}
    T4 {top 516.38  930.86}
    T5 {top 599.145 930.86}
    T6 {top 681.91  930.86}
    #T7 {top 764.675 930.86} #This is the original, technically correct location
    #I shifted this by 50 um to avoid the rectangular notch
    T7 {top 714.675 930.86}

    # Left side: bottom to top
    L0 {left 19.14 185.325}
    L1 {left 19.14 268.09}
    L2 {left 19.14 350.855}
    L3 {left 19.14 433.62}
    L4 {left 19.14 516.38}
    L5 {left 19.14 599.145}
    L6 {left 19.14 681.91}
    L7 {left 19.14 764.675}
}

# ------------------------------------------------------------
# Logical pin-to-pad assignment
#
# To change pinout, edit this list only.
#
# Format:
#   {pin_name pad_id}
# ------------------------------------------------------------

set pin_assignments {
    {clk L2}
    {reset_n L3}
    {kernel_valid L4}
    {normalization_valid L5}
    {pixel_valid L6}
    {datain[7] L7}

    {datain[6] T1}
    {datain[5] T2}
    {datain[4] T3}
    {datain[3] T4}
    {datain[2] T5}
    {datain[1] T6}
    {datain[0] T7}

    {dataout[7] B0}
    {dataout[6] B1}
    {dataout[5] B2}
    {dataout[4] B3}
    {dataout[3] B4}
    {dataout[2] B5}
    {dataout[1] B6}

    {dataout[0] R0}
    {output_valid R1}
    {status[0] R3}
    {status[1] R4}
    {test_mode R5}
}

    # Unused / spare pads:
    # B7, R2 (unused), R6, R7, T0, L0, L1

# ------------------------------------------------------------
# Helper procedure
# ------------------------------------------------------------

proc place_pad_pin {pin_name pad_id pad_width} {
    global pad_db

    if {![info exists pad_db($pad_id)]} {
        error "Unknown pad_id '$pad_id' for pin '$pin_name'"
    }

    set pin_shift [expr {$pad_width / 2.0}]

    set side [lindex $pad_db($pad_id) 0]
    set x    [lindex $pad_db($pad_id) 1]
    set y    [lindex $pad_db($pad_id) 2]

    if {$side == "top" || $side == "bottom"} {
        # Top/bottom pins shift LEFT by half pad width.
        set x_adj [expr {$x - $pin_shift}]
        set y_adj $y
    } elseif {$side == "left" || $side == "right"} {
        # Left/right pins shift DOWN by half pad width.
        set x_adj $x
        set y_adj [expr {$y - $pin_shift}]
    } else {
        error "Invalid side '$side' for pad_id '$pad_id'"
    }

    puts "Placing pin $pin_name on pad $pad_id side=$side at ($x_adj, $y_adj)"

    edit_pin \
        -pin $pin_name \
        -assign [list $x_adj $y_adj] \
        -layer METAL6 \
        -side $side \
        -fixed_pin
}

# ------------------------------------------------------------
# Place pins
# ------------------------------------------------------------

set_db assign_pins_edit_in_batch true

foreach assignment $pin_assignments {
    set pin_name [lindex $assignment 0]
    set pad_id   [lindex $assignment 1]

    place_pad_pin $pin_name $pad_id $pad_width
}

set_db assign_pins_edit_in_batch false

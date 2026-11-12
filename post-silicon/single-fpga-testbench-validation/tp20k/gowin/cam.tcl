# Gowin EDA (Education Edition) build of tp20k_cam_top, the same RTL as the
# open-source flow. Run from tp20k/ (make bit-cam-gowin):
#   gw_sh gowin/cam.tcl
# Generated inputs (build/kernel_rom.v, build/font_rom.v, build/chip.v) come
# from the open-source Makefile rules.

set root [file normalize ..]
set_device -name GW2A-18C GW2A-LV18PG256C8/I7

foreach f [list \
    tp20k_cam_top.v rtl/hdmi_tx_gowin.v rtl/tmds_encoder.v \
    $root/rtl/fpga_tb_core.v $root/rtl/axi4_slave_native.v $root/rtl/bram_dp_be.v \
    $root/rtl/dut_sequencer.v $root/rtl/link_phy.v \
    $root/rtl/video_downscale.v $root/rtl/video_frame.v $root/rtl/video_out.v \
    $root/rtl/video_timing.v $root/rtl/text_line.v \
    $root/third_party/core_dbg_bridge/src_v/dbg_bridge.v \
    $root/third_party/core_dbg_bridge/src_v/dbg_bridge_uart.v \
    $root/third_party/core_dbg_bridge/src_v/dbg_bridge_fifo.v \
    build/kernel_rom.v build/font_rom.v build/chip.v] {
    add_file -type verilog $f
}
add_file -type cst gowin/tp20k_cam_gowin.cst
add_file -type sdc gowin/tp20k_cam.sdc

set_option -top_module tp20k_cam_top
set_option -output_base_name tp20k_cam
set_option -verilog_std v2001
# The RAM-zeroing initial loops run 4096..16384 iterations (default limit 2000)
set_option -looplimit 100000
# No read/write collision logic on RAMs: nothing reads a word in the cycle it is
# written, and without this the input RAM infers an unsupported write mode
set_option -rw_check_on_ram 0
# Dual-purpose configuration pins used as ordinary I/O:
#   C10 (camera PWDN) is SSPI SCLK, A13 / C13 (LEDs) are READY / DONE
set_option -use_sspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1

# No security bit: with it set, openFPGALoader can't erase / reload SRAM afterwards
set_option -bit_security 0

run all

# PYNQ-Z2 HDMI pins (official TUL "PYNQ-Z2 v1.0.xdc"). Both connectors go
# straight to PL TMDS_33 pairs; there is no external transmitter/receiver.
set hdmi_tx_pins {
    hdmi_tx_clk_p   L16
    hdmi_tx_clk_n   L17
    hdmi_tx_d_p[0]  K17
    hdmi_tx_d_n[0]  K18
    hdmi_tx_d_p[1]  K19
    hdmi_tx_d_n[1]  J19
    hdmi_tx_d_p[2]  J18
    hdmi_tx_d_n[2]  H18
}
set hdmi_rx_pins {
    hdmi_rx_clk_p   N18
    hdmi_rx_clk_n   P19
    hdmi_rx_d_p[0]  V20
    hdmi_rx_d_n[0]  W20
    hdmi_rx_d_p[1]  T20
    hdmi_rx_d_n[1]  U20
    hdmi_rx_d_p[2]  N20
    hdmi_rx_d_n[2]  P20
}
set hdmi_rx_aux_pins {
    hdmi_rx_hpd     T19
    hdmi_rx_scl     U14
    hdmi_rx_sda     U15
}

proc hdmi_constraints {} {
    global hdmi_tx_pins hdmi_rx_pins hdmi_rx_aux_pins
    foreach {port pin} [concat $hdmi_tx_pins $hdmi_rx_pins] {
        set_property PACKAGE_PIN $pin [get_ports $port]
        set_property IOSTANDARD TMDS_33 [get_ports $port]
    }
    foreach {port pin} $hdmi_rx_aux_pins {
        set_property PACKAGE_PIN $pin [get_ports $port]
        set_property IOSTANDARD LVCMOS33 [get_ports $port]
    }

    # HDMI in: 720p60 pixel clock (dvi2rgb's MMCM derives the rest)
    create_clock -name hdmi_rx_clk -period 13.468 [get_ports hdmi_rx_clk_p]
    # The HDMI TX clocks come from clk_wiz_1, cascaded from the fabric clock,
    # so Vivado treats them as related. Every crossing between the fabric and
    # pixel domains goes through a synchronizer/toggle handshake or a
    # dual-clock RAM (rtl/video_frame.v), or is a static configuration bit.
    # The HDMI-in pixel clock is recovered from the source and unrelated to
    # both; its crossings into the fabric clock are synchronized in
    # rtl/fpga_tb_core.v and rtl/video_downscale.v (dual-clock RAM).
    set_clock_groups -asynchronous \
        -group [get_clocks -filter {NAME =~ clk_out1_clk_wiz_0*}] \
        -group [get_clocks -filter {NAME =~ clk_out*_clk_wiz_1*}] \
        -group [get_clocks -include_generated_clocks hdmi_rx_clk]
}

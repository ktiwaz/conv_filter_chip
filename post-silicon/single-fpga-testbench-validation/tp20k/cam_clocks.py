# nextpnr --pre-pack script for tp20k_cam_top: one timing target per clock.
ctx.addClock("clk", 46.41)          # fabric: tester, DUT, bridge (371.25 / 8)
ctx.addClock("pclk_v", 74.25)       # HDMI pixel clock (720p60)
ctx.addClock("core.rx_clk", 48)     # camera PCLK as nextpnr names it (~23 MHz; 2x margin)

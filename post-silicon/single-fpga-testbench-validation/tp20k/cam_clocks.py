# nextpnr --pre-pack script for tp20k_cam_top: one timing target per clock.
ctx.addClock("clk", 46.41)          # fabric: tester, DUT, bridge (371.25 / 8)
ctx.addClock("pclk_v", 74.25)       # HDMI pixel clock (720p60)
ctx.addClock("core.rx_clk", 60)     # camera PCLK as nextpnr names it (~46 MHz in RGB565)
ctx.addClock("dclk", 94.5)         # DDR3 controller + PHY (CK), second rPLL

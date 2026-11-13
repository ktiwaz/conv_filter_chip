# Tang Primer 20K port (open-source flow)

The single-FPGA testbench on a Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7, dock board), built with yosys, nextpnr-himbaechel, apycula and openFPGALoader. Two bitstreams:

- **Tester** (`tp20k_top`): input RAM → sequencer → `conv_filter_top` → capture RAM. The PC drives it over the debugger's USB UART instead of Vivado's JTAG-to-AXI.
- **Camera pipeline** (`tp20k_cam_top`): an OV3660 on the dock's DVP connector feeds the DUT live. HDMI at 720p shows a colour preview of the camera (384×384, through the core board's DDR3) next to the filtered 128×128 DUT output, as in the PYNQ build's HDMI-in live mode. It runs standalone: after reset the FPGA configures the camera and starts live mode by itself, so with the bitstream in SPI flash (`make flash-cam`) no PC is needed. The tester commands work on this bitstream too.

```
PC (scripts/tb_host.py, cam_host.py) ──USB UART──▶ dbg_bridge ──AXI4──▶ fpga_tb_core
                                                      │ GPIO: status, manual camera control
sccb_init + register ROM ──SCCB──▶ OV3660 (at reset)
OV3660 ──DVP RGB565──▶ pix565 ─┬▶ grabber (luma, 3x3 average → 128x128) ──▶ DUT run per frame ──▶ output RAM ─┐
                               └▶ preview_wr ──▶ DDR3 (3 frame banks) ──▶ preview_rd (line buffer) ─┤
                                                                       cam_compositor ──▶ TMDS ──▶ HDMI 720p
DDR3: gowin-ddr3 controller + PHY ◀── ddr_arb ◀── preview reader / preview writer / bridge window (0x1000_0000)
```

The external-DUT link pins are not brought out on either bitstream.

## Tools
- **Place and route (built locally):** nextpnr-himbaechel and apycula (`gowin_pack`) come from the submodules `../third_party/nextpnr` and `../third_party/apicula`, pinned to known-good commits. The Makefile uses only these, built into `tools/` by `tools/setup.sh` (about a minute). apycula's chip databases come from Gowin's vendor tools, so the two this board needs are committed in `tools/chipdb/`; its README says where they come from and how to refresh them. Gowin EDA isn't needed.
  ```
  git submodule update --init      # once, from the repository root
  tools/setup.sh                   # needs cmake, a C++17 compiler, Boost, Eigen3, Python headers
  ```
  The pinned apicula includes two fixes not in release 0.35: true-LVDS banks no longer turn every single-ended pin into `LVDS25` ([#576](https://github.com/YosysHQ/apicula/issues/576); this killed the camera build's 27 MHz clock), and the IO-logic routing fix ([#565](https://github.com/YosysHQ/apicula/pull/565)) that DDR3 PHYs with IODELAY need.
- **From PATH:** yosys, openFPGALoader, and sv2v (the chip RTL uses unpacked-array ports, which yosys's own parser rejects).
- **Simulation:** Icarus Verilog.
- **Host scripts:** pyserial, in `../.venv`:
  ```
  python -m venv ../.venv && ../.venv/bin/pip install pyserial
  ```
- **Optional, Gowin EDA Education Edition** (free, no license) for the cross-check build and flash programming, unpacked in `~/.local/Gowin_EDA` (or set `GOWIN_HOME`).

## Usage
Tester:
```
make bit                 # build/tp20k.fs
make program             # SRAM; `make flash` writes the SPI flash
make sim                 # UART-level simulation incl. two golden testcases (~3 min)
make host-test           # on the board: selftest + all 5x5 testcases
```

Camera pipeline:
```
make bit-cam             # build/cam.fs (~3 min; prints utilisation and Fmax)
make program-cam         # SRAM
make flash-cam-gowin     # SPI flash, boots standalone (see "Writing the SPI flash")
make sim-sccb            # camera init engine + register ROM vs an SCCB monitor
make sim-grab            # grabber in the camera configuration vs a reference model
make sim-tmds            # TMDS encoder vs a reference decoder
make sim-ddrarb          # DDR3 arbiter + bridge window vs a model of the controller
make sim-pvwr            # RGB565 capture + preview writer vs a synthetic camera
make sim-pvrd            # preview reader vs a 720p scan, DDR side out of reset late
make sim-ddrsys          # preview writer + bridge window + reader traffic on one arbiter
```
The camera comes up and live mode starts about 50 ms after configuration or a press of S0. The host script is optional:
```
# from the testbench root (one level up):
.venv/bin/python scripts/cam_host.py status     # init result, frame size / rate, runs per second
.venv/bin/python scripts/cam_host.py grab out.png     # the DUT's 128x128 input (luma)
.venv/bin/python scripts/tb_host.py ddr-test       # DDR3 through the bridge window
.venv/bin/python scripts/cam_host.py live off   # stop live mode (also the automatic one); `live on`
.venv/bin/python scripts/cam_host.py reg 4300   # read a sensor register (PC takes the camera pins)
.venv/bin/python scripts/cam_host.py init       # PC-side init from the register file (~3 s)
.venv/bin/python scripts/cam_host.py auto       # pins back to the FPGA; S0 reruns its init
```

Host side:
```
.venv/bin/python scripts/tb_host.py run-testcase 5x5/emboss
.venv/bin/python scripts/tb_host.py shell       # t = Tester(...), interactive
```

On the camera bitstream, `tb_host.py` pauses live mode around each testcase and the selftest (live runs share the tester's input and capture RAMs) and restores it afterwards.

`tb_host.py` has the same commands as `tcl/hw_access.tcl`, minus the HDMI ones (`--help` lists them). Both scripts find the debugger's UART automatically (FT2232 interface B, usually `/dev/ttyUSB1`); pass `--port` to override.

Cross-check build of the camera design with Gowin's tools: `make bit-cam-gowin` / `make program-cam-gowin` (`gowin/cam.tcl`).

## Camera pipeline details
- **Clocks:** one `rPLL` makes 371.25 MHz (27 × 55 / 4) for the HDMI serializers. `CLKDIV` /5 gives the 74.25 MHz pixel clock (exact 720p60), and the PLL's `CLKOUTD` /8 gives the 46.41 MHz fabric clock. The camera's XCLK is fabric/2 (23.2 MHz), its PCLK about 46 MHz. The second `rPLL` makes the 94.5 MHz DDR3 clock (27 × 7 / 2).
- **Camera:** OV3660, 384×384 RGB565 from the sensor's 1:1 window at about 29 fps. The register list is `cam/ov3660_384sq_rgb565.txt` (`cam/ov3660_384sq_y8.txt` is the grayscale variant), derived from Espressif esp32-camera (Apache-2.0). Two fixes against that source: the ISP Y offset `3813` is 3 (esp32-camera's 6, halved for binning), which puts the demosaic on the right Bayer phase; and the gamma curve has all 16 points (`5480`–`548f`). With the wrong phase the colours came out as rainbow speckle, and with half the gamma points bright areas wrapped around in hue.
- **DDR3:** the core board's 1 Gbit x16 chip, through [gowin-ddr3](https://github.com/e-karge/gowin-ddr3) (submodule, Apache-2.0) with its fast 2:1 PHY, plus two patches in `ddr3/`: `ddr3_ctrl.patch` adds whole-burst writes (16 bytes per access instead of one 16-bit word; 70 MB/s write, 58 MB/s read measured at 108 MHz with `ddrtest/`), and `ddr3_phy_2to1.patch` holds the write data instead of a 9-stage pipeline (about 1,150 fewer flip-flops; this controller has one access in flight). The patched copies go to `build/ddr3/`, ahead of the submodule on the include path. `rtl/ddr3_sys.sv` wraps controller, PHY and PLL; `rtl/ddr_arb.v` schedules whole-burst accesses by fixed priority (preview reader, preview writer, bridge window) and refreshes every 7.8 µs. The preview needs about 27 MB/s.
- **Colour preview:** `rtl/pix565.v` assembles RGB565 pixels on PCLK; `rtl/preview_wr.v` packs them into 8-pixel bursts through a dual-clock FIFO into one of three frame banks (never the newest complete one or the displayed one); `rtl/preview_rd.v` prefetches source lines into a 4-line buffer ahead of the scan-out; `rtl/cam_compositor.v` shows them 1.5x (576×576) beside the DUT output. Layout in DDR3: bank b, line y at byte `0x1000_0000 + 16 × (b × 0x8000 + y × 64)`, 768 bytes per line.
- **Camera init:** `scripts/gen_cam_rom.py` turns the register list into `build/cam_init_rom.v` (one 32-bit entry per write or delay). After reset, `rtl/sccb_init.v` sequences PWDN and RESET (10 ms, 5 ms, then 30 ms before the first access), writes every entry over SCCB at 100 kHz and sets `done`; live mode then turns on unless the PC has turned it off. NACKs are counted, not retried: with no camera, init still finishes and `cam_host.py status` reports the NACKs. The same register file also works from the PC (`cam_host.py init`, bit-banged through the bridge's GPIO).
- **Grabber:** `video_downscale` with `SCALE=3`, `BANKS=1` and `PIX_CE=1` (a pixel every other PCLK): luminance of the whole 384×384 frame averaged 3×3 into the DUT's 128×128 input.
- **Display:** `video_frame` (`BANKS=1`) for the DUT output, `rtl/cam_compositor.v`, and `rtl/hdmi_tx_gowin.v` (TMDS encoders + `OSER10` + `TLVDS_OBUF`).
- **Block RAM:** 35 of 46: tester input and capture RAMs 16, grabber 8, DUT output display 8, preview FIFO 1, line buffer 2.
- **GPIO** (`0xF000_0000`; reset value 0 = automatic init and live mode):
  - **Out:** bit 0 PWDN, 1 release reset, 2/3 SCL/SDA low (bits 0–3 apply only with bit 6), 4 invert HREF, 5 live mode on, 6 MANUAL (PC drives the camera pins instead of `sccb_init`), 7 no automatic live mode.
  - **Out (more):** bit 8 freezes the preview writer, so the newest frame can be read from DDR3 undisturbed.
  - **In:** bits 3:0 SCL/SDA/VSYNC/HREF, 4 a preview frame exists, 11:8 filter preset, 12 DDR3 calibrated, 13 DDR3 calibration failed, 15:14 newest preview bank, 23:16 the outputs read back, 31 init done, 30:24 init NACKs (saturating at 127).
- **Utilisation:** about 9.7k LUT4 (46%), 10.0k FF (64%), 2.2k ALU, 32 LUT-RAM sites, both rPLLs. Flip-flops are the tight resource: at about 69% the placer couldn't legalise. The DUT's line buffer alone is 4.2k flip-flops (a shift register in the chip RTL).
- **Timing:** 10 of 10 placement seeds meet every clock. Worst cases: pixel clock 97.9 MHz against 74.25, DDR3 105 MHz against 94.5, fabric 64.9 MHz against 46.4. At 108 MHz (gowin-ddr3's example clock) the DDR3 clock's margin was thin, so it runs at 94.5 MHz.
- **Synthesis:** two-step `synth_gowin`. Memories without a `ram_style` (the font and preset ROMs) go to logic, because in block RAM their short address paths fail nextpnr's hold check.
- **Tried and dropped:** `synth_gowin -retime` raised the pixel clock to 91–98 MHz but **broke the design** on hardware (control state wrong after reset; 8 of 9 golden testcases failed). nextpnr's router2, timing-driven rip-up and heap timing weights gave no gain; the `static` and `sa` placers are unsupported or crash on this architecture; `--threads` without `--parallel-refine` changes nothing.

## Details
- **Tester clock:** `rPLL` to 48 MHz (27 × 16 / 9), which divides evenly into 1 and 3 Mbaud. The external link runs at 24/H MHz, and each sample-phase step is 20.8 ns.
- **Baud rate:** 1 Mbaud by default (`make BAUD=3000000 bit`). Pass the same `--baud` to the host scripts.
- **Bridge protocol (dbg_bridge):**
  - A request is `0x10` (write) or `0x11` (read), then a length in bytes (1–255), then the address as 4 bytes big-endian, then the data little-endian.
  - Writes get no response, so the host checks results by reading back.
  - The bridge has registers of its own at `0xF000_0000` (GPIO) and `0xF000_0004` (status: `0xCAFE....`).
- **Resync:** after a lost byte the bridge can sit in the middle of a request. On connect, the host sends 260 zero bytes, which complete any partial request and are ignored by an idle bridge.
- **Debugger quirk:** the first open of the UART after openFPGALoader has used the debugger passes no data. The host scripts close and reopen it automatically.
- **I/O banks:** banks 0, 1 and 2 run at 3.3 V on this board. Every single-ended pin is `LVCMOS33`, including camera pins: Sipeed's camera example says `LVCMOS25`, but the banks are shared with 3.3 V pins. The HDMI pins are true-LVDS pairs: `TLVDS_OBUF` with the default IO type, and `_p` and `_n` constrained separately (Sipeed's `"P,N"` syntax makes nextpnr swap the legs).
- **Camera flex cable:** it fits both ways but works in only one; the reversed orientation browned the board out. `scripts/camcheck.py` with `camcheck/` reads the chip ID and is a safe first check.
- **LEDs and buttons** (both active low):
  - Tester: led0 heartbeat, led1 run done, led2–led5 filter preset.
  - Camera build: led0 heartbeat, led1 live, led2–led5 preset. With `DEBUG_LEDS=1`: PLL lock, resets and a raw 27 MHz reference blink.
  - Buttons: S0 (pin T10) is reset; S1 (T3) and S2 (T2) step to the next and previous preset.
- **Capture RAM is read-only over UART** (`CAP_AXI_WR=0`), and the input RAM takes whole-word writes (`IN_BYTE_WE=0`). Gowin block RAM can't combine byte-enabled writes with reads on one port, or write with byte enables on both ports.
- **Writing the SPI flash:** `make flash` / `make flash-cam` (openFPGALoader) stall at 7–12% with `ftdi_read_data in mpsse_read` on dense bitstreams such as `cam.fs` and `tp20k.fs`; a near-empty blinky writes fine. The cause is the dock's BL702 debugger firmware (an FT2232 clone), not the board or flash: [openFPGALoader#573](https://github.com/trabucayre/openFPGALoader/issues/573), still open; the workaround reported there is a 128-byte flash page size in openFPGALoader. A stalled write leaves the debugger hung until a power cycle. What works: `make flash-cam-gowin` (Gowin's `programmer_cli`, ~45 s), after detaching the kernel's serial driver from both debugger interfaces (`1-3` is the USB path, see `ls /sys/bus/usb/drivers/ftdi_sio/`):
  ```
  echo -n 1-3:1.0 | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind
  echo -n 1-3:1.1 | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind
  ```
  It reported "SPI Verify failed!", yet the board booted from that flash and ran correctly; the read-back goes through the same debugger. Replug afterwards to get the UART back. Make sure no earlier `programmer_cli` is still running: a leftover one holds the USB device and the next run hangs silently.
- **Loading SRAM:** erasing SRAM over JTAG hangs while the camera + DDR3 bitstream is running (the status stays in configuration-edit mode and MEMORY_ERASE never sets) until a power cycle; over every other design, the standalone DDR3 test included, it works. `make program` / `make program-cam` therefore first reconfigure from flash over JTAG (`openFPGALoader --reset`), then load.
- **Gowin EDA builds:** not yet updated for DDR3 (`gowin/cam.tcl` lacks the DDR3 sources). `gowin/cam.tcl` turns off the bitstream security bit. With it on, openFPGALoader can't erase or reload SRAM until a power cycle. `gw_sh` needs `LD_PRELOAD=/usr/lib/libfreetype.so.6` and `QT_QPA_PLATFORM=minimal` (the Makefile sets both).

## Directory
| Path | Contents |
|---|---|
| `tp20k_top.v`, `tp20k.cst` | tester |
| `tp20k_cam_top.v`, `tp20k_cam.cst`, `cam_clocks.py` | camera pipeline (`cam_clocks.py`: per-clock timing targets for nextpnr) |
| `rtl/` | `hdmi_tx_gowin.v`, `tmds_encoder.v`, `sccb_init.v`; DDR3: `ddr3_sys.sv`, `ddr_arb.v`, `axi_ddr.v`, `async_fifo.v`; preview: `pix565.v`, `preview_wr.v`, `preview_rd.v`, `cam_compositor.v` |
| `ddr3/` | our patches to gowin-ddr3 |
| `ddrtest/` | DDR3 burst memory test and throughput report (UART, 115200), built by hand |
| `cam/` | OV3660 register lists (RGB565, Y8) |
| `sim/` | `tb_tp20k.sv` (tester over UART), `tb_cam_grab.sv`, `tb_tmds.sv`, `tb_sccb_init.sv`, `tb_ddr_arb.sv`, `tb_preview_wr.sv`, `tb_preview_rd.sv`, `tb_ddr_sys.sv` |
| `gowin/` | Gowin EDA cross-check build |
| `tools/` | `setup.sh` (local nextpnr + apycula), `chipdb/` |
| `camcheck/` | camera connection check bitstream (with `scripts/camcheck.py`), built by hand |
| `hdmitest/` | 640×480 and 720p HDMI test patterns, built by hand |

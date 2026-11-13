# Tang Primer 20K port (open-source flow)

The single-FPGA testbench on a Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7, dock board), built with yosys, nextpnr-himbaechel, apycula and openFPGALoader only. Two bitstreams:

- **Tester** (`tp20k_top`): input RAM → sequencer → `conv_filter_top` → capture RAM. The PC drives it over the debugger's USB UART instead of Vivado's JTAG-to-AXI.
- **Camera pipeline** (`tp20k_cam_top`): an OV3660 on the dock's DVP connector feeds the DUT live. HDMI at 720p shows a colour preview of the camera (384×384, through the core board's DDR3) next to the filtered 128×128 DUT output, as in the PYNQ build's HDMI-in live mode. The output is in colour for presets where that makes sense: the DUT runs once per channel (R, G, B) per frame. Edge detectors run once on luminance and show gray. It runs standalone: after reset the FPGA configures the camera and starts live mode by itself, so with the bitstream in SPI flash (`make flash-cam`) no PC is needed. The tester commands work on this bitstream too.

```
PC (scripts/tb_host.py, cam_host.py) ──USB UART──▶ dbg_bridge ──AXI4──▶ fpga_tb_core (LIVE_EXT)
                                                      │ GPIO: status, colour mode, manual camera control
sccb_init + register ROM ──SCCB──▶ OV3660 (at reset)
OV3660 ──DVP RGB565──▶ pix565 ─┬▶ rgb_grab (3x3 average → 128x128 R,G,B,Y) ──▶ DDR3 (2 banks)
                               └▶ preview_wr ──▶ DDR3 (3 frame banks)
color_live, per frame: per channel  plane_dma (DDR3 → plane RAM) ──▶ DUT run ──▶ color_frame (R,G,B planes) ─┐
preview_rd (DDR3 → line buffer) ───────────────────────────────────────────────────────────────────────────┤
                                                                       cam_compositor ──▶ TMDS ──▶ HDMI 720p
DDR3: gowin-ddr3 controller + PHY ◀── ddr_arb ◀── preview_rd / preview_wr / bridge window (0x1000_0000) / rgb_grab / plane_dma
```

The external-DUT link pins are not brought out on either bitstream.

## Tools
Everything except yosys and sv2v is built from submodules pinned to known-good commits. The Makefile uses only these copies, not ones on PATH.

- **Built locally:** nextpnr-himbaechel, apycula (`gowin_pack`) and openFPGALoader, from the submodules `../third_party/nextpnr`, `../third_party/apicula` and `../third_party/openFPGALoader`. `tools/setup.sh` builds them into `tools/` (a few minutes):
  ```
  git submodule update --init      # once, from the repository root
  tools/setup.sh                   # needs cmake, a C++17 compiler, Boost, Eigen3, Python headers; libftdi1, libusb-1.0, hidapi, zlib, pkg-config
  ```
  - **Parallel jobs:** `setup.sh` runs one compile job per 2 GB of available memory (capped at the core count). nextpnr's compile units peak at well over 1 GB each, and one job per core ran a 32 GB machine out of memory. Override with `JOBS=n tools/setup.sh`.
  - **apycula's chip databases:** these come from Gowin's vendor tools, so the two this board needs are committed in `tools/chipdb/`. Its README says where they come from and how to refresh them.
  - **apicula fixes:** the pinned apicula includes two fixes not in release 0.35:
    - True-LVDS banks no longer turn every single-ended pin into `LVDS25` ([#576](https://github.com/YosysHQ/apicula/issues/576)). This killed the camera build's 27 MHz clock.
    - The IO-logic routing fix ([#565](https://github.com/YosysHQ/apicula/pull/565)), which DDR3 PHYs with IODELAY need.
  - **openFPGALoader flash patch:** `setup.sh` applies `tools/openfpgaloader.patch` for the build and reverts it afterwards, so the submodule stays clean. The patch writes the SPI flash in 128-byte chunks instead of 256-byte pages. See "Writing the SPI flash" for why.
- **From PATH:** yosys, and sv2v (the chip RTL uses unpacked-array ports, which yosys's own parser rejects).
- **Simulation:** Icarus Verilog.
- **Host scripts:** pyserial, in `../.venv`:
  ```
  python -m venv ../.venv && ../.venv/bin/pip install pyserial
  ```

Gowin EDA is not used or supported. It served once as a cross-check build and as the interim flash programmer (see "Writing the SPI flash").

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
make flash-cam           # SPI flash with verify (~45 s), boots standalone
make sim-sccb            # camera init engine + register ROM vs an SCCB monitor
make sim-cgrab           # colour grabber + plane DMA vs a reference model
make sim-tmds            # TMDS encoder vs a reference decoder
make sim-ddrarb          # DDR3 arbiter + bridge window vs a model of the controller
make sim-pvwr            # RGB565 capture + preview writer vs a synthetic camera
make sim-pvrd            # preview reader vs a 720p scan, DDR side out of reset late
make sim-ddrsys          # all five DDR3 ports at realistic rates on one arbiter
make sim-grab            # shared video_downscale (PYNQ grabber) with a pixel enable
```
The camera comes up and live mode starts about 50 ms after configuration or a press of S0. The host script is optional:
```
# from the testbench root (one level up):
.venv/bin/python scripts/cam_host.py status     # init result, frame size / rate, runs per second, colour mode
.venv/bin/python scripts/cam_host.py grab out.png     # the DUT's 128x128 input (luma)
.venv/bin/python scripts/cam_host.py color gray # DUT output: auto (per preset) | gray | on
.venv/bin/python scripts/tb_host.py ddr-test       # DDR3 through the bridge window (see Known issues)
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

On the camera bitstream, `tb_host.py` pauses live mode around each testcase and the selftest, and restores it afterwards. Live runs share the tester's capture RAM and sequencer.

`tb_host.py` has the same commands as `tcl/hw_access.tcl`, minus the HDMI ones (`--help` lists them). Both scripts find the debugger's UART automatically (FT2232 interface B, usually `/dev/ttyUSB1`); pass `--port` to override.

## Camera pipeline details

### Clocks
- One `rPLL` makes 371.25 MHz (27 × 55 / 4) for the HDMI serializers.
  - `CLKDIV` /5 gives the 74.25 MHz pixel clock (exact 720p60).
  - The PLL's `CLKOUTD` /8 gives the 46.41 MHz fabric clock.
- The camera's XCLK is fabric/2 (23.2 MHz). Its PCLK is about 46 MHz.
- The second `rPLL` makes the 94.5 MHz DDR3 clock (27 × 7 / 2).

### Camera
- OV3660, 384×384 RGB565 from the sensor's 1:1 window at about 29 fps.
- The register list is `cam/ov3660_384sq_rgb565.txt`; `cam/ov3660_384sq_y8.txt` is the grayscale variant. Both are derived from Espressif esp32-camera (Apache-2.0).
- Two fixes against that source:
  - The ISP Y offset `3813` is 3 (esp32-camera's 6, halved for binning). This puts the demosaic on the right Bayer phase; with the wrong phase the colours came out as rainbow speckle.
  - The gamma curve has all 16 points (`5480`–`548f`). With half of them, bright areas wrapped around in hue.
- White balance is the sensor's automatic one and not yet tuned.

### Camera init
- `scripts/gen_cam_rom.py` turns the register list into `build/cam_init_rom.v`: one 32-bit entry per write or delay, in logic (in block RAM its short paths failed the hold check).
- After reset, `rtl/sccb_init.v` sequences PWDN and RESET (10 ms, 5 ms, then 30 ms before the first access), writes every entry over SCCB at 100 kHz and sets `done`. Live mode then turns on unless the PC has turned it off.
- NACKs are counted, not retried: with no camera, init still finishes and `cam_host.py status` reports the NACKs.
- The same register file also works from the PC (`cam_host.py init`, bit-banged through the bridge's GPIO).

### DDR3
- **Memory and controller:** the core board's 1 Gbit x16 chip, through [gowin-ddr3](https://github.com/e-karge/gowin-ddr3) (submodule, Apache-2.0) with its fast 2:1 PHY.
- **Our patches,** in `ddr3/`:
  - `ddr3_ctrl.patch` adds whole-burst writes: 16 bytes per access instead of one 16-bit word. `ddrtest/` measured 70 MB/s write and 58 MB/s read at 108 MHz.
  - `ddr3_phy_2to1.patch` holds the write data instead of a 9-stage pipeline. This saves about 1,150 flip-flops; this controller has one access in flight.

  The patched copies go to `build/ddr3/`, ahead of the submodule on the include path.
- **Our RTL:**
  - `rtl/ddr3_sys.sv` wraps the controller, PHY and PLL.
  - `rtl/ddr_arb.v` schedules whole-burst accesses by fixed priority and refreshes every 7.8 µs. The ports, highest priority first:
    1. preview reader
    2. preview writer
    3. bridge window
    4. rgb_grab
    5. plane_dma

  The window sits above the DMA because otherwise a busy DMA starved it until the bridge hung.
- **Bandwidth:** the preview needs about 27 MB/s. The colour path adds about 2 MB/s of grab writes and 3 bursty plane reads per frame.
- **Layout** (byte address over the bridge = `0x1000_0000 + 16 × burst`):

  | Bursts | Contents |
  |---|---|
  | `b × 0x8000 + y × 64 + x` (b = 0–2) | preview frame banks: 384×384 RGB565, 8 pixels per burst |
  | `0x20000 + b × 0x1000 + n / 4` (b = 0–1) | grabbed 128×128 frames: 4 pixels per burst, bytes R, G, B, Y per pixel |
- **Bridge window** (`rtl/axi_ddr.v`): writes are read-modify-write of whole bursts, so it needs no data mask. A request the arbiter doesn't serve within 2^21 DDR cycles (22 ms) is abandoned and sets GPIO in bit 6, so the bridge can't hang.

### Colour preview
- `rtl/pix565.v` assembles RGB565 pixels on PCLK.
- `rtl/preview_wr.v` packs them into 8-pixel bursts through a dual-clock FIFO. It writes into one of three frame banks: never the newest complete one, and never the one being displayed.
- `rtl/preview_rd.v` prefetches source lines into a 4-line buffer ahead of the scan-out.
- `rtl/cam_compositor.v` shows them at 1.5× (576×576) beside the DUT output.

### Colour DUT output
- **Grab:** `rtl/rgb_grab.v` averages the camera frame 3×3 into 128×128 R, G, B and Y. Y uses the BT.709 weights of `video_downscale`. The frame goes into one of two DDR3 banks; the column accumulators sit in one block RAM.
- **Runs per frame:** `rtl/color_live.v` handles each completed frame while live mode is on.
  - Colour frames get three runs, one per channel (R, G, B). Gray frames get one run on Y.
  - Before each run, `rtl/plane_dma.v` copies that channel from DDR3 into a 4096×32 plane RAM.
  - `fpga_tb_core` (`LIVE_EXT=1`) then runs the DUT on the plane RAM instead of its internal grabber.
  - A frame that arrives while the previous one is still running is dropped, as before.
- **Display buffer:** `rtl/color_frame.v` holds the output as 5 bits per channel, in fifteen 16K×1 block RAMs. A gray run writes all three channels.
- **Timing:** three runs take about 1.1 ms of a 34 ms frame.
- **Colour or gray:**
  - By default, the preset's flag from `scripts/gen_kernel_rom.py` (`kernel_color`) decides. Outline, sobel_x and sobel_y are gray; everything else, custom kernels included, is colour.
  - GPIO out bits 10:9 override it (`cam_host.py color gray|on|auto`).
  - The overlay shows COLOR or GRAY.
- **Grab command:** `cam_host.py grab` forces gray for its readout, so it still returns the luma input.

### Display
- `rtl/cam_compositor.v` produces the frame:
  - preview 576×576 at (48, 80)
  - output 512×512 at (704, 112)
  - titles and status text
- `rtl/hdmi_tx_gowin.v` drives HDMI: TMDS encoders, `OSER10` and `TLVDS_OBUF`.

### GPIO
The bridge GPIO is at `0xF000_0000`. Its reset value 0 means automatic init and live mode.

**Out:**
| Bit | Function |
|---|---|
| 0 | PWDN |
| 1 | release reset |
| 2, 3 | SCL / SDA low |
| 4 | invert HREF |
| 5 | live mode on |
| 6 | MANUAL: the PC drives the camera pins instead of `sccb_init` |
| 7 | no automatic live mode |
| 8 | freeze the preview writer (read a frame from DDR3 undisturbed) |
| 10:9 | DUT output: 00 per preset, 01 gray, 10 colour |

Bits 0–3 apply only when bit 6 is set.

**In:**
| Bit | Function |
|---|---|
| 3:0 | SCL / SDA / VSYNC / HREF |
| 4 | a preview frame exists |
| 5 | the output shown is colour |
| 6 | the bridge window abandoned a request |
| 11:8 | filter preset |
| 12 | DDR3 calibrated |
| 13 | DDR3 calibration failed |
| 15:14 | newest preview bank |
| 27:16 | out bits 11:0 read back |
| 30:28 | init NACKs (7 = seven or more) |
| 31 | init done |

### Utilisation (seed 1)
| Resource | Used | Share |
|---|---|---|
| LUT4 | 10.1k | 48% |
| ALU | 2.4k | 15% |
| FF | 10.0k | 64% |
| BSRAM | 44 of 46 | 95% |
| MULT18X18 | 11 | 22% |
| MULT9X9 | 37 | 38% |
| rPLL | 2 | 100% |

- **Flip-flops are the tight resource:** at about 66–69% the placer couldn't legalise. The DUT's line buffer alone is 4.4k flip-flops (a shift register in the chip RTL).
- **Block RAM:**
  - tester input and capture RAMs: 16
  - plane RAM: 8
  - output display (`color_frame`): 15
  - preview FIFO: 1
  - preview line buffer: 2
  - grab accumulator: 1
  - grab FIFO: 1

### Timing
- 10 of 10 placement seeds meet every clock. Worst cases over the seeds: pixel clock 83.1 MHz against 74.25, DDR3 107 MHz against 94.5, fabric 63.7 MHz against 46.4.
- At 108 MHz (gowin-ddr3's example clock) the DDR3 clock's margin was thin, so it runs at 94.5 MHz.

### Synthesis
- Two-step `synth_gowin`.
- Memories without a `ram_style` (the font and preset ROMs) go to logic, because in block RAM their short address paths fail nextpnr's hold check.

### Tried and dropped
- `synth_gowin -retime` raised the pixel clock to 91–98 MHz but **broke the design** on hardware: control state was wrong after reset, and 8 of 9 golden testcases failed.
- nextpnr's router2, timing-driven rip-up and heap timing weights gave no gain.
- The `static` and `sa` placers are unsupported or crash on this architecture.
- `--threads` without `--parallel-refine` changes nothing.

## Known issues
- **Rare DDR3 write corruption:** about one byte in 30 KB written through the bridge window comes back wrong, and only while the preview writer is running. The signature is always the same: byte 0 of a 16-bit beat takes the value of byte 0 of the next beat, on DQ lane 0 only. `tb_host.py ddr-test` therefore reports FAIL on this bitstream.
  - The same signature appears with full-burst writes (no data mask), so it isn't the mask path.
  - It doesn't reproduce in simulation (`sim-ddrsys`, all ports at full rate).
  - It does not show visibly in the preview. A bit-level PHY or board timing issue is suspected but unconfirmed.
  - The standalone `ddrtest/` passes.
- **Loading SRAM over the running camera bitstream hangs** (see "Loading SRAM"). This is worked around in the Makefile.

## Details
- **Tester clock:** `rPLL` to 48 MHz (27 × 16 / 9), which divides evenly into 1 and 3 Mbaud. The external link runs at 24/H MHz, and each sample-phase step is 20.8 ns.
- **Baud rate:** 1 Mbaud by default (`make BAUD=3000000 bit`). Pass the same `--baud` to the host scripts.
- **Bridge protocol (dbg_bridge):**
  - A request is `0x10` (write) or `0x11` (read), then a length in bytes (1–255), then the address as 4 bytes big-endian, then the data little-endian.
  - Writes get no response, so the host checks results by reading back.
  - The bridge has registers of its own at `0xF000_0000` (GPIO) and `0xF000_0004` (status: `0xCAFE....`).
- **Resync:** after a lost byte the bridge can sit in the middle of a request. On connect, the host sends 260 zero bytes, which complete any partial request and are ignored by an idle bridge.
- **Debugger quirk:** the first open of the UART after openFPGALoader has used the debugger passes no data. The host scripts close and reopen it automatically.
- **I/O banks:** banks 0, 1 and 2 run at 3.3 V on this board.
  - Every single-ended pin is `LVCMOS33`, including the camera pins. Sipeed's camera example says `LVCMOS25`, but the banks are shared with 3.3 V pins.
  - The HDMI pins are true-LVDS pairs: `TLVDS_OBUF` with the default IO type, and `_p` and `_n` constrained separately. Sipeed's `"P,N"` syntax makes nextpnr swap the legs.
- **Camera flex cable:** it fits both ways but works in only one; the reversed orientation browned the board out. `scripts/camcheck.py` with `camcheck/` reads the chip ID and is a safe first check.
- **LEDs and buttons** (both active low):
  - Tester: led0 heartbeat, led1 run done, led2–led5 filter preset.
  - Camera build: led0 heartbeat, led1 live, led2–led5 preset. With `DEBUG_LEDS=1`: PLL lock, resets and a raw 27 MHz reference blink.
  - Buttons: S0 (pin T10) is reset; S1 (T3) and S2 (T2) step to the next and previous preset.
- **Capture RAM is read-only over UART** (`CAP_AXI_WR=0`), and the input RAM takes whole-word writes (`IN_BYTE_WE=0`). Gowin block RAM can't combine byte-enabled writes with reads on one port, or write with byte enables on both ports.
- **Writing the SPI flash:** `make flash` / `make flash-cam` write and verify the flash with our patched openFPGALoader (about 45 s for `cam.fs`).
  - **The problem:** stock openFPGALoader stalls at 7–12% with `ftdi_read_data in mpsse_read` on dense bitstreams such as `cam.fs` and `tp20k.fs`; a near-empty blinky writes fine. The stalled write leaves the debugger hung until a power cycle.
  - **The cause:** the dock's BL702 debugger firmware (an FT2232 emulation) can't keep up with 256-byte page writes. The board and flash are fine. This is [openFPGALoader#573](https://github.com/trabucayre/openFPGALoader/issues/573), still open upstream.
  - **The workaround:** the one reported in that issue. `tools/openfpgaloader.patch` writes 128 bytes per page-program command, and with it flashing and verifying `cam.fs` works every time.
  - **Why openFPGALoader is built here:** to carry this patch. Before it, we flashed with Gowin EDA's `programmer_cli`. That needed the kernel's `ftdi_sio` driver detached from the debugger, reported a spurious verify failure, and hung silently if an earlier instance was still running. With the patched loader, Gowin EDA was dropped from this repo entirely.
- **Loading SRAM:** erasing SRAM over JTAG hangs while the camera + DDR3 bitstream is running. The status stays in configuration-edit mode and MEMORY_ERASE never sets, until a power cycle. Over every other design, the standalone DDR3 test included, it works.
  - `make program`, `make program-cam` and the flash targets therefore first reconfigure from flash over JTAG (`openFPGALoader --reset`), wait 2 s, then load.
  - This also recovers a board already stuck in a hung erase.

## Directory
| Path | Contents |
|---|---|
| `tp20k_top.v`, `tp20k.cst` | tester |
| `tp20k_cam_top.v`, `tp20k_cam.cst`, `cam_clocks.py` | camera pipeline (`cam_clocks.py`: per-clock timing targets for nextpnr) |
| `rtl/` | `hdmi_tx_gowin.v`, `tmds_encoder.v`, `sccb_init.v`; DDR3: `ddr3_sys.sv`, `ddr_arb.v`, `axi_ddr.v`, `async_fifo.v`; preview: `pix565.v`, `preview_wr.v`, `preview_rd.v`, `cam_compositor.v`; colour output: `rgb_grab.v`, `plane_dma.v`, `color_live.v`, `color_frame.v` |
| `ddr3/` | our patches to gowin-ddr3 |
| `ddrtest/` | DDR3 burst memory test and throughput report (UART, 115200), built by hand |
| `cam/` | OV3660 register lists (RGB565, Y8) |
| `sim/` | `tb_tp20k.sv` (tester over UART), `tb_cam_grab.sv`, `tb_color_grab.sv`, `tb_tmds.sv`, `tb_sccb_init.sv`, `tb_ddr_arb.sv`, `tb_preview_wr.sv`, `tb_preview_rd.sv`, `tb_ddr_all.sv` |
| `tools/` | `setup.sh` (local nextpnr, apycula, openFPGALoader), `openfpgaloader.patch`, `chipdb/` |
| `camcheck/` | camera connection check bitstream (with `scripts/camcheck.py`), built by hand |
| `hdmitest/` | 640×480 and 720p HDMI test patterns, built by hand |

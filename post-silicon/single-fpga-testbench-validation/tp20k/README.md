# Tang Primer 20K port (open-source flow)

The single-FPGA testbench on a Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7, dock board), built with yosys, nextpnr-himbaechel, apycula and openFPGALoader. Two bitstreams:

- **Tester** (`tp20k_top`): input RAM → sequencer → `conv_filter_top` → capture RAM. The PC drives it over the debugger's USB UART instead of Vivado's JTAG-to-AXI.
- **Camera pipeline** (`tp20k_cam_top`): an OV3660 on the dock's DVP connector feeds the DUT live, and the input and filtered output are shown side by side on the HDMI port at 720p, as in the PYNQ build's HDMI-in live mode. It runs standalone: after reset the FPGA configures the camera and starts live mode by itself, so with the bitstream in SPI flash (`make flash-cam`) no PC is needed. The tester commands work on this bitstream too.

```
PC (scripts/tb_host.py, cam_host.py) ──USB UART──▶ dbg_bridge ──AXI4──▶ fpga_tb_core
                                                      │ GPIO: status, manual camera control
sccb_init + register ROM ──SCCB──▶ OV3660 (at reset)
OV3660 ──DVP──▶ grabber (3x3 average → 128x128) ──▶ DUT run per frame ──▶ display RAMs
                                                     video_compositor ──▶ TMDS ──▶ HDMI 720p
```

The external-DUT link pins are not brought out on either bitstream.

## Tools
- **FPGA flow:** yosys, nextpnr-himbaechel, apycula (`gowin_pack`) and openFPGALoader.
- **apycula fix (required for the camera build):** releases up to 0.35 configure every single-ended pin in a bank that has both true-LVDS outputs and an ordinary output as `LVDS25`. On the dock that kills the 27 MHz clock input, which shares a bank with the HDMI pairs. The fix is upstream ([YosysHQ/apicula#576](https://github.com/YosysHQ/apicula/issues/576), commit `993faec`) but not yet released. Until it is, delete this line under `if bank_desc.has_true_lvds_outputs:` in `check_io_banks()` of the installed `apycula/gowin_pack.py`:
  ```python
  bank_desc.set_attr("IO_TYPE", default_io_type)
  ```
  The pack rules refuse to run without the fix.
- **sv2v:** the chip RTL uses unpacked-array ports, which yosys's own parser rejects.
- **Simulation:** Icarus Verilog.
- **Host scripts:** pyserial, in `../.venv`:
  ```
  python -m venv ../.venv && ../.venv/bin/pip install pyserial
  ```
- **Optional, Gowin EDA Education Edition** (free, no license) for the cross-check build, unpacked in `~/.local/Gowin_EDA` (or set `GOWIN_HOME`).

The UART bridge is a submodule. After cloning, run `git submodule update --init`.

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
```
The camera comes up and live mode starts about 50 ms after configuration or a press of S0. The host script is optional:
```
# from the testbench root (one level up):
.venv/bin/python scripts/cam_host.py status     # init result, frame size / rate, runs per second
.venv/bin/python scripts/cam_host.py grab out.png
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
- **Clocks:** a single `rPLL` makes 371.25 MHz (27 × 55 / 4) for the HDMI serializers. `CLKDIV` /5 gives the 74.25 MHz pixel clock (exact 720p60), and the PLL's `CLKOUTD` /8 gives the 46.41 MHz fabric clock. The camera's XCLK is fabric/2 (23.2 MHz).
- **Camera:** OV3660, 384×384 Y8 (grayscale) from the sensor's 1:1 window at about 29 fps. The register list is `cam/ov3660_384sq_y8.txt`, derived from Espressif esp32-camera (Apache-2.0).
- **Camera init:** `scripts/gen_cam_rom.py` turns the register list into `build/cam_init_rom.v` (one 32-bit entry per write or delay). After reset, `rtl/sccb_init.v` sequences PWDN and RESET (10 ms, 5 ms, then 30 ms before the first access), writes every entry over SCCB at 100 kHz and sets `done`; live mode then turns on unless the PC has turned it off. NACKs are counted, not retried: with no camera, init still finishes and `cam_host.py status` reports the NACKs. The same register file also works from the PC (`cam_host.py init`, bit-banged through the bridge's GPIO).
- **Grabber:** `video_downscale` with `SCALE=3`, `BANKS=1`, `GRAY_IN=1`: the whole 384×384 frame averaged 3×3 into the DUT's 128×128 input.
- **Display:** `video_frame` with `BANKS=1` (single-buffered, may tear briefly), `video_compositor` (shared with the PYNQ build), and `rtl/hdmi_tx_gowin.v` (TMDS encoders + `OSER10` + `TLVDS_OBUF`).
- **Block RAM:** 40 of 46: tester input and capture RAMs 16, grabber 8, display buffers 16.
- **GPIO** (`0xF000_0000`; reset value 0 = automatic init and live mode):
  - **Out:** bit 0 PWDN, 1 release reset, 2/3 SCL/SDA low (bits 0–3 apply only with bit 6), 4 invert HREF, 5 live mode on, 6 MANUAL (PC drives the camera pins instead of `sccb_init`), 7 no automatic live mode.
  - **In:** bits 3:0 SCL/SDA/VSYNC/HREF, 11:8 filter preset, 23:16 the outputs read back, 31 init done, 30:24 init NACKs (saturating at 127).
- **Utilisation:** about 7.3k LUT4 (35%), 7.5k FF (48%), 32 LUT-RAM sites. The init ROM is about 0.7k LUT4 of that (logic, like the other ROMs).
- **Timing:** 10 of 10 placement seeds meet every clock. Worst cases: pixel clock 84.7 MHz against 74.25 (+14%), fabric 61.9 MHz against 46.4.
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
- **Gowin EDA builds:** `gowin/cam.tcl` turns off the bitstream security bit. With it on, openFPGALoader can't erase or reload SRAM until a power cycle. `gw_sh` needs `LD_PRELOAD=/usr/lib/libfreetype.so.6` and `QT_QPA_PLATFORM=minimal` (the Makefile sets both).

## Directory
| Path | Contents |
|---|---|
| `tp20k_top.v`, `tp20k.cst` | tester |
| `tp20k_cam_top.v`, `tp20k_cam.cst`, `cam_clocks.py` | camera pipeline (`cam_clocks.py`: per-clock timing targets for nextpnr) |
| `rtl/` | `hdmi_tx_gowin.v`, `tmds_encoder.v`, `sccb_init.v` |
| `cam/` | OV3660 register list |
| `sim/` | `tb_tp20k.sv` (tester over UART), `tb_cam_grab.sv`, `tb_tmds.sv`, `tb_sccb_init.sv` |
| `gowin/` | Gowin EDA cross-check build |
| `camcheck/` | camera connection check bitstream (with `scripts/camcheck.py`), built by hand |
| `hdmitest/` | 640×480 and 720p HDMI test patterns, built by hand |

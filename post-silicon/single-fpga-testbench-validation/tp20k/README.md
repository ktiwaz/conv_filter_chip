# Tang Primer 20K port (open-source flow)

The single-FPGA testbench on a Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7, dock board), built with yosys, nextpnr-himbaechel, apycula and openFPGALoader. Two bitstreams:

- **Tester** (`tp20k_top`): input RAM → sequencer → `conv_filter_top` → capture RAM. The PC drives it over the debugger's USB UART instead of Vivado's JTAG-to-AXI.
- **Camera pipeline** (`tp20k_cam_top`): an OV3660 on the dock's DVP connector feeds the DUT live, and the input and filtered output are shown side by side on the HDMI port at 720p, as in the PYNQ build's HDMI-in live mode. The tester commands work on this bitstream too.

```
PC (scripts/tb_host.py, cam_host.py) ──USB UART──▶ dbg_bridge ──AXI4──▶ fpga_tb_core
                                                      │ GPIO: camera power/reset, SCCB
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
make program-cam         # SRAM; `make flash-cam` writes the SPI flash
make sim-grab            # grabber in the camera configuration vs a reference model
make sim-tmds            # TMDS encoder vs a reference decoder

# from the testbench root (one level up):
.venv/bin/python scripts/cam_host.py init       # power up + configure the OV3660 (~3 s)
.venv/bin/python scripts/cam_host.py live on    # DUT on every frame, panes on HDMI
.venv/bin/python scripts/cam_host.py status     # frame size / rate, runs per second
.venv/bin/python scripts/cam_host.py grab out.png
```

Host side:
```
.venv/bin/python scripts/tb_host.py run-testcase 5x5/emboss
.venv/bin/python scripts/tb_host.py shell       # t = Tester(...), interactive
```

`tb_host.py` has the same commands as `tcl/hw_access.tcl`, minus the HDMI ones (`--help` lists them). Both scripts find the debugger's UART automatically (FT2232 interface B, usually `/dev/ttyUSB1`); pass `--port` to override.

Cross-check build of the camera design with Gowin's tools: `make bit-cam-gowin` / `make program-cam-gowin` (`gowin/cam.tcl`).

## Camera pipeline details
- **Clocks:** a single `rPLL` makes 371.25 MHz (27 × 55 / 4) for the HDMI serializers. `CLKDIV` /5 gives the 74.25 MHz pixel clock (exact 720p60), and the PLL's `CLKOUTD` /8 gives the 46.41 MHz fabric clock. The camera's XCLK is fabric/2 (23.2 MHz).
- **Camera:** OV3660, 384×384 Y8 (grayscale) from the sensor's 1:1 window at about 29 fps. The register list is `cam/ov3660_384sq_y8.txt`, derived from Espressif esp32-camera (Apache-2.0). `cam_host.py init` writes it over SCCB, bit-banged through the bridge's GPIO.
- **Grabber:** `video_downscale` with `SCALE=3`, `BANKS=1`, `GRAY_IN=1`: the whole 384×384 frame averaged 3×3 into the DUT's 128×128 input.
- **Display:** `video_frame` with `BANKS=1` (single-buffered, may tear briefly), `video_compositor` (shared with the PYNQ build), and `rtl/hdmi_tx_gowin.v` (TMDS encoders + `OSER10` + `TLVDS_OBUF`).
- **Block RAM:** 40 of 46: tester input and capture RAMs 16, grabber 8, display buffers 16.
- **GPIO** (`0xF000_0000`):
  - **Out:** bit 0 PWDN, 1 release reset, 2/3 SCL/SDA low, 4 invert HREF, 5 live mode.
  - **In:** bits 3:0 SCL/SDA/VSYNC/HREF, 11:8 filter preset, 23:16 the outputs read back.
- **Utilisation:** about 6.6k LUT4 (31%), 7.3k FF (47%), 32 LUT-RAM sites.
- **Timing:** 10 of 10 placement seeds meet every clock. Worst cases: pixel clock 85.6 MHz against 74.25 (+15%), fabric 60.4 MHz against 46.4.
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
- **Gowin EDA builds:** `gowin/cam.tcl` turns off the bitstream security bit. With it on, openFPGALoader can't erase or reload SRAM until a power cycle. `gw_sh` needs `LD_PRELOAD=/usr/lib/libfreetype.so.6` and `QT_QPA_PLATFORM=minimal` (the Makefile sets both).

## Directory
| Path | Contents |
|---|---|
| `tp20k_top.v`, `tp20k.cst` | tester |
| `tp20k_cam_top.v`, `tp20k_cam.cst`, `cam_clocks.py` | camera pipeline (`cam_clocks.py`: per-clock timing targets for nextpnr) |
| `rtl/` | `hdmi_tx_gowin.v`, `tmds_encoder.v` |
| `cam/` | OV3660 register list |
| `sim/` | `tb_tp20k.sv` (tester over UART), `tb_cam_grab.sv`, `tb_tmds.sv` |
| `gowin/` | Gowin EDA cross-check build |
| `camcheck/` | camera connection check bitstream (with `scripts/camcheck.py`), built by hand |
| `hdmitest/` | 640×480 and 720p HDMI test patterns, built by hand |

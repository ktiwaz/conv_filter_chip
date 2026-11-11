# Tang Primer 20K port (open-source flow)

This is the single-FPGA tester (input RAM → sequencer → `conv_filter_top` → capture RAM) on a Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7, dock board). The PC controls it over the debugger's USB UART instead of Vivado's JTAG-to-AXI. There is no HDMI, and the external-DUT link pins are not brought out.

```
PC (scripts/tb_host.py) ──USB UART──▶ dbg_bridge ──AXI4──▶ fpga_tb_core (HDMI=0, CAP_AXI_WR=0)
                                      third_party/core_dbg_bridge
```

## Tools
- **FPGA flow:** yosys, nextpnr-himbaechel, apycula (`gowin_pack`) and openFPGALoader.
- **sv2v:** the chip RTL uses unpacked-array ports, which yosys's own parser rejects.
- **Simulation:** Icarus Verilog.
- **Host script:** pyserial, installed in `../.venv`:

  ```
  python -m venv ../.venv && ../.venv/bin/pip install pyserial
  ```

The bridge is a submodule. After cloning, run `git submodule update --init`.

## Usage
```
make bit                 # build/tp20k.fs (prints utilisation and Fmax)
make program             # SRAM; `make flash` writes the SPI flash
make sim                 # UART-level simulation incl. two golden testcases (~3 min)
make host-test           # on the board: selftest + all 5x5 testcases

# from the testbench root (one level up):
.venv/bin/python scripts/tb_host.py run-testcase 5x5/emboss
.venv/bin/python scripts/tb_host.py shell     # t = Tester(...), interactive
```

`tb_host.py` has the same commands as `tcl/hw_access.tcl`, minus the HDMI ones. Run it with `--help` for the list. It finds the debugger's UART automatically (FT2232 interface B, usually `/dev/ttyUSB1`); pass `--port` to override.

## Details
- **Clock:** the 27 MHz oscillator goes through an `rPLL` to 48 MHz (27 × 16 / 9). That is the closest a single PLL gets to the PYNQ's 50 MHz, and it divides evenly into 1 and 3 Mbaud. With this clock the external link runs at 24/H MHz, and each sample-phase step is 20.8 ns.
- **Baud rate:** 1 Mbaud by default (`make BAUD=3000000 bit`). Pass the same `--baud` to `tb_host.py`.
- **Bridge protocol (dbg_bridge):**
  - A request is `0x10` (write) or `0x11` (read), then a length in bytes (1–255), then the address as 4 bytes big-endian, then the data little-endian.
  - Writes get no response, so the host checks results by reading back.
  - The bridge has registers of its own at `0xF000_0000` (GPIO in: the filter preset index) and `0xF000_0004` (status: `0xCAFE....`).
- **Resync:** after a lost byte the bridge can sit in the middle of a request. On connect, the host sends 260 zero bytes, which complete any partial request and are ignored by an idle bridge.
- **LEDs and buttons** (both active low):
  - led0 is the heartbeat, led1 shows a finished run, and led2–led5 show the filter preset index.
  - The T10 button is reset, and T3 and T2 step to the next and previous preset.
- **Capture RAM is read-only over UART** (`CAP_AXI_WR=0`). Gowin block RAM has no byte-enabled writes on both ports.

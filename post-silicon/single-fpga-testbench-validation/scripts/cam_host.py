#!/usr/bin/env python3
"""Camera control for the Tang Primer 20K camera pipeline (tp20k_cam_top).

The bitstream initializes the OV3660 by itself after reset (sccb_init with
the register list built in) and turns live mode on, so none of this is
needed for normal use. This script reads the pipeline's status from
fpga_tb_core and, for experiments, takes the camera pins over through the
dbg_bridge GPIO register (MANUAL bit: power, reset, SCCB bit-banged on
SCL/SDA). The tester commands (scripts/tb_host.py) work on the same bitstream.

  cam_host.py [--port P] [--baud B] <command>

Commands:
  init [regfile]     manual: power up the sensor, write the register file
                     (default tp20k/cam/ov3660_384sq_y8.txt), check the chip ID
  auto               give the camera pins back to the FPGA's init engine
                     (press S0 to rerun its init)
  status             FPGA init result, SCCB lines, frame size and rate seen
                     by the grabber, live runs per second
  live on|off        live mode (DUT run on every camera frame, HDMI panes);
                     off also stops the automatic live mode after init
  grab out.png       one camera frame as the grabber saw it (128x128, DUT
                     bypassed), read back over the UART
  reg <addr> [val]   read (or write) one sensor register, hex (manual)
  href-invert 0|1    capture on HREF low instead of high
  off                power the sensor down (manual)
"""
import argparse
import os
import sys
import time

from tb_host import Bridge, find_port, Tester, CAP_BASE, CAP_COUNT, CONFIG, STATUS
from camcheck import Cam
from img_tool import write_png_gray

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REGS = os.path.join(os.path.dirname(HERE), "tp20k", "cam", "ov3660_384sq_y8.txt")

GPIO = 0xF000_0000
# GPIO out bits (tp20k_cam_top)
PWDN, RUN, SCL_LOW, SDA_LOW, HREF_INV, LIVE, MANUAL, NO_AUTO_LIVE = 1, 2, 4, 8, 16, 32, 64, 128
CAM_PINS = PWDN | RUN | SCL_LOW | SDA_LOW
# fpga_tb_core video registers
VIDEO, RX_SIZE, RX_FRAMES, LIVE_RUNS, LIVE_DROP = 0x0002_0024, 0x0002_0028, 0x0002_002C, 0x0002_0030, 0x0002_0034
CHIP_IDS = {0x3660: "OV3660", 0x5640: "OV5640"}


class GpioCam(Cam):
    """camcheck.Cam's SCCB bit-banging, on tp20k_cam_top's GPIO register
    (outputs read back on GPIO in [23:16])."""

    def __init__(self, bus, check_acks=False):
        self.bus = bus
        self.ctrl = bus.read32(GPIO) >> 16 & 0xFF
        self.check_acks = check_acks

    def set_ctrl(self, value):
        self.ctrl = value
        self.bus.write32(GPIO, value)

    def set_pins(self, pins):
        """Camera pins under PC control (MANUAL), other bits kept."""
        self.set_ctrl(self.ctrl & ~CAM_PINS | MANUAL | pins)

    def take_over(self):
        """Switch to MANUAL without disturbing the sensor: powered, running,
        SCCB released, as the FPGA's init engine leaves it."""
        if not self.ctrl & MANUAL:
            g = self.bus.read32(GPIO)
            if not g >> 31 & 1:
                sys.exit("the FPGA's camera init is still running; try again in a second")
            self.set_pins(RUN)

    def _lines(self, scl, sda):
        c = self.ctrl & ~(SCL_LOW | SDA_LOW) | MANUAL
        c |= (0 if scl else SCL_LOW) | (0 if sda else SDA_LOW)
        self.set_ctrl(c)

    def _sda(self):
        return self.bus.read32(GPIO) >> 1 & 1

    def write_byte(self, b):
        if self.check_acks:
            return super().write_byte(b)
        # Without the ACK read (a UART round trip per byte): just clock it
        for i in range(7, -1, -1):
            bit = b >> i & 1
            self._lines(0, bit)
            self._lines(1, bit)
            self._lines(0, bit)
        self._lines(0, 1)
        self._lines(1, 1)
        self._lines(0, 1)
        return True

    def write_reg(self, addr, value):
        self.start()
        acks = [self.write_byte(0x78), self.write_byte(addr >> 8),
                self.write_byte(addr & 0xFF), self.write_byte(value)]
        self.stop()
        return all(acks)

    def read_reg_checked(self, addr):
        saved, self.check_acks = self.check_acks, True
        try:
            return self.read_reg(addr)
        finally:
            self.check_acks = saved


def load_regs(path):
    """'<addr> <data>' (hex) and 'delay <ms>' lines; '#' starts a comment."""
    ops = []
    for n, line in enumerate(open(path), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        a, b = line.split()
        if a == "delay":
            ops.append(("delay", int(b)))
        else:
            ops.append(("w", int(a, 16), int(b, 16)))
    return ops


def power_up(cam):
    cam.set_pins(PWDN)                  # powered down, in reset
    time.sleep(0.01)
    cam.set_pins(0)                     # powered, in reset
    time.sleep(0.005)
    cam.set_pins(RUN)                   # out of reset
    time.sleep(0.03)


def chip_id(cam):
    hi, _ = cam.read_reg_checked(0x300A)
    lo, _ = cam.read_reg_checked(0x300B)
    return None if hi is None or lo is None else hi << 8 | lo


def cmd_init(t, cam, regfile):
    power_up(cam)
    ident = chip_id(cam)
    if ident not in CHIP_IDS:
        sys.exit(f"no camera answering (chip ID {ident!r}); check the cable")
    ops = load_regs(regfile)
    nw = sum(op[0] == "w" for op in ops)
    print(f"{CHIP_IDS[ident]} found; writing {nw} registers from {regfile}")
    t0 = time.monotonic()
    for op in ops:
        if op[0] == "delay":
            t.bus.read32(GPIO)          # let queued writes drain before timing the delay
            time.sleep(op[1] / 1000)
        else:
            cam.write_reg(op[1], op[2])
    t.bus.read32(GPIO)
    # Spot-check: the format register and the chip ID survived
    fmt, _ = cam.read_reg_checked(0x4300)
    ident = chip_id(cam)
    print(f"done in {time.monotonic() - t0:.1f} s; format 0x4300 = "
          + (f"0x{fmt:02x}" if fmt is not None else "unreadable") + " (Y8 is 0x10), chip ID "
          + (f"{ident:04x}" if ident else "unreadable"))


def cmd_status(t, cam):
    g = t.bus.read32(GPIO)
    ctrl = g >> 16 & 0xFF
    nacks = g >> 24 & 0x7F
    init = f"done, {nacks}{'+' if nacks == 0x7F else ''} NACKs" if g >> 31 else "running"
    print(f"FPGA camera init {init}; pins {'MANUAL (PC)' if ctrl & MANUAL else 'FPGA'}; "
          f"auto live {'off' if ctrl & NO_AUTO_LIVE else 'on'}")
    print(f"SCL={g & 1} SDA={g >> 1 & 1} VSYNC={g >> 2 & 1} HREF={g >> 3 & 1} preset={g >> 8 & 15}")
    v, size = t.read1(VIDEO), t.read1(RX_SIZE)
    f0, r0, t0 = t.read1(RX_FRAMES), t.read1(LIVE_RUNS), time.monotonic()
    time.sleep(1.0)
    f1, r1, dt = t.read1(RX_FRAMES), t.read1(LIVE_RUNS), time.monotonic() - t0
    print(f"camera {'enabled' if v & 1 else 'off/in reset'}, grabber sees {size & 0xFFF}x{size >> 16 & 0xFFF}, "
          f"{(f1 - f0) / dt:.1f} frames/s; live={v >> 1 & 1}, {(r1 - r0) / dt:.1f} runs/s, "
          f"{t.read1(LIVE_DROP)} dropped")


def cmd_grab(t, cam, path):
    # Live mode is also held on by the GPIO switch (automatic after init);
    # pause it, or later frames overwrite the capture RAM during readout.
    ctrl = t.pause_live()
    cfg = t.read1(CONFIG)
    try:
        r0 = t.read1(LIVE_RUNS)
        t.write1(CONFIG, (cfg & ~0x1F) | 0x11)      # live + bypass: capture = camera frame
        t0 = time.monotonic()
        while t.read1(LIVE_RUNS) - r0 < 2:
            if time.monotonic() - t0 > 3:
                sys.exit("no camera frames arriving (check `status`)")
            time.sleep(0.02)
        t.write1(CONFIG, (cfg & ~0x1F) | 0x01)      # stop live, keep bypass
        t.wait_done()
        count = t.read1(CAP_COUNT)
        pixels = t.read_pixels(CAP_BASE, count)
    finally:
        t.write1(CONFIG, cfg)
        t.resume_live(ctrl)
    pixels += [0] * (128 * 128 - len(pixels))
    write_png_gray(path, 128, 128, pixels)
    print(f"Wrote {count} pixels to {path} (min {min(pixels)}, max {max(pixels)})")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port")
    ap.add_argument("--baud", type=int, default=1_000_000)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init").add_argument("regfile", nargs="?", default=DEFAULT_REGS)
    sub.add_parser("auto")
    sub.add_parser("status")
    sub.add_parser("live").add_argument("state", choices=["on", "off"])
    sub.add_parser("grab").add_argument("path")
    p = sub.add_parser("reg")
    p.add_argument("addr")
    p.add_argument("value", nargs="?")
    sub.add_parser("href-invert").add_argument("on", type=int, choices=[0, 1])
    sub.add_parser("off")
    a = ap.parse_args()

    t = Tester(a.port or find_port(), a.baud)
    cam = GpioCam(t.bus)

    if a.cmd == "init":
        cmd_init(t, cam, a.regfile)
    elif a.cmd == "auto":
        cam.set_ctrl(cam.ctrl & ~(MANUAL | CAM_PINS))
        print("camera pins back with the FPGA (S0 reruns its init)")
    elif a.cmd == "status":
        cmd_status(t, cam)
    elif a.cmd == "live":
        if a.state == "on":
            cam.set_ctrl(cam.ctrl & ~NO_AUTO_LIVE | LIVE)
        else:
            cam.set_ctrl(cam.ctrl & ~LIVE | NO_AUTO_LIVE)
        print(f"live {a.state}")
    elif a.cmd == "grab":
        cmd_grab(t, cam, a.path)
    elif a.cmd == "reg":
        addr = int(a.addr, 16)
        cam.take_over()
        if a.value is not None:
            cam.write_reg(addr, int(a.value, 16))
        v, acks = cam.read_reg_checked(addr)
        print(f"0x{addr:04x} = " + (f"0x{v:02x}" if v is not None else f"no ACK {acks}"))
    elif a.cmd == "href-invert":
        cam.set_ctrl(cam.ctrl | HREF_INV if a.on else cam.ctrl & ~HREF_INV)
    elif a.cmd == "off":
        cam.set_pins(PWDN)
        print("sensor powered down (`init`, or `auto` then S0, brings it back)")


if __name__ == "__main__":
    main()

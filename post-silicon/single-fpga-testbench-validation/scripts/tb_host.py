#!/usr/bin/env python3
"""Host side of the UART-controlled FPGA testbench (Tang Primer 20K, tp20k/).

The Python counterpart of tcl/hw_access.tcl: same register map and commands,
talking to fpga_tb_core through the ultraembedded dbg_bridge
(third_party/core_dbg_bridge) over the board's USB UART instead of Vivado's
JTAG-to-AXI. Needs pyserial.

  tb_host.py [--port /dev/ttyUSB1] [--baud 1000000] <command> [args]

Commands:
  id                          read the ID register (expect C0F10005)
  selftest                    write/read pattern through the input RAM
  status                      STATUS / CAP_COUNT / DUT state / config
  set-kernel <kernel.hex>     25 signed bytes, row-major (testcases format)
  set-norm <value>            16-bit Q1.15 normalization value
  config [--bypass 0|1] [--test-mode 0|1] [--ext 0|1]
  link [--half H] [--sample S]   external-DUT link clock / sample phase
  set-gap <every> <cycles>    idle cycles after every <every> pixels (0 0 = off)
  kernel-select [n|name]      filter preset (kernel_rom); no argument lists them
  start | wait-done [ms]
  write-image <in.hex8> | read-input <out.hex8> | read-capture <out.hex8>
  run <in.hex8> <out.hex8>    write image, start, wait, read capture
  run-testcase <name|dir> [out.hex8]   e.g. 5x5/emboss, checked against the golden output
  run-all [group]             every testcase in <group> (default 5x5)
  sweep-sample <testcase>     run a testcase at every link sample phase
  shell                       interactive Python with t = Tester(...)

Relative paths are relative to the testbench root; testcase names are looked
up in <repo>/testcases.
"""
import argparse
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TESTCASES = os.path.normpath(os.path.join(ROOT, "..", "..", "testcases"))
sys.path.insert(0, os.path.join(ROOT, "third_party", "core_dbg_bridge", "sw"))

import serial                                    # noqa: E402
GPIO_REG = 0xF000_0000                           # dbg_bridge GPIO
DDR_BASE = 0x1000_0000                           # camera bitstream: DDR3 window
import serial.tools.list_ports                   # noqa: E402
from uart_bus_interface import UartBusInterface  # noqa: E402
from img_tool import read_hex8, write_hex8       # noqa: E402

# fpga_tb_core register map (rtl/fpga_tb_core.v)
IN_BASE   = 0x0000_0000
CAP_BASE  = 0x0001_0000
CTRL      = 0x0002_0000
STATUS    = 0x0002_0004
CAP_COUNT = 0x0002_0008
ID        = 0x0002_000C
CONFIG    = 0x0002_0010
NORM      = 0x0002_0014
GAP       = 0x0002_0018
LINK      = 0x0002_001C
KSEL      = 0x0002_0038
KERNEL    = 0x0002_0040

ID_VALUE     = 0xC0F1_0005
KERNEL_WORDS = 25
NUM_PIXELS   = 16384
# Order of rtl/kernel_rom.v (scripts/gen_kernel_rom.py: sorted testcases/5x5)
PRESETS = ["box_blur", "emboss", "gaussian_blur", "identity", "outline",
           "sharpen", "sobel_x", "sobel_y", "test_mode"]
DUT_STATES = ["IDLE", "LOAD_KERNEL", "LOAD_NORM", "ERROR"]

BLOCK = 252          # bytes per dbg_bridge request (max 255, keep word-aligned)
FLUSH = 260          # zero bytes that finish any partial request (see _resync)


def find_port():
    """The debugger's second FT2232 interface (A is JTAG, B is the UART)."""
    ports = [p for p in serial.tools.list_ports.comports()
             if p.vid == 0x0403 and p.pid == 0x6010]
    uarts = [p for p in ports if (p.location or "").endswith(".1")]
    pick = uarts or ports
    if not pick:
        raise SystemExit("no Tang Primer 20K debugger (0403:6010) found; use --port")
    return pick[-1].device


class Bridge(UartBusInterface):
    """dbg_bridge transport with a read timeout, block reads and resync.

    Upstream opens the port without a timeout (a silent board hangs the
    host), reads one byte per call and can't recover from a lost byte.
    """

    def __init__(self, port, baud, timeout=2.0):
        super().__init__(port, baud)
        self.timeout = timeout

    def connect(self):
        # The first open of the UART after openFPGALoader has used the
        # debugger (JTAG) never passes data; closing and reopening fixes it.
        for attempt in range(3):
            self.uart = serial.Serial(port=self.interface, baudrate=self.baud,
                                      timeout=self.timeout if attempt == 2 else 0.3)
            self._resync()
            try:
                sts = self.read32(self.STS_ADDR)
                break
            except TimeoutError:
                self.uart.close()
                if attempt == 2:
                    raise SystemExit("bridge not responding; is the board programmed "
                                     "with tp20k.fs and the baud rate right?")
        self.uart.timeout = self.timeout
        if (sts & 0xFFFF0000) != 0xCAFE0000:
            raise SystemExit(f"bridge not responding (STS = {sts:08x}); "
                             f"check the bitstream, port and baud rate")

    def _resync(self):
        # A request cut short (lost byte, host killed mid-transfer) leaves the
        # bridge waiting for address/data bytes. Zeros complete it (a write of
        # zeros at worst, which the caller rewrites anyway) and are ignored
        # once the bridge is idle.
        self.uart.write(bytes(FLUSH))
        self.uart.flush()
        time.sleep(0.05)
        self.uart.reset_input_buffer()

    def _read_exact(self, n):
        data = self.uart.read(n)
        if len(data) != n:
            raise TimeoutError(f"bridge returned {len(data)} of {n} bytes")
        return data

    def read32(self, addr):
        if self.uart is None:
            self.connect()
        self.uart.write(bytes([self.CMD_READ, 4]) + addr.to_bytes(4, "big"))
        return int.from_bytes(self._read_exact(4), "little")

    def read(self, addr, length, addr_incr=True, max_block_size=BLOCK):
        if self.uart is None:
            self.connect()
        out = bytearray()
        while len(out) < length:
            n = min(max_block_size, length - len(out))
            a = addr + (len(out) if addr_incr else 0)
            self.uart.write(bytes([self.CMD_READ, n]) + a.to_bytes(4, "big"))
            out += self._read_exact(n)
        return out

    def write(self, addr, data, length=None, addr_incr=True, max_block_size=BLOCK):
        if length is None:
            length = len(data)
        super().write(addr, data, length, addr_incr, max_block_size)


class Tester:
    def __init__(self, port=None, baud=1_000_000, clk_mhz=48.0):
        self.bus = Bridge(port or find_port(), baud)
        self.clk_mhz = clk_mhz
        self.bus.connect()

    # ---- word access -------------------------------------------------
    def write(self, addr, words):
        data = b"".join((w & 0xFFFFFFFF).to_bytes(4, "little") for w in words)
        self.bus.write(addr, data)

    def read(self, addr, n):
        data = self.bus.read(addr, 4 * n)
        return [int.from_bytes(data[i:i + 4], "little") for i in range(0, 4 * n, 4)]

    def read1(self, addr):
        return self.bus.read32(addr)

    def write1(self, addr, value):
        self.write(addr, [value])

    def write_pixels(self, base, pixels):
        data = bytes(pixels) + bytes(-len(pixels) % 4)
        self.bus.write(base, data)

    def read_pixels(self, base, count):
        return list(self.bus.read(base, (count + 3) // 4 * 4))[:count]

    # ---- commands ----------------------------------------------------
    def id(self):
        v = self.read1(ID)
        print(f"ID = {v:08X}")
        return v

    def status(self):
        st, cnt, cfg = self.read1(STATUS), self.read1(CAP_COUNT), self.read1(CONFIG)
        gap, link, norm = self.read1(GAP), self.read1(LINK), self.read1(NORM)
        h = max(1, link & 0xFF)
        print(f"busy={st & 1} done={st >> 1 & 1} cap_count={cnt} "
              f"dut={DUT_STATES[st >> 4 & 3]} mode={'ext' if cfg >> 2 & 1 else 'int'} "
              f"bypass={cfg & 1} test_mode={cfg >> 1 & 1} norm={norm} "
              f"gap={gap >> 16}/{gap & 0xFFFF} "
              f"link={self.clk_mhz / 2 / h:.2f}MHz H={h} S={link >> 8 & 0xFF}")
        return st, cnt

    def set_kernel(self, path):
        k = read_hex8(resolve(path))
        if len(k) != KERNEL_WORDS:
            raise SystemExit(f"{path} has {len(k)} values, expected {KERNEL_WORDS}")
        k += [0] * (-len(k) % 4)
        words = [k[i] | k[i + 1] << 8 | k[i + 2] << 16 | k[i + 3] << 24
                 for i in range(0, len(k), 4)]
        self.write(KERNEL, words)
        if self.read(KERNEL, len(words)) != words:
            raise SystemExit("kernel readback mismatch")

    def set_norm(self, value):
        if not 0 <= value <= 0xFFFF:
            raise SystemExit("norm must fit in 16 bits")
        self.write1(NORM, value)

    def config(self, bypass=None, test_mode=None, ext=None):
        cfg = self.read1(CONFIG)
        for bit, val in ((0, bypass), (1, test_mode), (2, ext)):
            if val is not None:
                cfg = (cfg & ~(1 << bit)) | (int(bool(val)) << bit)
        self.write1(CONFIG, cfg)

    def link(self, half=None, sample=None):
        link = self.read1(LINK)
        h, s = link & 0xFF, link >> 8 & 0xFF
        if half is not None:
            h = half
            if sample is None:
                s = 0 if h >= 3 else 1
        if sample is not None:
            s = sample
        if not 1 <= h <= 255:
            raise SystemExit("half period must be 1..255")
        if s > 2 * h - 1:
            raise SystemExit(f"sample phase must be 0..{2 * h - 1} for H={h}")
        self.write1(LINK, s << 8 | h)
        print(f"link {self.clk_mhz / 2 / h:.2f} MHz (H={h}), sampling "
              f"{s * 1000 / self.clk_mhz:.1f} ns after the rising edge (S={s})")

    def set_gap(self, every, cycles):
        if every > 0xFFFF or cycles > 0xFFFF:
            raise SystemExit("gap fields are 16 bits")
        self.write1(GAP, every << 16 | cycles)

    def kernel_select(self, sel=None):
        if sel is not None:
            n = PRESETS.index(sel) if sel in PRESETS else int(sel)
            if not 0 <= n < len(PRESETS):
                raise SystemExit(f"unknown preset {sel!r} (0..{len(PRESETS) - 1} or one of {PRESETS})")
            self.write1(KSEL, n)
        cur = self.read1(KSEL)
        for i, name in enumerate(PRESETS):
            print(f"{'*' if i == cur else ' '} {i} {name}")
        return PRESETS[cur] if cur < len(PRESETS) else cur

    def start(self):
        self.write1(CTRL, 1)

    def wait_done(self, timeout_ms=5000):
        t0 = time.monotonic()
        while not self.read1(STATUS) >> 1 & 1:
            if (time.monotonic() - t0) * 1000 > timeout_ms:
                raise SystemExit("timeout waiting for done")
            time.sleep(0.01)

    def write_image(self, path):
        pixels = read_hex8(resolve(path))
        if len(pixels) > NUM_PIXELS:
            raise SystemExit(f"{path} has more than {NUM_PIXELS} pixels")
        self.write_pixels(IN_BASE, pixels)
        print(f"Wrote {len(pixels)} pixels from {path}")

    def read_input(self, path):
        write_hex8(resolve(path), self.read_pixels(IN_BASE, NUM_PIXELS))
        print(f"Wrote input RAM to {path}")

    def read_capture(self, path):
        count = self.read1(CAP_COUNT)
        if count == 0:
            print("WARNING: CAP_COUNT is 0")
            return
        write_hex8(resolve(path), self.read_pixels(CAP_BASE, count))
        print(f"Wrote {count} captured pixels to {path}")

    def run(self, in_path, out_path):
        self.write_image(in_path)
        self.start()
        self.wait_done()
        self.read_capture(out_path)

    def selftest(self):
        ctrl = self.pause_live()
        try:
            self._selftest()
        finally:
            self.resume_live(ctrl)

    def _selftest(self):
        if self.id() != ID_VALUE:
            raise SystemExit(f"bad ID (expected {ID_VALUE:08X}; old bitstream?)")
        words = [0xA5000000 | (i * 0x10101) & 0xFFFFFF for i in range(256)]
        self.write(IN_BASE, words)
        for i in (0, 1, 2, 127, 255):
            got = self.read1(IN_BASE + 4 * i)
            if got != words[i]:
                raise SystemExit(f"selftest: word {i} = {got:08x}, expected {words[i]:08x}")
        if self.read(IN_BASE, 256) != words:
            raise SystemExit("selftest: block readback mismatch")
        print("SELFTEST PASS")

    def ddr_test(self, kbytes=64):
        """Camera bitstream: DDR3 through the bridge window (0x1000_0000).
        Random data at 16 MB, the middle and the end of the 128 MB (the first
        megabytes hold the camera preview frames, which change all the time),
        plus odd byte writes, read back and compared."""
        g = self.bus.read32(GPIO_REG)
        if g >> 13 & 1:
            raise SystemExit("DDR3 calibration failed (GPIO in bit 13)")
        if not g >> 12 & 1:
            raise SystemExit("DDR3 not calibrated (GPIO in bit 12); camera bitstream?")
        import random
        rnd = random.Random(kbytes)
        n = kbytes * 1024
        bad = 0
        t0 = time.monotonic()
        for off in (16 << 20, 64 << 20, (128 << 20) - n):
            data = bytes(rnd.getrandbits(8) for _ in range(n))
            self.bus.write(DDR_BASE + off, data)
            back = self.bus.read(DDR_BASE + off, n)
            if back != data:
                i = next(i for i in range(n) if back[i] != data[i])
                print(f"  mismatch at 0x{off + i:07x}: got {back[i]:02x} want {data[i]:02x}")
                bad += 1
        # single bytes into a known word: the byte strobes
        sb = DDR_BASE + (16 << 20) - 0x100
        self.bus.write(sb, bytes(16))
        for i, v in ((1, 0x11), (6, 0x66), (13, 0xdd)):
            self.bus.write(sb + i, bytes([v]))
        want = bytearray(16)
        want[1], want[6], want[13] = 0x11, 0x66, 0xdd
        back = self.bus.read(sb, 16)
        if back != want:
            print(f"  byte strobes: got {back.hex()} want {want.hex()}")
            bad += 1
        dt = time.monotonic() - t0
        print(f"DDR3 {'PASS' if not bad else 'FAIL'}: 3 x {kbytes} KB + byte strobes, "
              f"{2 * 3 * n / dt / 1024:.0f} KB/s over the UART")
        return not bad

    def pause_live(self):
        """Camera bitstream (tp20k_cam_top): live mode runs the DUT on every
        camera frame through the same input and capture RAMs, and is on by
        default. Turn it off (GPIO bit 5 live, bit 7 no auto live) and let a
        run in flight finish; returns the GPIO value for resume_live. The
        tester bitstream ignores GPIO writes and reads back 0."""
        ctrl = self.bus.read32(GPIO_REG) >> 16 & 0xFF
        self.bus.write32(GPIO_REG, ctrl & ~0x20 | 0x80)
        time.sleep(0.05)                            # > one camera frame
        return ctrl

    def resume_live(self, ctrl):
        self.bus.write32(GPIO_REG, ctrl)

    def run_testcase(self, name, out_path=None):
        ctrl = self.pause_live()
        try:
            return self._run_testcase(name, out_path)
        finally:
            self.resume_live(ctrl)

    def _run_testcase(self, name, out_path=None):
        d = testcase_dir(name)
        cfg = open(os.path.join(d, "config.yml")).read()
        m = re.search(r"NORMALIZATION_VALUE=(\d+)", cfg)
        if not m:
            raise SystemExit(f"no NORMALIZATION_VALUE in {d}/config.yml")
        norm, tmode = int(m.group(1)), int("TEST_MODE=1" in cfg)

        self.set_kernel(os.path.join(d, "kernel.hex"))
        self.set_norm(norm)
        self.config(bypass=0, test_mode=tmode)          # keeps the current ext setting
        self.write_pixels(IN_BASE, read_hex8(os.path.join(d, "input_image.hex")))
        self.start()
        self.wait_done()

        st, count, cfg_r = self.read1(STATUS), self.read1(CAP_COUNT), self.read1(CONFIG)
        got = self.read_pixels(CAP_BASE, count)
        if out_path:
            write_hex8(resolve(out_path), got)

        exp = read_hex8(os.path.join(d, "expected_output_image.hex"))
        label = f"{os.path.basename(os.path.dirname(d))}/{os.path.basename(d)}"
        mode = "ext" if cfg_r >> 2 & 1 else "int"
        problems = []
        if st >> 4 & 3 == 3:
            problems.append("DUT in ERROR state")
        if count != len(exp):
            problems.append(f"count {count}, expected {len(exp)}")
        bad = [i for i, (g, e) in enumerate(zip(got, exp)) if g != e]
        if bad:
            i = bad[0]
            problems.append(f"{len(bad)} mismatches, first at {i}: got {got[i]:02x} expected {exp[i]:02x}")
        if not problems:
            print(f"PASS {label:<20} {mode} norm={norm:<5} test_mode={tmode} {count} px")
            return True
        print(f"FAIL {label:<20} {mode} {'; '.join(problems)}")
        return False

    def run_all(self, group="5x5"):
        root = testcase_dir(group)
        dirs = sorted(os.path.join(root, d) for d in os.listdir(root)
                      if os.path.isfile(os.path.join(root, d, "config.yml")))
        passed = sum(self.run_testcase(d) for d in dirs)
        print(f"{passed} / {len(dirs)} testcases passed")
        return passed == len(dirs)

    def sweep_sample(self, name):
        link = self.read1(LINK)
        h, orig = max(1, link & 0xFF), link >> 8 & 0xFF
        eye = []
        for s in range(2 * h):
            self.write1(LINK, s << 8 | h)
            print(f"S={s:<3} ({s * 1000 / self.clk_mhz:6.1f} ns)  ", end="")
            eye.append("PASS" if self.run_testcase(name) else "FAIL")
        self.write1(LINK, orig << 8 | h)
        print(f"sample phase sweep at {self.clk_mhz / 2 / h:.2f} MHz: {' '.join(eye)}")
        return eye


def resolve(path):
    return path if os.path.isabs(path) else os.path.normpath(os.path.join(ROOT, path))


def testcase_dir(name):
    for d in (name, os.path.join(TESTCASES, name), resolve(name)):
        if os.path.isdir(d):
            return os.path.abspath(d)
    raise SystemExit(f"testcase {name} not found (looked in {TESTCASES})")


def bit(v):
    return int(v, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", help="serial port (default: autodetect the debugger)")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--clk-mhz", type=float, default=48.0, help="fabric clock (link labels)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("id", "selftest", "status", "start", "shell"):
        sub.add_parser(name)
    sub.add_parser("set-kernel").add_argument("path")
    sub.add_parser("set-norm").add_argument("value", type=bit)
    p = sub.add_parser("config")
    for opt in ("--bypass", "--test-mode", "--ext"):
        p.add_argument(opt, type=bit)
    p = sub.add_parser("link")
    p.add_argument("--half", type=bit)
    p.add_argument("--sample", type=bit)
    p = sub.add_parser("set-gap")
    p.add_argument("every", type=bit)
    p.add_argument("cycles", type=bit)
    sub.add_parser("kernel-select").add_argument("sel", nargs="?")
    sub.add_parser("wait-done").add_argument("timeout_ms", nargs="?", type=int, default=5000)
    for name in ("write-image", "read-input", "read-capture"):
        sub.add_parser(name).add_argument("path")
    p = sub.add_parser("run")
    p.add_argument("in_path")
    p.add_argument("out_path")
    p = sub.add_parser("run-testcase")
    p.add_argument("name")
    p.add_argument("out_path", nargs="?")
    sub.add_parser("run-all").add_argument("group", nargs="?", default="5x5")
    sub.add_parser("sweep-sample").add_argument("name")
    sub.add_parser("ddr-test").add_argument("kbytes", nargs="?", type=int, default=64)
    a = ap.parse_args()

    t = Tester(a.port, a.baud, a.clk_mhz)
    ok = True
    if a.cmd == "shell":
        import code
        code.interact(banner="t = Tester(...) connected; e.g. t.run_testcase('5x5/emboss')",
                      local={"t": t, **{k: v for k, v in globals().items() if k.isupper()}})
    elif a.cmd == "config":
        t.config(a.bypass, a.test_mode, a.ext)
    elif a.cmd == "link":
        t.link(a.half, a.sample)
    elif a.cmd == "ddr-test":
        ok = t.ddr_test(a.kbytes)
    elif a.cmd in ("run-testcase", "run-all"):
        ok = t.run_testcase(a.name, a.out_path) if a.cmd == "run-testcase" else t.run_all(a.group)
    else:
        method = getattr(t, a.cmd.replace("-", "_"))
        args = [v for k, v in vars(a).items() if k not in ("port", "baud", "clk_mhz", "cmd")]
        method(*args)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

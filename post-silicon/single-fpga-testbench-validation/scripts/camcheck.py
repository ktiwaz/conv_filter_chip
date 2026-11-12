#!/usr/bin/env python3
"""Check an OV5640 (or OV3660) on the Tang Primer 20K dock's DVP connector.

Needs the tp20k/camcheck bitstream. Powers the sensor up (PWDN/RESET
sequence, 24 MHz XCLK from the FPGA), reads its chip ID over SCCB
(bit-banged through the UART bridge), measures PCLK / VSYNC / HREF
activity, then powers it back down.

  camcheck.py [--port /dev/ttyUSB1] [--baud 1000000] [--leave-on]
"""
import argparse
import sys
import time

from tb_host import Bridge, find_port

CTRL, PINS, PCLK, VSYNC, HREF, ID = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14
PWDN, RST_N, XCLK, SCL_LOW, SDA_LOW = 1, 2, 4, 8, 16
SCCB_W, SCCB_R = 0x78, 0x79                 # OV5640 SCCB address (0x3C << 1)


class Cam:
    def __init__(self, bus):
        self.bus = bus
        self.ctrl = bus.read32(CTRL)

    def set_ctrl(self, value):
        self.ctrl = value
        self.bus.write32(CTRL, value)

    def pins(self):
        v = self.bus.read32(PINS)
        return {"scl": v & 1, "sda": v >> 1 & 1, "vsync": v >> 2 & 1,
                "href": v >> 3 & 1, "pclk": v >> 4 & 1, "d": v >> 8 & 0xFF}

    # ---- SCCB, bit-banged (open drain: "1" = released) ----------------
    def _lines(self, scl, sda):
        c = self.ctrl & ~(SCL_LOW | SDA_LOW)
        c |= (0 if scl else SCL_LOW) | (0 if sda else SDA_LOW)
        self.set_ctrl(c)

    def _sda(self):
        return self.bus.read32(PINS) >> 1 & 1

    def start(self):
        self._lines(1, 1)
        self._lines(1, 0)
        self._lines(0, 0)

    def stop(self):
        self._lines(0, 0)
        self._lines(1, 0)
        self._lines(1, 1)

    def write_byte(self, b):
        for i in range(7, -1, -1):
            bit = b >> i & 1
            self._lines(0, bit)
            self._lines(1, bit)
            self._lines(0, bit)
        self._lines(0, 1)                   # release SDA for the ACK
        self._lines(1, 1)
        ack = self._sda() == 0
        self._lines(0, 1)
        return ack

    def read_byte(self, ack):
        b = 0
        self._lines(0, 1)
        for _ in range(8):
            self._lines(1, 1)
            b = b << 1 | self._sda()
            self._lines(0, 1)
        self._lines(0, 0 if ack else 1)
        self._lines(1, 0 if ack else 1)
        self._lines(0, 0 if ack else 1)
        return b

    def read_reg(self, addr):
        """SCCB 16-bit-address read. Returns (value or None, list of ACKs)."""
        self.start()
        acks = [self.write_byte(SCCB_W), self.write_byte(addr >> 8), self.write_byte(addr & 0xFF)]
        self.stop()
        if not all(acks):
            return None, acks
        self.start()
        acks.append(self.write_byte(SCCB_R))
        value = self.read_byte(ack=False) if acks[-1] else None
        self.stop()
        return value, acks


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--leave-on", action="store_true", help="don't power the sensor down at the end")
    a = ap.parse_args()

    bus = Bridge(a.port or find_port(), a.baud)
    bus.connect()
    ident = bus.read32(ID)
    if ident != 0xCA3C0001:
        sys.exit(f"ID {ident:08x}: not the camcheck bitstream (expected CA3C0001)")
    cam = Cam(bus)
    ok = True

    p = cam.pins()
    print(f"[1] powered down:  SCL={p['scl']} SDA={p['sda']}  "
          f"VSYNC={p['vsync']} HREF={p['href']} PCLK={p['pclk']} D={p['d']:02x}")
    if not (p["scl"] and p["sda"]):
        print("    WARNING: SCL/SDA not idle high (shorted, or cable reversed?)")

    # OV5640 power-up: PWDN low >= 1 ms before RESET high, SCCB >= 20 ms after
    cam.set_ctrl(XCLK | PWDN)
    time.sleep(0.01)
    cam.set_ctrl(XCLK)
    time.sleep(0.005)
    cam.set_ctrl(XCLK | RST_N)
    time.sleep(0.05)

    p = cam.pins()
    print(f"[2] powered up:    SCL={p['scl']} SDA={p['sda']}  "
          f"VSYNC={p['vsync']} HREF={p['href']} PCLK={p['pclk']} D={p['d']:02x}")
    if not (p["scl"] and p["sda"]):
        print("    WARNING: SCL/SDA not idle high")
        ok = False

    hi, acks_hi = cam.read_reg(0x300A)
    lo, acks_lo = cam.read_reg(0x300B)
    if hi is None or lo is None:
        ok = False
        print(f"[3] SCCB: no response (ACKs: 0x300A {acks_hi}, 0x300B {acks_lo})")
        if not acks_hi[0]:
            print("    the sensor didn't acknowledge its address 0x3C: not powered, not")
            print("    connected, cable reversed, or no XCLK")
    else:
        chip = hi << 8 | lo
        # OV3660 shares the OV5640's SCCB address, ID registers and 24-pin pinout
        name = {0x5640: "OV5640", 0x3660: "OV3660"}.get(chip)
        ok &= name is not None
        print(f"[3] SCCB chip ID 0x300A/0x300B = {chip:04x} "
              f"({name or 'unknown sensor; expected 5640 or 3660'})")

    c0 = [bus.read32(r) for r in (PCLK, VSYNC, HREF)]
    t0 = time.monotonic()
    time.sleep(1.0)
    c1 = [bus.read32(r) for r in (PCLK, VSYNC, HREF)]
    dt = time.monotonic() - t0
    rate = [((b - a) & 0xFFFFFFFF) / dt for a, b in zip(c0, c1)]
    print(f"[4] activity: PCLK {rate[0] / 1e6:.2f} MHz, VSYNC {rate[1]:.1f} /s, HREF {rate[2]:.0f} /s")
    data = {cam.pins()["d"] for _ in range(32)}
    print(f"    D[7:0] samples: {len(data)} distinct values ({' '.join(f'{d:02x}' for d in sorted(data)[:12])})")
    print("    (an unconfigured OV5640 may not stream; the ID read is the connection test)")

    if not a.leave_on:
        cam.set_ctrl(XCLK | PWDN)           # power down, hold in reset
    print("PASS: camera responds" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

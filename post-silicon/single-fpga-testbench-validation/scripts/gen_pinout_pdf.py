#!/usr/bin/env python3
"""Render the two-FPGA link pinout (tcl/link_pins.tcl) as a PDF wiring sheet.

Uses groff (ms + tbl) and ps2pdf, so the table always matches the pin map
the bitstreams are built from.

Usage: gen_pinout_pdf.py <tcl/link_pins.tcl> <out.pdf>
"""
import re
import subprocess
import sys

# Standard Raspberry Pi 40-pin header power/ground pins
POWER = {1: "3V3", 17: "3V3", 2: "5V", 4: "5V"}
GROUND = {6, 9, 14, 20, 25, 30, 34, 39}
CLOCK_CAPABLE = {"U7", "Y6", "Y7", "Y8", "Y9", "U19", "F19"}   # MRCC/SRCC pins (PYNQ-Z2 v1.0.xdc)
PULLED_UP = {3, 5, 27, 28}   # on-board pull-ups to 3V3 (PYNQ-Z2 manual, RPi header)
JA_SHARED = {3, 5, 7, 26, 27, 28, 29, 31}   # nets shared with PMOD JA (slow falling edges)


def parse(path):
    text = open(path).read()
    body = re.search(r"set link_pins \{(.*?)\n\}", text, re.S).group(1)
    pins = []
    for line in body.splitlines():
        f = line.split()
        if len(f) == 5 and not f[0].startswith("#"):
            sig, gpio, hdr, pkg, d = f
            pins.append(dict(sig=sig, gpio=int(gpio), hdr=int(hdr), pkg=pkg, dir=d))
    return pins


def esc(s):
    return s.replace("\\", "\\e").replace("_", "_")


def roff(pins):
    by_hdr = {p["hdr"]: p for p in pins}
    out = [
        ".nr PS 10", ".nr VS 12", ".nr HM 0.6i", ".nr FM 0.6i", ".nr PO 0.8i", ".nr LL 6.9i",
        ".ds CH", ".ds CF Generated from tcl/link_pins.tcl by scripts/gen_pinout_pdf.py",
        ".TL", "Two-FPGA Test Setup: Board-to-Board Link Pinout",
        ".AU", "conv_filter_chip post-silicon validation (PYNQ-Z2 x 2)",
        ".LP",
        "The tester board drives the 14 chip inputs and samples the 11 chip outputs of",
        "the DUT board over the Raspberry Pi 40-pin header of each PYNQ-Z2.",
        "Both boards use the same header pin numbers: connect pin N on the tester to",
        "pin N on the DUT board with a female-female jumper.",
        ".IP \\(bu 2", "25 signal wires (every GPIO pin except 7, 26 and 29) plus ground wires: use at least pins 9 and 14",
        "(next to the clock on pin 11), 25 and 39; all eight ground pins if possible.",
        ".IP \\(bu 2", "\\fBNever connect pins 1, 2, 4 or 17\\fP (3V3/5V). Each board is powered from its own USB.",
        ".IP \\(bu 2", "Leave pins 7, 26 and 29 unconnected. Leave PMOD A unplugged on both boards:",
        "six of its pins are shared with this header.",
        ".IP \\(bu 2", "Keep jumpers short (10-15 cm or less), especially the clock on pin 11.",
        "Load the DUT bitstream (make program-dut) only on the DUT board.",
        ".IP \\(bu 2", "Link defaults: 8.33 MHz (H=3), DUT outputs sampled at the next rising edge (S=0).",
        "Inputs change on the link clock's falling edge. Check margins with jtb_sweep_sample.",
        ".SH", "Signals",
        ".LP", ".TS", "center box tab(|);",
        "cb | cb | cb | cb | cb | cb", "l | l | n | l | l | l.",
        "Signal|Direction|RPi pin|BCM GPIO|FPGA pin|Notes", "_",
    ]
    for p in pins:
        arrow = "tester \\(-> DUT" if p["dir"] == "out" else "DUT \\(-> tester"
        note = "forwarded link clock, clock-capable" if p["sig"] == "chip_clk" else (
            "JA-shared, pull-up (non-critical)" if p["hdr"] in PULLED_UP else
            "JA-shared (non-critical)" if p["hdr"] in JA_SHARED else "")
        out.append(f"{esc(p['sig'])}|{arrow}|{p['hdr']}|GPIO{p['gpio']}|{p['pkg']}|{note}")
    out += [".TE",
            ".LP", "FPGA pin is the xc7z020 package pin, the same on both boards",
            "(official TUL PYNQ-Z2 v1.0.xdc, rpio_NN_r). Pin 13 (GPIO27, V7) is missing from that",
            "file and from Vivado's board files; it was verified with the I/O lab.",
            ".LP", "\\fBPin placement.\\fP Pins 3, 5, 7, 26-29 and 31 share their net with PMOD JA (3, 5,",
            "27, 28 also have pull-ups). As receivers at 50 MHz their falling edges are ~4.7 ns",
            "(~10 ns with the pull-up) slower than rising, vs 1-3 ns on plain pins. So all",
            "critical signals use plain pins, the pulled-up pins carry only reset_n, test_mode",
            "and status, and dataout[0] (31) is the only JA-shared data bit. Buses run in bit",
            "order: controls on 8-13, datain[0..7] on 15-24, dataout[0..7] on 31-40.",
            ".bp",
            ".SH", "Header wiring checklist (both boards, same pin numbers)",
            ".LP", ".TS", "center box tab(|);",
            "cb | cb | cb | cb || cb | cb | cb | cb", "n | l | l | c || n | l | l | c.",
            "Pin|Connect|Signal|Done|Pin|Connect|Signal|Done", "_"]

    def cell(n):
        if n in POWER:
            return f"{n}|\\fBNO\\fP|{POWER[n]} (do not connect)|"
        if n in GROUND:
            return f"{n}|yes|GND|\\(sq"
        if n in by_hdr:
            p = by_hdr[n]
            return f"{n}|yes|{esc(p['sig'])}|\\(sq"
        if n in PULLED_UP:
            return f"{n}|no|unused (pulled up)|"
        return f"{n}|no|unused|"

    for left in range(1, 41, 2):
        out.append(f"{cell(left)}|{cell(left + 1)}")
    out += [".TE",
            ".LP", "Odd pins are on one row of the header and even pins on the other;",
            "pin 1 is marked on the board silkscreen. Check pin 1 and a ground pin against",
            "the PYNQ-Z2 manual before powering up.",
            ".LP", "DUT-board inputs have pull-downs, so an unwired or idle link holds the DUT in",
            "reset, except on the pulled-up pins 3 and 5 (chip_reset_n, chip_test_mode), which",
            "float high while the tester is unprogrammed; harmless without a forwarded clock."]
    return "\n".join(out) + "\n"


def main(src, dst):
    pins = parse(src)
    assert len(pins) == 25, len(pins)
    ps = subprocess.run(["groff", "-t", "-ms", "-Tps", "-P-pletter"], input=roff(pins).encode(),
                        capture_output=True, check=True).stdout
    subprocess.run(["ps2pdf", "-", dst], input=ps, check=True)


if __name__ == "__main__":
    main(*sys.argv[1:])

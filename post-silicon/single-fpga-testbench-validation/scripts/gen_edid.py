#!/usr/bin/env python3
"""Generate the HDMI-in EDID (rtl/edid_720p.data) from Digilent's 720p EDID.

dvi2rgb is built for pixel clocks >= 60 MHz (kClkRange = 2), and the -1 speed
grade Zynq cannot receive 1080p (1.485 Gb/s per lane). The Digilent EDID also
advertises 1080p60, 640x480, 480p and older VESA modes, so a source could pick
one we can't receive. This keeps only 1280x720 @ 60 Hz:
  - established timings cleared, standard timings unused
  - the 1080p detailed timing descriptor replaced by a dummy descriptor
  - monitor name "CONV FILTER"
  - CEA video data block reduced to VIC 4 (720p60), marked native, and only
    the 720p60 detailed timing kept in the extension block
Output format matches dvi2rgb's EEPROM_8b: 256 lines of 8 binary digits.

Usage: gen_edid.py <digilent dgl_720p_cea.data> <out.data>
"""
import sys


def checksum(block):
    block[127] = (-sum(block[:127])) % 256


def main(src, dst):
    b = [int(line, 2) for line in open(src).read().split()]
    assert len(b) == 256 and b[:8] == [0, 255, 255, 255, 255, 255, 255, 0]

    base = b[:128]
    base[35:38] = [0, 0, 0]                 # established timings
    base[38:54] = [0x01] * 16               # standard timings: unused
    # Descriptor 0 (bytes 54-71) is the 720p60 preferred timing: keep it.
    # Descriptor 1 (72-89) was 1080p60: make it a dummy descriptor.
    base[72:90] = [0, 0, 0, 0x10, 0] + [0] * 13
    # Descriptor 2 (90-107): monitor name
    name = b"CONV FILTER\n"
    base[90:108] = [0, 0, 0, 0xFC, 0] + list(name.ljust(13, b" "))
    # Descriptor 3 (108-125): keep the range limits
    checksum(base)

    ext = b[128:256]
    assert ext[0] == 0x02
    dtd_start = ext[2]
    i = 4
    while i < dtd_start:
        tag, length = ext[i] >> 5, ext[i] & 31
        if tag == 2:                        # video data block
            ext[i + 1:i + 1 + length] = [0x84] + [0] * (length - 1)   # VIC 4, native
            # Shrink the block to one VIC and close the gap
            ext[i] = (2 << 5) | 1
            del ext[i + 2:i + 1 + length]
            ext[2] -= length - 1
            dtd_start = ext[2]
            ext[dtd_start:dtd_start] = []
            ext += [0] * (128 - len(ext))
            break
        i += 1 + length
    # Extension detailed timings: keep only the first (720p60), drop the
    # 1080p60 and 1280x1024 ones that follow it
    first = ext[2]
    assert (ext[first] | ext[first + 1] << 8) == 7425
    ext[first + 18:127] = [0] * (127 - (first + 18))
    checksum(ext)

    out = base + ext
    assert len(out) == 256
    with open(dst, "w") as f:
        f.writelines(f"{v:08b}\n" for v in out)


if __name__ == "__main__":
    main(*sys.argv[1:])

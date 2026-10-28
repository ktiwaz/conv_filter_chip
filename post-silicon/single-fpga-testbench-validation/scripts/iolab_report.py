#!/usr/bin/env python3
"""Analyse I/O lab sweeps (tcl/iolab_access.tcl CSVs): timing eyes, delays,
skews, and PNG eye maps / bathtub plots. Standard library only.

  iolab_report.py <dir or csv ...>                 summary + PNGs next to the CSVs
  iolab_report.py --compare <dirA> <dirB> ...      also overlay bathtubs per experiment

How a sweep becomes an eye
  Each CSV row is one capture phase (MMCM fine phase-shift position); each
  lane column is the number of PRBS-7 check failures out of `samples`. A bit
  error is flagged ~3 times by the self-synchronizing checker, so
  BER ~= errors / (3 * samples). Mid-bit the count is 0 (the eye); near a
  data transition it rises toward 50% BER (the eye wall).

What the phase means per experiment
  A  bus launched at phase phi of clk_ps, captured on clk_ref edges:
     the wall sits where phi + D = 0 (mod T) -> path delay D = (T - wall) mod T
  B  bus launched at phi, captured by the looped-back clock (rclk):
     wall = clock arrival - data arrival (mod T)
  B2 rclk launches the return line, captured at phi of clk_ps:
     wall = full round trip (clock out + clock buffer + clock-to-out + wire back)
"""
import cmath
import csv
import glob
import math
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_font import GLYPHS            # the 5x7 font of the HDMI overlay


# ---------------------------------------------------------------- loading
def load(path):
    meta, rows = {}, []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                if "=" in line:
                    k, v = line[1:].strip().split("=", 1)
                    meta[k.strip()] = v.strip()
            elif line.startswith("point"):
                continue
            elif line.strip():
                rows.append([int(x) for x in line.split(",")])
    for k in ("lanes", "div", "vco_mhz", "steps_per_period", "samples", "step_k", "phase_start", "lane"):
        meta[k] = int(float(meta[k]))
    for k in ("mhz", "step_ps"):
        meta[k] = float(meta[k])
    meta["path"] = path
    meta["name"] = os.path.splitext(os.path.basename(path))[0]
    spp, k, p0 = meta["steps_per_period"], meta["step_k"], meta["phase_start"]
    step_ns = meta["step_ps"] / 1000.0
    meta["T_ns"] = spp * step_ns
    # Point p was measured after (p + 1) * k steps beyond phase_start
    meta["phase_ns"] = [((p0 + (p + 1) * k) % spp) * step_ns for p in range(len(rows))]
    meta["errors"] = [[r[1 + l] for r in rows] for l in range(8)]
    # Rise/fall split (sweeps from the 16-word result layout)
    if rows and len(rows[0]) >= 25:
        meta["rise"] = [[r[9 + l] for r in rows] for l in range(8)]
        meta["fall"] = [[r[17 + l] for r in rows] for l in range(8)]
    return meta


def lanes_of_interest(m):
    if m["exp"] == "B2":
        return [0]
    if m["mode"] in ("single", "aggressor"):
        return [m["lane"]]
    return list(range(m["lanes"]))


# ---------------------------------------------------------------- analysis
def analyse_lane(m, errs):
    """Eye/wall figures for one lane of one sweep, in ns."""
    T, ph = m["T_ns"], m["phase_ns"]
    n = len(errs)
    timed_out = any(e == 0xFFFFFFFF for e in errs)
    bad = [e > 0 for e in errs]
    ber = [min(0.5, e / (3.0 * m["samples"])) if e != 0xFFFFFFFF else 0.5 for e in errs]
    # Sort by phase (the sweep starts at an arbitrary phase and wraps once)
    order = sorted(range(n), key=lambda i: ph[i])
    ph_s = [ph[i] for i in order]
    bad_s = [bad[i] for i in order]
    ber_s = [ber[i] for i in order]
    step = T / n

    def longest_run(flags, value):
        best, best_start = 0, 0
        for s in range(n):
            if flags[s] == value and flags[s - 1] != value:
                L = 0
                while L < n and flags[(s + L) % n] == value:
                    L += 1
                if L > best:
                    best, best_start = L, s
        if all(f == value for f in flags):
            return n, 0
        return best, best_start

    eye_pts, eye_start = longest_run(bad_s, False)
    wall_pts = sum(bad_s)
    # Error-weighted circular centroid of the wall
    if wall_pts:
        z = sum(w * cmath.exp(2j * math.pi * p / T) for p, w in zip(ph_s, ber_s) if w > 0)
        wall_ns = (cmath.phase(z) / (2 * math.pi) * T) % T
    else:
        wall_ns = float("nan")
    return dict(eye_ns=eye_pts * step, eye_start_ns=ph_s[eye_start] if eye_pts < n else 0.0,
                wall_ns=wall_ns, wall_width_ns=wall_pts * step, timed_out=timed_out,
                open_everywhere=(wall_pts == 0), ph=ph_s, ber=ber_s, bad=bad_s)


def edge_walls(m, lane):
    """Rise and fall walls (ns) of one lane, or None without the rise/fall split.

    The faster edge only errs at its own wall, so its error centroid is the
    wall. The slower edge's errors fill the plateau between the two walls, so
    its wall is the end of that plateau away from the other wall.
    """
    if "rise" not in m:
        return None
    T, ph = m["T_ns"], m["phase_ns"]
    n = len(ph)
    order = sorted(range(n), key=lambda i: ph[i])
    rv = [m["rise"][lane][i] for i in order]
    fv = [m["fall"][lane][i] for i in order]
    phs = [ph[i] for i in order]
    if any(v == 0xFFFFFFFF for v in rv) or not any(rv) or not any(fv):
        return None

    def centroid(v):
        z = sum(w * cmath.exp(2j * math.pi * p / T) for p, w in zip(phs, v) if w)
        return (cmath.phase(z) / (2 * math.pi) * T) % T

    def longest(v):
        best, bs = 0, 0
        for s0 in range(n):
            if v[s0] and not v[s0 - 1]:
                L = 0
                while L < n and v[(s0 + L) % n]:
                    L += 1
                if L > best:
                    best, bs = L, s0
        return best, bs

    def far_end(v, other):
        L, s0 = longest(v)
        e1, e2 = phs[s0], phs[(s0 + L - 1) % n]
        d = lambda x: abs(((x - other + T / 2) % T) - T / 2)
        return e1 if d(e1) > d(e2) else e2

    lr, lf = longest(rv)[0], longest(fv)[0]
    if lf >= lr:                     # falling edge is the slower one
        rise = centroid(rv)
        fall = far_end(fv, rise)
    else:
        fall = centroid(fv)
        rise = far_end(rv, fall)
    return rise, fall


def interpret(m, a):
    """The physically meaningful number for this experiment (ns)."""
    T = m["T_ns"]
    if a["open_everywhere"] or math.isnan(a["wall_ns"]):
        return None
    if m["exp"] == "A":
        return ("delay out+wire+in", (T - a["wall_ns"]) % T)
    if m["exp"] == "B":
        return ("clock arrival - data arrival", a["wall_ns"])
    return ("round trip", a["wall_ns"])


def b_margins(m, a):
    """Exp B: margins at the real link's launch point (data changes half a
    period after the forwarded clock's rising edge)."""
    T = m["T_ns"]
    if a["open_everywhere"]:
        return None
    half = a["wall_width_ns"] / 2
    after_edge = (T / 2 - a["wall_ns"]) % T     # data transition after the rclk edge
    return dict(hold_ns=after_edge - half, setup_ns=(T - after_edge) - half)


# ---------------------------------------------------------------- PNG output
def write_png_rgb(path, w, h, px):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(px[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


class Canvas:
    def __init__(self, w, h, bg=(255, 255, 255)):
        self.w, self.h = w, h
        self.px = bytearray(bytes(bg) * (w * h))

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 3
            self.px[i:i + 3] = bytes(c)

    def rect(self, x0, y0, x1, y1, c):
        for y in range(max(0, y0), min(self.h, y1)):
            for x in range(max(0, x0), min(self.w, x1)):
                self.set(x, y, c)

    def line(self, x0, y0, x1, y1, c):
        n = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(n + 1):
            self.set(round(x0 + (x1 - x0) * i / n), round(y0 + (y1 - y0) * i / n), c)

    def text(self, x, y, s, c=(0, 0, 0), scale=2):
        for ci, ch in enumerate(s.upper()):
            g = GLYPHS.get(ch)
            if not g:
                continue
            for r, bits in enumerate(g.split()):
                for col, b in enumerate(bits):
                    if b == "1":
                        self.rect(x + (ci * 6 + col) * scale, y + r * scale,
                                  x + (ci * 6 + col + 1) * scale, y + (r + 1) * scale, c)

    def save(self, path):
        write_png_rgb(path, self.w, self.h, self.px)


def ber_colour(ber):
    """0 -> green (open eye), 1e-6..0.5 -> yellow..red on a log scale."""
    if ber <= 0:
        return (40, 170, 70)
    t = min(1.0, max(0.0, (math.log10(ber) + 6) / (math.log10(0.5) + 6)))
    return (255, int(220 * (1 - t)), 0)


def window_x(p, x0, span, T):
    """Position of phase p (ns) in a window [x0, x0 + span) on the circle, or None."""
    d = (p - x0) % T
    return d / span if d < span else None


def nice_step(span):
    for st in (0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10):
        if span / st <= 12:
            return st
    return 20


def axis(c, ml, mr, top, bottom, x0, span, T):
    """x ticks with labels in ns (phase within the period, wrapped mod T)."""
    st = nice_step(span)
    t = math.ceil(x0 / st) * st
    while t <= x0 + span + 1e-9:
        x = ml + int((t - x0) / span * (c.w - ml - mr))
        c.line(x, bottom, x, bottom + 6, (0, 0, 0))
        c.text(x - 12, bottom + 9, f"{round(t % T, 3):g}", (0, 0, 0), 2)
        t += st
    c.text(c.w - mr - 6 * 2 * 8, bottom + 26, "PHASE NS", (90, 90, 90), 2)


def eye_map(m, lanes, path, x0, span, title):
    """Rows = lanes, x = capture phase in the window, colour = BER."""
    W, ml, mr, top, row_h = 1200, 80, 20, 34, 26
    H = top + row_h * len(lanes) + 50
    c = Canvas(W, H)
    c.text(ml, 8, title, (0, 0, 0), 2)
    T = m["T_ns"]
    for r, l in enumerate(lanes):
        a = analyse_lane(m, m["errors"][l])
        y0 = top + r * row_h
        c.text(8, y0 + 6, f"LANE {l}", (0, 0, 0), 2)
        c.rect(ml, y0 + 2, W - mr, y0 + row_h - 2, (225, 225, 225))     # outside the window
        n = len(a["ph"])
        step = T / n
        for i in range(n):
            fx = window_x(a["ph"][i], x0, span, T)
            if fx is None:
                continue
            x1 = ml + int(fx * (W - ml - mr))
            x2 = ml + int(min(1.0, fx + step / span) * (W - ml - mr))
            c.rect(x1, y0 + 2, max(x2, x1 + 1), y0 + row_h - 2, ber_colour(a["ber"][i]))
    axis(c, ml, mr, top, top + row_h * len(lanes) + 2, x0, span, T)
    c.save(path)


def bathtub(series, T, path, x0, span, title):
    """series: [(label, colour, ph[], ber[])]; y = log10(BER) from 1E-7 to 1."""
    W, H, ml, mr, top, mb = 1200, 420, 80, 20, 34, 50
    c = Canvas(W, H)
    c.text(ml, 8, title, (0, 0, 0), 2)
    ph_h = H - top - mb

    def ypos(lb):
        return top + int((-lb) / 7 * ph_h)

    for d in range(-7, 1):
        y = ypos(d)
        c.line(ml, y, W - mr, y, (225, 225, 225))
        c.text(8, y - 7, "1" if d == 0 else f"1E{d}", (0, 0, 0), 2)
    axis(c, ml, mr, top, top + ph_h + 2, x0, span, T)
    for si, (label, colour, ph, ber) in enumerate(series):
        pts = sorted((window_x(p, x0, span, T), b) for p, b in zip(ph, ber)
                     if window_x(p, x0, span, T) is not None)
        xy = [(ml + int(fx * (W - ml - mr)), ypos(max(math.log10(b), -7.0) if b > 0 else -7.0))
              for fx, b in pts]
        for (xa, ya), (xb, yb) in zip(xy, xy[1:]):
            c.line(xa, ya, xb, yb, colour)
        c.text(W - mr - 130, top + 6 + si * 18, label, colour, 2)
    c.save(path)


def circ_mean(vals, T):
    z = sum(cmath.exp(2j * math.pi * v / T) for v in vals)
    return (cmath.phase(z) / (2 * math.pi) * T) % T


def plots(m, res, lanes, base, label_fn):
    """Bathtub over one period centred on the eye, plus a zoom on the wall."""
    T = m["T_ns"]
    walls = [res[l]["wall_ns"] for l in lanes if not math.isnan(res[l]["wall_ns"])]
    title = f"{m['wiring']} {m['mhz']:.1f} MHZ EXP {m['exp']} {m['mode']}"
    series = [(label_fn(l), PALETTE[l % 8], res[l]["ph"], res[l]["ber"]) for l in lanes]
    if not walls:
        bathtub(series, T, base + "_bathtub.png", 0.0, T, title + " (NO ERRORS)")
        eye_map(m, lanes, base + "_eye.png", 0.0, T, title + " (NO ERRORS)")
        return
    w = circ_mean(walls, T)
    width = max(res[l]["wall_width_ns"] for l in lanes)
    spread = max(abs(((x - w + T / 2) % T) - T / 2) for x in walls)
    zoom = min(T, max(2.0, 4 * width + 4 * spread))
    bathtub(series, T, base + "_bathtub.png", w, T, title + " - BATHTUB, EYE CENTRED")
    bathtub(series, T, base + "_wall.png", w - zoom / 2, zoom, title + " - WALL ZOOM")
    eye_map(m, lanes, base + "_eye.png", w - zoom / 2, zoom, title + " - EYE MAP, WALL ZOOM")


PALETTE = [(31, 119, 180), (255, 127, 14), (44, 160, 44), (214, 39, 40),
           (148, 103, 189), (140, 86, 75), (227, 119, 194), (127, 127, 127)]


# ---------------------------------------------------------------- report
def report(paths, compare_groups=None):
    sweeps = [load(p) for p in paths]
    lines = []
    by_key = {}
    for m in sorted(sweeps, key=lambda s: (s["wiring"], s["mhz"], s["exp"], s["mode"], s["lane"])):
        lanes = lanes_of_interest(m)
        lines.append(f"\n{m['name']}  ({m['wiring']}, {m['mhz']:.2f} MHz, exp {m['exp']}, "
                     f"mode {m['mode']}, T = {m['T_ns']:.2f} ns, step {m['step_ps']:.2f} ps x {m['step_k']})")
        res = {}
        for l in lanes:
            a = analyse_lane(m, m["errors"][l])
            res[l] = a
            what = interpret(m, a)
            if a["timed_out"]:
                lines.append(f"  lane {l}: TIMED OUT (no clock in the capture domain)")
                continue
            if what is None:
                lines.append(f"  lane {l}: no errors at any phase (eye open over the whole period)")
                continue
            lines.append(f"  lane {l}: eye {a['eye_ns']:6.3f} ns   wall {a['wall_ns']:6.3f} ns "
                         f"(width {a['wall_width_ns']:.3f})   {what[0]} = {what[1]:.3f} ns")
            ew = edge_walls(m, l)
            if ew and m["exp"] in ("A", "B", "B2"):
                T = m["T_ns"]
                if m["exp"] == "A":
                    r, f = (T - ew[0]) % T, (T - ew[1]) % T
                    lines.append(f"          rising edge {r:.3f} ns, falling edge {f:.3f} ns "
                                 f"(fall - rise = {f - r:+.3f} ns)")
                else:
                    lines.append(f"          rising-edge wall {ew[0]:.3f} ns, falling-edge wall {ew[1]:.3f} ns")
            if m["exp"] == "B":
                mg = b_margins(m, a)
                lines.append(f"          at the link's launch point (T/2): hold margin {mg['hold_ns']:.3f} ns, "
                             f"setup margin {mg['setup_ns']:.3f} ns")
        # Bus figures for multi-lane modes
        if len(lanes) > 1 and all(not res[l]["timed_out"] for l in lanes):
            delays = [interpret(m, res[l]) for l in lanes]
            if all(d is not None for d in delays):
                vals = [d[1] for d in delays]
                ref = vals[0]
                rel = [((v - ref + m["T_ns"] / 2) % m["T_ns"]) - m["T_ns"] / 2 for v in vals]
                lines.append(f"  lane-to-lane skew: {max(rel) - min(rel):.3f} ns")
            n = len(res[lanes[0]]["bad"])
            common = [all(not res[l]["bad"][i] for l in lanes) for i in range(n)]
            best = 0
            for s in range(n):
                if common[s] and not common[s - 1]:
                    L = 0
                    while L < n and common[(s + L) % n]:
                        L += 1
                    best = max(best, L)
            lines.append(f"  bus eye (all lanes error-free): {best * m['T_ns'] / n:.3f} ns of {m['T_ns']:.2f}")
        base = os.path.splitext(m["path"])[0]
        plots(m, res, lanes, base, lambda l: f"LANE {l}")
        by_key.setdefault((m["mhz"], m["exp"], m["mode"], m["lane"]), []).append((m, res))

    # Single-mode lane skew per wiring/frequency (exp A)
    singles = {}
    for m in sweeps:
        if m["exp"] == "A" and m["mode"] == "single":
            a = analyse_lane(m, m["errors"][m["lane"]])
            d = interpret(m, a)
            if d:
                singles.setdefault((m["wiring"], m["mhz"]), {})[m["lane"]] = (d[1], a["eye_ns"])
    for (wiring, mhz), per in sorted(singles.items()):
        ds = [v[0] for v in per.values()]
        lines.append(f"\nStatic bus skew, {wiring} @ {mhz:.2f} MHz (exp A, single lane at a time): "
                     f"delays {min(ds):.3f}..{max(ds):.3f} ns, skew {max(ds) - min(ds):.3f} ns")
        for l in sorted(per):
            lines.append(f"  lane {l}: delay {per[l][0]:.3f} ns, eye {per[l][1]:.3f} ns")

    if compare_groups:
        lines.append("\nComparison (overlays: *_compare_bathtub.png)")
        for key, group in sorted(by_key.items()):
            wirings = sorted({m["wiring"] for m, _ in group})
            if len(wirings) < 2:
                continue
            series, walls, widths = [], [], []
            T = group[0][0]["T_ns"]
            for i, (m, res) in enumerate(group):
                for l, a in res.items():
                    series.append((f"{m['wiring']} L{l}", PALETTE[(i * 3 + l) % 8], a["ph"], a["ber"]))
                    if not math.isnan(a["wall_ns"]):
                        walls.append(a["wall_ns"])
                        widths.append(a["wall_width_ns"])
                    what = interpret(m, a)
                    lines.append(f"  {m['wiring']:9s} {key[0]:.0f} MHz {key[1]:2s} {key[2]:9s} lane {l}: "
                                 f"eye {a['eye_ns']:.3f} ns, wall width {a['wall_width_ns']:.3f} ns"
                                 + (f", {what[0]} {what[1]:.3f} ns" if what else ""))
            out = os.path.join(os.path.dirname(group[0][0]["path"]),
                               f"compare_{key[0]:.0f}MHz_{key[1]}_{key[2]}_lane{key[3]}")
            if walls:
                w = circ_mean(walls, T)
                spread = max(abs(((x - w + T / 2) % T) - T / 2) for x in walls)
                zoom = min(T, max(2.0, 4 * max(widths) + 4 * spread))
                bathtub(series, T, out + "_wall.png", w - zoom / 2, zoom,
                        f"{key[0]:.0f} MHZ EXP {key[1]} {key[2]} - WIRINGS COMPARED")

    text = "\n".join(lines).lstrip("\n") + "\n"
    print(text)
    return text


def main(argv):
    compare = False
    if argv and argv[0] == "--compare":
        compare, argv = True, argv[1:]
    paths = []
    for a in argv:
        paths += sorted(glob.glob(os.path.join(a, "*.csv"))) if os.path.isdir(a) else [a]
    if not paths:
        sys.exit(__doc__)
    text = report(paths, compare)
    out = os.path.join(os.path.dirname(paths[0]), "summary.txt")
    with open(out, "w") as f:
        f.write(text)


if __name__ == "__main__":
    main(sys.argv[1:])

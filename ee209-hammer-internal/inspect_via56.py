#!/usr/bin/env python3

import gdspy
from collections import Counter, defaultdict

GDS = "build/par-rundir/top_5x5.gds"

VIA56_LAYER = 39
VIA56_DATATYPE = 0

lib = gdspy.GdsLibrary(infile=GDS)
top = lib.top_level()[0]

polys_by_spec = top.get_polygons(by_spec=True)
via_polys = polys_by_spec.get((VIA56_LAYER, VIA56_DATATYPE), [])

print(f"Found {len(via_polys)} VIA56 polygons on layer {VIA56_LAYER}/{VIA56_DATATYPE}")

bboxes = []

for poly in via_polys:
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    xmin, xmax = min(xs), max(xs)
    ymin, ymax = min(ys), max(ys)
    w = round(xmax - xmin, 4)
    h = round(ymax - ymin, 4)
    cx = round((xmin + xmax) / 2.0, 4)
    cy = round((ymin + ymax) / 2.0, 4)
    bboxes.append((xmin, ymin, xmax, ymax, w, h, cx, cy))

size_counts = Counter((w, h) for *_, w, h, cx, cy in bboxes)

print("\nMost common VIA56 cut sizes:")
for (w, h), count in size_counts.most_common(20):
    print(f"  size {w} x {h} um : count={count}")

# Estimate common pitches from vias that share approximately the same y-center.
rows = defaultdict(list)
for xmin, ymin, xmax, ymax, w, h, cx, cy in bboxes:
    rows[cy].append(cx)

x_deltas = []

for cy, xs in rows.items():
    xs = sorted(xs)
    for a, b in zip(xs, xs[1:]):
        d = round(b - a, 4)
        if d > 0:
            x_deltas.append(d)

x_pitch_counts = Counter(x_deltas)

print("\nMost common x-center spacings between VIA56 cuts:")
for pitch, count in x_pitch_counts.most_common(20):
    print(f"  pitch {pitch} um : count={count}")

# Estimate common pitches from vias that share approximately the same x-center.
cols = defaultdict(list)
for xmin, ymin, xmax, ymax, w, h, cx, cy in bboxes:
    cols[cx].append(cy)

y_deltas = []

for cx, ys in cols.items():
    ys = sorted(ys)
    for a, b in zip(ys, ys[1:]):
        d = round(b - a, 4)
        if d > 0:
            y_deltas.append(d)

y_pitch_counts = Counter(y_deltas)

print("\nMost common y-center spacings between VIA56 cuts:")
for pitch, count in y_pitch_counts.most_common(20):
    print(f"  pitch {pitch} um : count={count}")

import os
import gdspy


# ============================================================
# Input / output files
# ============================================================

CORE_GDS = "build/par-rundir/top_3x3.gds"
PAD_GDS = "UCLA_CEMiD_pad_frame_1x1_pcell.gds"
OUT_GDS = "final_chip.gds"

LAYERMAP = "/w/class.1/ee/ee209b/ee209bta/TSMC180PDK/PDK/tsmc18/tsmc18.layermap"

METAL_LAYER_NAME = "METAL6"

# Stitches are written as real drawing metal.
STITCH_PURPOSE = "drawing"

# For finding existing core/pin metal, check both drawing and pin purposes.
SEARCH_PURPOSES = ["drawing", "pin"]


# ============================================================
# Pad / stitch parameters, in microns
# ============================================================

pad_width = 47.0
pad_height = 84.0

# Width of the connector in the short direction.
stitch_width = 2.6
pad_overlap = 2.6

# Overlap into both the pad metal and the core pin metal.
stitch_overlap = 1.0

# Search distance inward from pad edge to find the actual routed pin metal.
search_depth = 150.0

# Allowed sideways search window around the pad.
search_side_margin = 80.0

# Only search very close to the inner pad edge.
# This prevents accidentally selecting VDD/VSS straps farther inside the core.
pin_search_depth = 5.0

# Reject very long shapes, which are more likely to be power straps/rings.
# For top/bottom, this limits candidate x-span.
# For left/right, this limits candidate y-span.
max_candidate_span = 70.0

# ============================================================
# Physical pad definitions
# ============================================================

# Stable physical pad locations.
# Coordinates are bottom-left corners of the physical pad rectangles.
pads_by_id = {
    # Top row, left to right
    "T0": ("top", 161.825, 845.280),
    "T1": ("top", 244.600, 845.280),
    "T2": ("top", 327.355, 845.280),
    "T3": ("top", 410.120, 845.280),
    "T4": ("top", 492.880, 845.280),
    "T5": ("top", 575.800, 845.280),
    "T6": ("top", 658.410, 845.280),
    "T7": ("top", 741.175, 845.280),

    # Left side, bottom to top
    "L0": ("left", 20.720, 161.825),
    "L1": ("left", 20.720, 244.590),
    "L2": ("left", 20.720, 327.355),
    "L3": ("left", 20.720, 410.120),
    "L4": ("left", 20.720, 492.880),
    "L5": ("left", 20.720, 575.645),
    "L6": ("left", 20.720, 658.410),
    "L7": ("left", 20.720, 741.175),

    # Bottom row, left to right
    "B0": ("bottom", 161.825, 20.720),
    "B1": ("bottom", 244.590, 20.720),
    "B2": ("bottom", 327.355, 20.720),
    "B3": ("bottom", 410.120, 20.720),
    "B4": ("bottom", 492.880, 20.720),
    "B5": ("bottom", 575.645, 20.720),
    "B6": ("bottom", 658.410, 20.720),
    "B7": ("bottom", 741.175, 20.720),

    # Right side, bottom to top
    "R0": ("right", 845.280, 161.825),
    "R1": ("right", 845.280, 244.590),
    "R2": ("right", 845.280, 327.355),
    "R3": ("right", 845.280, 410.120),
    "R4": ("right", 845.280, 492.880),
    "R5": ("right", 845.280, 575.645),
    "R6": ("right", 845.280, 658.410),
    "R7": ("right", 845.280, 741.175),
}

# ============================================================
# Logical pin-to-pad assignment
# ============================================================
#
# Only list pads that are currently used.
# Changing pin names or moving pins to different pads should only require
# editing this dictionary.

pin_to_pad = {
    # LEFT: clock / reset / control
    "clk": "L2",
    "reset_n": "L3",
    "kernel_valid": "L4",
    "normalization_valid": "L5",
    "pixel_valid": "L6",
    "test_mode": "L7",

    # TOP: datain[7:1]
    "datain[7]": "T1",
    "datain[6]": "T2",
    "datain[5]": "T3",
    "datain[4]": "T4",
    "datain[3]": "T5",
    "datain[2]": "T6",
    "datain[1]": "T7",

    # BOTTOM: datain[0], dataout[7:2]
    "datain[0]": "B0",
    "dataout[7]": "B1",
    "dataout[6]": "B2",
    "dataout[5]": "B3",
    "dataout[4]": "B4",
    "dataout[3]": "B5",
    "dataout[2]": "B6",

    # RIGHT: dataout[1:0], output_valid, status[1:0]
    "status[0]": "R1",
    "status[1]": "R2",
    "output_valid": "R3",
    "dataout[0]": "R4",
    "dataout[1]": "R5",

    # Spare / unused pads:
    # B7, R0, R6, R7, T0, L0, L1
}

# Build the list used by the stitching code.
pads = [
    (pin_name, *pads_by_id[pad_id])
    for pin_name, pad_id in pin_to_pad.items()
]


# ============================================================
# Helper functions
# ============================================================

def get_gds_layer_from_layermap(layermap_path, layer_name, purpose):
    """
    Parse a Virtuoso-style layermap line like:
        METAL6 drawing 48 0

    Returns:
        (gds_layer, gds_datatype)
    """
    if not os.path.exists(layermap_path):
        raise FileNotFoundError(f"Layer map not found: {layermap_path}")

    layer_name_lower = layer_name.lower()
    purpose_lower = purpose.lower()

    with open(layermap_path, "r") as f:
        for line in f:
            line = line.strip()

            if not line or line.startswith("#") or line.startswith(";"):
                continue

            tokens = line.split()

            if len(tokens) < 4:
                continue

            if tokens[0].lower() == layer_name_lower and tokens[1].lower() == purpose_lower:
                return int(tokens[2]), int(tokens[3])

    raise ValueError(
        f"Could not find {layer_name} {purpose} in {layermap_path}"
    )


def polygon_bbox(poly):
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    return [min(xs), min(ys), max(xs), max(ys)]


def shift_bbox(bbox, dx, dy):
    return [
        bbox[0] + dx,
        bbox[1] + dy,
        bbox[2] + dx,
        bbox[3] + dy,
    ]


def pad_bbox_from_bl(side, bl_x, bl_y):
    if side in ("top", "bottom"):
        return [
            bl_x,
            bl_y,
            bl_x + pad_width,
            bl_y + pad_height,
        ]

    if side in ("left", "right"):
        return [
            bl_x,
            bl_y,
            bl_x + pad_height,
            bl_y + pad_width,
        ]

    raise ValueError(f"Unknown side: {side}")


def inner_pad_edge(side, pad_bbox):
    """
    Return the inner-facing edge of the pad.

    pad_bbox = [xmin, ymin, xmax, ymax]
    """
    xmin, ymin, xmax, ymax = pad_bbox

    if side == "top":
        return ymin

    if side == "bottom":
        return ymax

    if side == "left":
        return xmax

    if side == "right":
        return xmin

    raise ValueError(f"Unknown side: {side}")


def interval_gap(a0, a1, b0, b1):
    """
    Distance between two 1D intervals.
    Returns 0 if they overlap.
    """
    if a1 < b0:
        return b0 - a1

    if b1 < a0:
        return a0 - b1

    return 0.0


def find_nearest_core_metal(side, pad_bbox, core_m6_bboxes):
    """
    Find the actual signal pin METAL6 bbox near the pad inner edge.

    The radial search is kept shallow to avoid accidentally selecting PG metal.
    The lateral search is allowed to be nonzero because Innovus may legally
    move pin metal sideways during routing/legalization.
    """
    pxmin, pymin, pxmax, pymax = pad_bbox
    candidates = []

    if side == "top":
        edge_y = pymin

        for bbox in core_m6_bboxes:
            bxmin, bymin, bxmax, bymax = bbox

            radial_gap = edge_y - bymax
            lateral_gap = interval_gap(pxmin, pxmax, bxmin, bxmax)
            candidate_span = bxmax - bxmin

            if (
                0.0 <= radial_gap <= pin_search_depth
                and lateral_gap <= search_side_margin
                and candidate_span <= max_candidate_span
            ):
                score = radial_gap + 0.25 * lateral_gap
                candidates.append((score, bbox))

    elif side == "bottom":
        edge_y = pymax

        for bbox in core_m6_bboxes:
            bxmin, bymin, bxmax, bymax = bbox

            radial_gap = bymin - edge_y
            lateral_gap = interval_gap(pxmin, pxmax, bxmin, bxmax)
            candidate_span = bxmax - bxmin

            if (
                0.0 <= radial_gap <= pin_search_depth
                and lateral_gap <= search_side_margin
                and candidate_span <= max_candidate_span
            ):
                score = radial_gap + 0.25 * lateral_gap
                candidates.append((score, bbox))

    elif side == "left":
        edge_x = pxmax

        for bbox in core_m6_bboxes:
            bxmin, bymin, bxmax, bymax = bbox

            radial_gap = bxmin - edge_x
            lateral_gap = interval_gap(pymin, pymax, bymin, bymax)
            candidate_span = bymax - bymin

            if (
                0.0 <= radial_gap <= pin_search_depth
                and lateral_gap <= search_side_margin
                and candidate_span <= max_candidate_span
            ):
                score = radial_gap + 0.25 * lateral_gap
                candidates.append((score, bbox))

    elif side == "right":
        edge_x = pxmin

        for bbox in core_m6_bboxes:
            bxmin, bymin, bxmax, bymax = bbox

            radial_gap = edge_x - bxmax
            lateral_gap = interval_gap(pymin, pymax, bymin, bymax)
            candidate_span = bymax - bymin

            if (
                0.0 <= radial_gap <= pin_search_depth
                and lateral_gap <= search_side_margin
                and candidate_span <= max_candidate_span
            ):
                score = radial_gap + 0.25 * lateral_gap
                candidates.append((score, bbox))

    else:
        raise ValueError(f"Unknown side: {side}")

    if not candidates:
        return None

    candidates.sort(key=lambda item: item[0])
    return candidates[0][1]

def clamp(value, low, high):
    return max(low, min(high, value))


def add_rect(cell, xmin, ymin, xmax, ymax, layer, datatype):
    cell.add(
        gdspy.Rectangle(
            (min(xmin, xmax), min(ymin, ymax)),
            (max(xmin, xmax), max(ymin, ymax)),
            layer=layer,
            datatype=datatype
        )
    )


def add_stitch_to_core_metal(cell, side, pad_bbox, core_bbox, layer, datatype):
    """
    Add a compact L-shaped METAL6 stitch from the inner pad edge to the
    nearest actual core METAL6 bbox.

    The segment that touches the pin is aligned to the actual pin bbox,
    while the segment that touches the pad overlaps the pad by pad_overlap.
    """
    pxmin, pymin, pxmax, pymax = pad_bbox
    bxmin, bymin, bxmax, bymax = core_bbox

    half_w = stitch_width / 2.0

    if side == "top":
        pad_edge_y = pymin

        core_x = (bxmin + bxmax) / 2.0
        pad_x = clamp(core_x, pxmin + half_w, pxmax - half_w)

        # Vertical segment from pad inward.
        # Overlaps the pad by pad_overlap and reaches the pin bbox.
        add_rect(
            cell,
            pad_x - half_w,
            bymin,
            pad_x + half_w,
            pad_edge_y + pad_overlap,
            layer,
            datatype
        )

        # Horizontal jog aligned exactly to the pin trace y-bounds.
        add_rect(
            cell,
            min(pad_x - half_w, bxmin),
            bymin,
            max(pad_x + half_w, bxmax),
            bymax,
            layer,
            datatype
        )

        return [
            min(pad_x - half_w, bxmin),
            bymin,
            max(pad_x + half_w, bxmax),
            pad_edge_y + pad_overlap
        ]

    elif side == "bottom":
        pad_edge_y = pymax

        core_x = (bxmin + bxmax) / 2.0
        pad_x = clamp(core_x, pxmin + half_w, pxmax - half_w)

        # Vertical segment from pad inward.
        # Overlaps the pad by pad_overlap and reaches the pin bbox.
        add_rect(
            cell,
            pad_x - half_w,
            pad_edge_y - pad_overlap,
            pad_x + half_w,
            bymax,
            layer,
            datatype
        )

        # Horizontal jog aligned exactly to the pin trace y-bounds.
        add_rect(
            cell,
            min(pad_x - half_w, bxmin),
            bymin,
            max(pad_x + half_w, bxmax),
            bymax,
            layer,
            datatype
        )

        return [
            min(pad_x - half_w, bxmin),
            pad_edge_y - pad_overlap,
            max(pad_x + half_w, bxmax),
            bymax
        ]

    elif side == "left":
        pad_edge_x = pxmax

        core_y = (bymin + bymax) / 2.0
        pad_y = clamp(core_y, pymin + half_w, pymax - half_w)

        # Horizontal segment from pad inward.
        # Overlaps the pad by pad_overlap and reaches the pin bbox.
        add_rect(
            cell,
            pad_edge_x - pad_overlap,
            pad_y - half_w,
            bxmax,
            pad_y + half_w,
            layer,
            datatype
        )

        # Vertical jog aligned exactly to the pin trace x-bounds.
        add_rect(
            cell,
            bxmin,
            min(pad_y - half_w, bymin),
            bxmax,
            max(pad_y + half_w, bymax),
            layer,
            datatype
        )

        return [
            pad_edge_x - pad_overlap,
            min(pad_y - half_w, bymin),
            bxmax,
            max(pad_y + half_w, bymax)
        ]

    elif side == "right":
        pad_edge_x = pxmin

        core_y = (bymin + bymax) / 2.0
        pad_y = clamp(core_y, pymin + half_w, pymax - half_w)

        # Horizontal segment from pad inward.
        # Overlaps the pad by pad_overlap and reaches the pin bbox.
        add_rect(
            cell,
            bxmin,
            pad_y - half_w,
            pad_edge_x + pad_overlap,
            pad_y + half_w,
            layer,
            datatype
        )

        # Vertical jog aligned exactly to the pin trace x-bounds.
        add_rect(
            cell,
            bxmin,
            min(pad_y - half_w, bymin),
            bxmax,
            max(pad_y + half_w, bymax),
            layer,
            datatype
        )

        return [
            bxmin,
            min(pad_y - half_w, bymin),
            pad_edge_x + pad_overlap,
            max(pad_y + half_w, bymax)
        ]

    else:
        raise ValueError(f"Unknown side: {side}")

# ============================================================
# Load GDS files
# ============================================================

stitch_layer, stitch_datatype = get_gds_layer_from_layermap(
    LAYERMAP,
    METAL_LAYER_NAME,
    STITCH_PURPOSE
)

search_specs = []
for purpose in SEARCH_PURPOSES:
    try:
        search_specs.append(
            get_gds_layer_from_layermap(
                LAYERMAP,
                METAL_LAYER_NAME,
                purpose
            )
        )
    except ValueError:
        pass

print(f"Stitch layer: {METAL_LAYER_NAME} {STITCH_PURPOSE} -> {stitch_layer}/{stitch_datatype}")
print(f"Searching core METAL6 specs: {search_specs}")

core = gdspy.GdsLibrary(infile=CORE_GDS)
pad = gdspy.GdsLibrary(infile=PAD_GDS)

core_top = core.top_level()[0]
pad_top = pad.top_level()[0]

top = gdspy.Cell("chip_top")


# ============================================================
# Compute core-to-padframe placement offset
# ============================================================

core_bbox = core_top.get_bounding_box()
pad_bbox = pad_top.get_bounding_box()

core_cx = (core_bbox[0][0] + core_bbox[1][0]) / 2.0
core_cy = (core_bbox[0][1] + core_bbox[1][1]) / 2.0

pad_cx = (pad_bbox[0][0] + pad_bbox[1][0]) / 2.0
pad_cy = (pad_bbox[0][1] + pad_bbox[1][1]) / 2.0

dx = pad_cx - core_cx
dy = pad_cy - core_cy

print(f"Padframe fixed at (0, 0)")
print(f"Core shifted by dx={dx}, dy={dy}")


# ============================================================
# Extract actual core METAL6 geometry after applying dx/dy
# ============================================================

core_polys_by_spec = core_top.get_polygons(by_spec=True)
core_m6_bboxes = []

for spec in search_specs:
    if spec not in core_polys_by_spec:
        continue

    for poly in core_polys_by_spec[spec]:
        bbox = polygon_bbox(poly)
        core_m6_bboxes.append(shift_bbox(bbox, dx, dy))

print(f"Found {len(core_m6_bboxes)} core METAL6 bboxes")


# ============================================================
# Place padframe and core
# ============================================================

top.add(gdspy.CellReference(pad_top, (0, 0)))
top.add(gdspy.CellReference(core_top, (dx, dy)))


# ============================================================
# Add stitches
# ============================================================

for name, side, bl_x, bl_y in pads:
    this_pad_bbox = pad_bbox_from_bl(side, bl_x, bl_y)
    core_metal_bbox = find_nearest_core_metal(
        side,
        this_pad_bbox,
        core_m6_bboxes
    )

    if core_metal_bbox is None:
        print(f"WARNING: no core METAL6 found for {name} side={side} pad_bbox={this_pad_bbox}")
        continue

    stitch_bbox = add_stitch_to_core_metal(
        top,
        side,
        this_pad_bbox,
        core_metal_bbox,
        stitch_layer,
        stitch_datatype
    )

    print(
        f"{name}: side={side} "
        f"pad_bbox={this_pad_bbox} "
        f"core_bbox={core_metal_bbox} "
        f"stitch={stitch_bbox}"
    )


# ============================================================
# Write full hierarchy
# ============================================================

all_cells = top.get_dependencies(True)
all_cells.add(top)

gdspy.write_gds(OUT_GDS, cells=all_cells)

print(f"Created {OUT_GDS}")

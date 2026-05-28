import os
import gdspy


# ============================================================
# Input / output files
# ============================================================

CORE_GDS = "build/par-rundir/top_3x3.gds"
PAD_GDS = "UCLA_CEMiD_pad_frame_1x1_pcell.gds"
OUT_GDS = "final_chip.gds"

LAYERMAP = "/w/class.1/ee/ee209b/ee209bta/TSMC180PDK/PDK/tsmc18/tsmc18.layermap"
VSS_M5_STRIPES_FILE = "build/par-rundir/vss_metal5_stripes.txt"

METAL_LAYER_NAME = "METAL6"

POWER_METAL5_NAME = "METAL5"
POWER_METAL6_NAME = "METAL6"

POWER_VIA56_NAME = "VIA56"

POWER_PURPOSE = "drawing"

ENABLE_SIGNAL_M5_STITCHES = False

# For L1/R6 VSS connections only:
# reject horizontal METAL5 shapes that are too thick in y.
# Tune this based on printed bbox widths.
max_vss_stripe_y_width = 9.0

# Power connector parameters, in microns
power_pad_overlap = 2.6
power_search_depth = 250.0
power_stripe_lateral_margin = 80.0

# Avoid AMS wide-metal slot violations by splitting power bridges whose
# short dimension would otherwise exceed this value. Tune power_slot_gap
# to the minimum same-net spacing/slot width required by your rule deck.
power_max_unslotted_width = 35.0
power_slot_gap = 2.5

# M5-to-M6 via array parameters, in microns.
# Extracted from existing VIA56 geometry in build/par-rundir/top_3x3.gds:
#   VIA56 drawing layer = 39/0
#   cut size = 0.36 x 0.36 um
#   common dense center-to-center pitch = 0.71 um
via56_size = 0.36
via56_pitch = 0.71
via56_edge_margin = 0.40

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
pin_search_depth = 6.0

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
    "datain[7]": "L7",

    # TOP: datain[7:1]
    "datain[6]": "T1",
    "datain[5]": "T2",
    "datain[4]": "T3",
    "datain[3]": "T4",
    "datain[2]": "T5",
    "datain[1]": "T6",
    "datain[0]": "T7",

    # BOTTOM: datain[0], dataout[7:2]
    "dataout[7]": "B0",
    "dataout[6]": "B1",
    "dataout[5]": "B2",
    "dataout[4]": "B3",
    "dataout[3]": "B4",
    "dataout[2]": "B5",
    "dataout[1]": "B6",

    # RIGHT: dataout[1:0], output_valid, status[1:0]
    "dataout[0]": "R0",
    "output_valid": "R1",
    "status[0]": "R3",
    "status[1]": "R4",
    "test_mode": "R5",

    # Spare / unused pads:
    # B7, R2, R6, R7, T0, L0, L1
}

# ============================================================
# Power pad-to-net assignment
# ============================================================
#
# VDD is known to be the outer ring.
# VSS is connected by extending the nearest inward METAL5 VSS stripe.

power_pad_to_net = {
    "T0": "VDD",
    "L0": "VDD",
    "L1": "VSS",
    "B7": "VDD",
    "R7": "VDD",
    "R6": "VSS",
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
    bbox = [
        min(xmin, xmax),
        min(ymin, ymax),
        max(xmin, xmax),
        max(ymin, ymax),
    ]

    cell.add(
        gdspy.Rectangle(
            (bbox[0], bbox[1]),
            (bbox[2], bbox[3]),
            layer=layer,
            datatype=datatype
        )
    )

    return bbox


def add_possibly_slotted_power_rect(
    cell,
    bbox,
    layer,
    datatype,
    max_unslotted_width=power_max_unslotted_width,
    slot_gap=power_slot_gap
):
    """
    Add a power connector rectangle, splitting it into two same-net rectangles
    when the short dimension would exceed the wide-metal slot threshold.

    This is intended for pad-to-ring/stripe bridges like L0, L1, R6, and R7.
    It intentionally does not affect the narrow signal stitches.
    """
    xmin, ymin, xmax, ymax = bbox
    width_x = xmax - xmin
    width_y = ymax - ymin

    if width_x <= 0.0 or width_y <= 0.0:
        return []

    short_dim = min(width_x, width_y)

    if short_dim <= max_unslotted_width:
        return [add_rect(cell, xmin, ymin, xmax, ymax, layer, datatype)]

    if slot_gap <= 0.0 or short_dim <= slot_gap:
        raise ValueError(
            f"Cannot split power rectangle bbox={bbox}; "
            f"slot_gap={slot_gap} is not smaller than short dimension={short_dim}"
        )

    drawn = []

    if width_x <= width_y:
        # Shape is narrower in x, so split the x-width into two columns.
        mid = interval_center(xmin, xmax)
        gap0 = mid - slot_gap / 2.0
        gap1 = mid + slot_gap / 2.0
        drawn.append(add_rect(cell, xmin, ymin, gap0, ymax, layer, datatype))
        drawn.append(add_rect(cell, gap1, ymin, xmax, ymax, layer, datatype))
    else:
        # Shape is narrower in y, so split the y-width into two rows.
        mid = interval_center(ymin, ymax)
        gap0 = mid - slot_gap / 2.0
        gap1 = mid + slot_gap / 2.0
        drawn.append(add_rect(cell, xmin, ymin, xmax, gap0, layer, datatype))
        drawn.append(add_rect(cell, xmin, gap1, xmax, ymax, layer, datatype))

    return drawn


def overlap_length(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def interval_center(a0, a1):
    return (a0 + a1) / 2.0


def extract_shifted_bboxes(cell, specs, dx, dy):
    polys_by_spec = cell.get_polygons(by_spec=True)
    bboxes = []

    for spec in specs:
        if spec not in polys_by_spec:
            continue

        for poly in polys_by_spec[spec]:
            bbox = polygon_bbox(poly)
            bboxes.append(shift_bbox(bbox, dx, dy))

    return bboxes


def get_layer_specs(layer_name, purposes):
    specs = []

    for purpose in purposes:
        try:
            specs.append(
                get_gds_layer_from_layermap(
                    LAYERMAP,
                    layer_name,
                    purpose
                )
            )
        except ValueError:
            pass

    if not specs:
        raise ValueError(f"No GDS specs found for {layer_name} purposes={purposes}")

    return specs


def find_nearest_inward_metal(side, pad_bbox, metal_bboxes):
    """
    Find nearest metal bbox directly inward from a pad.

    Used for VDD direct connections:
      T0/B7 use METAL5.
      L0/R7 use METAL6.
    """
    pxmin, pymin, pxmax, pymax = pad_bbox
    candidates = []

    for bbox in metal_bboxes:
        bxmin, bymin, bxmax, bymax = bbox

        if side == "top":
            radial_gap = pymin - bymax
            lateral_gap = interval_gap(pxmin, pxmax, bxmin, bxmax)

        elif side == "bottom":
            radial_gap = bymin - pymax
            lateral_gap = interval_gap(pxmin, pxmax, bxmin, bxmax)

        elif side == "left":
            radial_gap = bxmin - pxmax
            lateral_gap = interval_gap(pymin, pymax, bymin, bymax)

        elif side == "right":
            radial_gap = pxmin - bxmax
            lateral_gap = interval_gap(pymin, pymax, bymin, bymax)

        else:
            raise ValueError(f"Unknown side: {side}")

        if (
            0.0 <= radial_gap <= power_search_depth
            and lateral_gap <= power_stripe_lateral_margin
        ):
            score = radial_gap + 0.5 * lateral_gap
            candidates.append((score, bbox))

    if not candidates:
        return None

    candidates.sort(key=lambda item: item[0])
    return candidates[0][1]


def add_direct_power_connection(cell, side, pad_bbox, target_bbox, layer, datatype):
    """
    Connect a power pad to the nearest matching ring metal.

    The final connector rectangle is passed through
    add_possibly_slotted_power_rect(), so wide pad-to-ring plates become
    two narrower same-net rectangles instead of one AMS.1 wide-metal violation.
    """
    pxmin, pymin, pxmax, pymax = pad_bbox
    bxmin, bymin, bxmax, bymax = target_bbox

    if side == "top":
        x0 = max(pxmin, bxmin)
        x1 = min(pxmax, bxmax)

        if x1 <= x0:
            xmid = clamp(interval_center(pxmin, pxmax), bxmin, bxmax)
            x0 = xmid - stitch_width / 2.0
            x1 = xmid + stitch_width / 2.0

        connector_bbox = [x0, bymin, x1, pymin + power_pad_overlap]

    elif side == "bottom":
        x0 = max(pxmin, bxmin)
        x1 = min(pxmax, bxmax)

        if x1 <= x0:
            xmid = clamp(interval_center(pxmin, pxmax), bxmin, bxmax)
            x0 = xmid - stitch_width / 2.0
            x1 = xmid + stitch_width / 2.0

        connector_bbox = [x0, pymax - power_pad_overlap, x1, bymax]

    elif side == "left":
        y0 = max(pymin, bymin)
        y1 = min(pymax, bymax)

        if y1 <= y0:
            ymid = clamp(interval_center(pymin, pymax), bymin, bymax)
            y0 = ymid - stitch_width / 2.0
            y1 = ymid + stitch_width / 2.0

        connector_bbox = [pxmax - power_pad_overlap, y0, bxmax, y1]

    elif side == "right":
        y0 = max(pymin, bymin)
        y1 = min(pymax, bymax)

        if y1 <= y0:
            ymid = clamp(interval_center(pymin, pymax), bymin, bymax)
            y0 = ymid - stitch_width / 2.0
            y1 = ymid + stitch_width / 2.0

        connector_bbox = [bxmin, y0, pxmin + power_pad_overlap, y1]

    else:
        raise ValueError(f"Unknown side: {side}")

    return add_possibly_slotted_power_rect(
        cell,
        connector_bbox,
        layer,
        datatype
    )

def find_inward_vss_metal5_stripes(side, pad_bbox, metal5_bboxes, die_center_y=None):
    """
    Find VSS METAL5 stripes that are horizontally inward from a left/right VSS pad,
    whose shifted y-coordinates overlap the pad y-bounds, and whose y-thickness
    looks like a stripe rather than a wide METAL5 ring shape.
    """
    if side not in ("left", "right"):
        raise ValueError("VSS stripe extension currently supports left/right pads only")

    pxmin, pymin, pxmax, pymax = pad_bbox
    candidates = []

    for bbox in metal5_bboxes:
        bxmin, bymin, bxmax, bymax = bbox

        width_x = bxmax - bxmin
        width_y = bymax - bymin

        # Only horizontal METAL5 stripe-like shapes.
        if width_x <= width_y:
            continue

        # Reject wide/thick horizontal shapes, which are likely ring metal.
        if width_y > max_vss_stripe_y_width:
            continue

        # Require actual y-overlap with this pad.
        y_overlap = overlap_length(pymin, pymax, bymin, bymax)
        if y_overlap <= 0.0:
            continue

        if side == "left":
            radial_gap = bxmin - pxmax
        else:
            radial_gap = pxmin - bxmax

        if 0.0 <= radial_gap <= power_search_depth:
            candidates.append((radial_gap, bbox))

    candidates.sort(key=lambda item: item[0])
    return [bbox for _, bbox in candidates]


def extend_vss_stripe_to_pad(cell, side, pad_bbox, stripe_bbox, layer, datatype):
    """
    Extend only the selected VSS METAL5 stripe outward until it overlaps
    the VSS pad. This preserves the neighboring VDD stripe.
    """
    pxmin, pymin, pxmax, pymax = pad_bbox
    bxmin, bymin, bxmax, bymax = stripe_bbox

    if side == "left":
        add_rect(
            cell,
            pxmax - power_pad_overlap,
            bymin,
            bxmax,
            bymax,
            layer,
            datatype
        )

        return [pxmax - power_pad_overlap, bymin, bxmax, bymax]

    if side == "right":
        add_rect(
            cell,
            bxmin,
            bymin,
            pxmin + power_pad_overlap,
            bymax,
            layer,
            datatype
        )

        return [bxmin, bymin, pxmin + power_pad_overlap, bymax]

    raise ValueError(f"Unsupported VSS stripe side: {side}")


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

def read_bbox_file(path):
    bboxes = []

    if not os.path.exists(path):
        raise FileNotFoundError(f"Required bbox file not found: {path}")

    with open(path, "r") as f:
        for line_num, line in enumerate(f, start=1):
            line = line.strip()

            if not line:
                continue

            # Innovus may write rects as Tcl-style lists:
            #   {xmin ymin xmax ymax}
            # Strip braces before parsing.
            line = line.replace("{", " ").replace("}", " ")

            tokens = line.split()
            values = [float(x) for x in tokens]

            if len(values) != 4:
                raise ValueError(
                    f"Invalid bbox line in {path} at line {line_num}: "
                    f"expected 4 numbers, got {len(values)} from: {line}"
                )

            bboxes.append(values)

    return bboxes

def find_side_metal6_ring_for_corner_vdd(side, pad_bbox, metal6_bboxes):
    """
    Find the side METAL6 VDD ring segment for L0/R7.

    This is intentionally separate from generic METAL6 power search because
    the generic search was causing incorrect connections.

    For left/right VDD pads:
      - require a vertical METAL6 shape
      - require y-overlap with the pad
      - choose the nearest inward shape
    """
    if side not in ("left", "right"):
        raise ValueError("Corner VDD METAL6 ring connection only supports left/right pads")

    pxmin, pymin, pxmax, pymax = pad_bbox
    candidates = []

    for bbox in metal6_bboxes:
        bxmin, bymin, bxmax, bymax = bbox

        width_x = bxmax - bxmin
        width_y = bymax - bymin

        # Side METAL6 ring should be vertical.
        if width_y <= width_x:
            continue

        # Require actual y-overlap with the pad.
        y_overlap = overlap_length(pymin, pymax, bymin, bymax)
        if y_overlap <= 0.0:
            continue

        if side == "left":
            radial_gap = bxmin - pxmax
        else:
            radial_gap = pxmin - bxmax

        if 0.0 <= radial_gap <= power_search_depth:
            candidates.append((radial_gap, bbox))

    if not candidates:
        return None

    candidates.sort(key=lambda item: item[0])
    return candidates[0][1]

def add_via_array_in_bbox(cell, bbox, via_layer, via_datatype):
    """
    Add a simple rectangular via array inside bbox.

    bbox = [xmin, ymin, xmax, ymax]
    """
    xmin, ymin, xmax, ymax = bbox

    usable_xmin = xmin + via56_edge_margin
    usable_ymin = ymin + via56_edge_margin
    usable_xmax = xmax - via56_edge_margin
    usable_ymax = ymax - via56_edge_margin

    if usable_xmax - usable_xmin < via56_size:
        return 0

    if usable_ymax - usable_ymin < via56_size:
        return 0

    count = 0

    y = usable_ymin
    while y + via56_size <= usable_ymax:
        x = usable_xmin
        while x + via56_size <= usable_xmax:
            add_rect(
                cell,
                x,
                y,
                x + via56_size,
                y + via56_size,
                via_layer,
                via_datatype
            )
            count += 1
            x += via56_pitch
        y += via56_pitch

    return count

def find_side_metal6_ring_for_vss(side, pad_bbox, metal6_bboxes):
    """
    Find the side METAL6 VSS ring segment for L1/R6.

    For left/right VSS pads:
      - require a vertical METAL6 shape
      - require y-overlap with the pad
      - choose the nearest inward shape
    """
    if side not in ("left", "right"):
        raise ValueError("VSS METAL6 ring connection only supports left/right pads")

    pxmin, pymin, pxmax, pymax = pad_bbox
    candidates = []

    for bbox in metal6_bboxes:
        bxmin, bymin, bxmax, bymax = bbox

        width_x = bxmax - bxmin
        width_y = bymax - bymin

        # Side ring should be vertical.
        if width_y <= width_x:
            continue

        y_overlap = overlap_length(pymin, pymax, bymin, bymax)
        if y_overlap <= 0.0:
            continue

        if side == "left":
            radial_gap = bxmin - pxmax
        else:
            radial_gap = pxmin - bxmax

        if 0.0 <= radial_gap <= power_search_depth:
            score = radial_gap
            candidates.append((score, bbox))

    if not candidates:
        return None

    candidates.sort(key=lambda item: item[0])
    return candidates[0][1]

def add_m5_bridge_to_m6_ring_with_vias(
    cell,
    side,
    pad_bbox,
    ring_m6_bbox,
    m5_layer,
    m5_datatype,
    via_layer,
    via_datatype
):
    """
    Draw one or two METAL5 bridge rectangles from a left/right VSS pad to
    the side METAL6 ring, then add M5-M6 via arrays where each METAL5
    bridge piece overlaps the METAL6 ring.
    """
    pxmin, pymin, pxmax, pymax = pad_bbox
    rxmin, rymin, rxmax, rymax = ring_m6_bbox

    # Use the vertical overlap between the pad and the ring as the bridge height.
    y0 = max(pymin, rymin)
    y1 = min(pymax, rymax)

    if y1 <= y0:
        # Fallback: use a centered bridge within the pad.
        ymid = interval_center(pymin, pymax)
        y0 = ymid - stitch_width / 2.0
        y1 = ymid + stitch_width / 2.0

    if side == "left":
        bridge_bbox = [pxmax - power_pad_overlap, y0, rxmax, y1]
    elif side == "right":
        bridge_bbox = [rxmin, y0, pxmin + power_pad_overlap, y1]
    else:
        raise ValueError(f"Unsupported side for M5 bridge to M6 ring: {side}")

    bridge_pieces = add_possibly_slotted_power_rect(
        cell,
        bridge_bbox,
        m5_layer,
        m5_datatype
    )

    via_results = []
    total_vias = 0

    # Add vias separately for each slotted bridge piece so no vias are placed
    # in the gap between the two same-net METAL5 rectangles.
    for piece_bbox in bridge_pieces:
        via_bbox = [
            max(piece_bbox[0], rxmin),
            max(piece_bbox[1], rymin),
            min(piece_bbox[2], rxmax),
            min(piece_bbox[3], rymax)
        ]

        via_count = add_via_array_in_bbox(
            cell,
            via_bbox,
            via_layer,
            via_datatype
        )

        via_results.append((via_bbox, via_count))
        total_vias += via_count

    return bridge_pieces, via_results, total_vias

def find_vss_metal6_inner_ring(side, pad_bbox, metal6_bboxes):
    """
    Find the inner METAL6 VSS ring for L1/R6.

    For side pads, METAL6 ring shapes are vertical. Since VDD is the outer ring
    and VSS is the inner ring, the nearest inward vertical METAL6 ring is likely
    VDD, while the next inward vertical METAL6 ring is VSS.
    """
    if side not in ("left", "right"):
        raise ValueError("VSS METAL6 inner-ring search currently supports left/right pads only")

    pxmin, pymin, pxmax, pymax = pad_bbox
    candidates = []

    for bbox in metal6_bboxes:
        bxmin, bymin, bxmax, bymax = bbox

        width_x = bxmax - bxmin
        width_y = bymax - bymin

        # Side ring on METAL6 should be vertical.
        if width_y <= width_x:
            continue

        # Require y-overlap with the VSS pad.
        y_overlap = overlap_length(pymin, pymax, bymin, bymax)
        if y_overlap <= 0.0:
            continue

        if side == "left":
            radial_gap = bxmin - pxmax
        else:
            radial_gap = pxmin - bxmax

        if 0.0 <= radial_gap <= power_search_depth:
            candidates.append((radial_gap, bbox))

    if not candidates:
        return None

    candidates.sort(key=lambda item: item[0])

    print(f"VSS METAL6 candidates for side={side} pad_bbox={pad_bbox}:")
    for i, (gap, bbox) in enumerate(candidates):
        print(f"  candidate {i}: radial_gap={gap:.3f} bbox={bbox}")

    # Candidate 0 is usually the outer VDD ring.
    # Candidate 1 should be the inner VSS ring.
    if len(candidates) >= 2:
        return candidates[1][1]

    print(
        f"WARNING: only one METAL6 ring candidate found for VSS side={side}; "
        f"using it, but it may be the outer VDD ring"
    )
    return candidates[0][1]

# ============================================================
# Load GDS files
# ============================================================

power_via56_layer, power_via56_datatype = get_gds_layer_from_layermap(
    LAYERMAP,
    POWER_VIA56_NAME,
    POWER_PURPOSE
)

stitch_layer, stitch_datatype = get_gds_layer_from_layermap(
    LAYERMAP,
    METAL_LAYER_NAME,
    STITCH_PURPOSE
)

power_m5_layer, power_m5_datatype = get_gds_layer_from_layermap(
    LAYERMAP,
    POWER_METAL5_NAME,
    POWER_PURPOSE
)

power_m6_layer, power_m6_datatype = get_gds_layer_from_layermap(
    LAYERMAP,
    POWER_METAL6_NAME,
    POWER_PURPOSE
)

metal5_search_specs = get_layer_specs(
    POWER_METAL5_NAME,
    SEARCH_PURPOSES
)

metal6_search_specs = get_layer_specs(
    POWER_METAL6_NAME,
    SEARCH_PURPOSES
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

vss_m5_bboxes_unshifted = read_bbox_file(VSS_M5_STRIPES_FILE)

vss_m5_bboxes = [
    shift_bbox(bbox, dx, dy)
    for bbox in vss_m5_bboxes_unshifted
]

print(
    f"Loaded {len(vss_m5_bboxes)} VSS METAL5 stripe bboxes from Innovus "
    f"and shifted them by dx={dx}, dy={dy}"
)

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

core_m5_bboxes = extract_shifted_bboxes(
    core_top,
    metal5_search_specs,
    dx,
    dy
)

core_m6_power_bboxes = extract_shifted_bboxes(
    core_top,
    metal6_search_specs,
    dx,
    dy
)

die_center_y = pad_cy

print(f"Found {len(core_m5_bboxes)} core METAL5 bboxes")
print(f"Found {len(core_m6_power_bboxes)} core METAL6 power-search bboxes")


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

    stitch_bbox_m6 = add_stitch_to_core_metal(
        top,
        side,
        this_pad_bbox,
        core_metal_bbox,
        stitch_layer,
        stitch_datatype
    )

    stitch_bbox_m5 = None
    if ENABLE_SIGNAL_M5_STITCHES:
        stitch_bbox_m5 = add_stitch_to_core_metal(
            top,
            side,
            this_pad_bbox,
            core_metal_bbox,
            power_m5_layer,
            power_m5_datatype
        )

    print(
        f"{name}: side={side} "
        f"pad_bbox={this_pad_bbox} "
        f"core_bbox={core_metal_bbox} "
        f"stitch_m6={stitch_bbox_m6} "
        f"stitch_m5={stitch_bbox_m5}"
    )

# ============================================================
# Add power pad connections
# ============================================================

for pad_id, net_name in power_pad_to_net.items():
    side, bl_x, bl_y = pads_by_id[pad_id]
    this_pad_bbox = pad_bbox_from_bl(side, bl_x, bl_y)

    if net_name == "VDD":
        # VDD is the outer ring.
        # Top/bottom connect to METAL5 ring.
        # Left/right connect to METAL6 ring.
        if side in ("top", "bottom"):
            target_bbox = find_nearest_inward_metal(
                side,
                this_pad_bbox,
                core_m5_bboxes
            )

            if target_bbox is None:
                print(f"WARNING: no VDD METAL5 target found for pad {pad_id}")
                continue

            connector_bbox = add_direct_power_connection(
                top,
                side,
                this_pad_bbox,
                target_bbox,
                power_m5_layer,
                power_m5_datatype
            )

            print(
                f"POWER {pad_id} {net_name}: direct METAL5 "
                f"pad_bbox={this_pad_bbox} target={target_bbox} connector={connector_bbox}"
            )

        elif side in ("left", "right"):
            # Do not use generic METAL6 power search for side pads.
            # L0/R7 are handled separately after this loop.
            print(
                f"SKIPPING generic METAL6 VDD connection for pad {pad_id}; "
                f"handled separately"
            )
            continue

        else:
            raise ValueError(f"Unexpected VDD pad side: {side}")

#    elif net_name == "VSS":
#        # VSS is the inner net. Do NOT draw across all METAL5.
#        # Extend all matching inward VSS METAL5 stripes to the pad.
#        if side not in ("left", "right"):
#            print(f"WARNING: VSS pad {pad_id} on side {side} not supported by stripe extension")
#            continue

#        stripe_bboxes = find_inward_vss_metal5_stripes(
#            side,
#            this_pad_bbox,
#            vss_m5_bboxes,
#            die_center_y
#        )

#        if not stripe_bboxes:
#            print(f"WARNING: no inward VSS METAL5 stripes found for pad {pad_id}")
#            continue

#        for stripe_bbox in stripe_bboxes:
#            connector_bbox = extend_vss_stripe_to_pad(
#                top,
#                side,
#                this_pad_bbox,
#                stripe_bbox,
#                power_m5_layer,
#                power_m5_datatype
#            )

#            print(
#                f"POWER {pad_id} {net_name}: extended METAL5 stripe "
#                f"pad_bbox={this_pad_bbox} stripe={stripe_bbox} connector={connector_bbox}"
#            )

    elif net_name == "VSS":
        # VSS connects from the pad on METAL5 to the inner METAL6 VSS ring,
        # with M5-M6 vias added by add_m5_bridge_to_m6_ring_with_vias().
        target_bbox = find_vss_metal6_inner_ring(
            side,
            this_pad_bbox,
            core_m6_power_bboxes
        )

        if target_bbox is None:
            print(f"WARNING: no VSS inner METAL6 ring target found for pad {pad_id}")
            continue

        connector_bbox = add_m5_bridge_to_m6_ring_with_vias(
            top,
            side,
            this_pad_bbox,
            target_bbox,
            power_m5_layer,
            power_m5_datatype,
            power_via56_layer,
            power_via56_datatype
        )

        print(
            f"POWER {pad_id} {net_name}: METAL5 bridge to inner METAL6 ring with vias "
            f"pad_bbox={this_pad_bbox} target_m6={target_bbox} "
            f"bridge_and_vias={connector_bbox}"
        )

    else:
        raise ValueError(f"Unknown power net for pad {pad_id}: {net_name}")

# ============================================================
# Add explicit L0/R7 METAL6 VDD side-ring connections
# ============================================================

corner_vdd_m6_pads = ["L0", "R7"]

for pad_id in corner_vdd_m6_pads:
    side, bl_x, bl_y = pads_by_id[pad_id]
    this_pad_bbox = pad_bbox_from_bl(side, bl_x, bl_y)

    target_bbox = find_side_metal6_ring_for_corner_vdd(
        side,
        this_pad_bbox,
        core_m6_power_bboxes
    )

    if target_bbox is None:
        print(
            f"WARNING: no explicit METAL6 side-ring target found for "
            f"{pad_id} pad_bbox={this_pad_bbox}"
        )
        continue

    connector_bbox = add_direct_power_connection(
        top,
        side,
        this_pad_bbox,
        target_bbox,
        power_m6_layer,
        power_m6_datatype
    )

    print(
        f"POWER {pad_id} VDD: explicit METAL6 side-ring connection "
        f"pad_bbox={this_pad_bbox} target={target_bbox} connector={connector_bbox}"
    )


# ============================================================
# Write full hierarchy
# ============================================================

all_cells = top.get_dependencies(True)
all_cells.add(top)

gdspy.write_gds(OUT_GDS, cells=all_cells)

print(f"Created {OUT_GDS}")

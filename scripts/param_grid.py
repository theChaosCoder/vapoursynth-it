"""Single source of truth for the oracle parameter grids.

This grid used to be copy-pasted across four files (regen_golden.py,
gen_upstream_golden.py, compare_upstream.py, test_upstream_compare.py) with
only comments keeping them aligned — an edit in one file silently shrank
oracle coverage elsewhere. Import it instead.

UPSTREAM_GRID: (fixture, fps, threshold, pthreshold) combos the C reference
can act as an oracle for. The reference hardcodes ref=TOP,
diMode=one_field and blend=0, so those axes cannot appear here.

GOLDEN_GRID: (fixture, fps, threshold, pthreshold, ref, blend, diMode) —
superset pinned by the self-referential golden hashes
(tests/integration/fixtures/golden_hashes.txt). The extra ref/blend/diMode
rows have no external oracle; their goldens pin the port's own behaviour
against unintended drift.
"""

UPSTREAM_GRID = [
    ("constant_color",     30, 20, 75),
    ("constant_color",     24, 20, 75),
    ("constant_large",     24, 20, 75),
    ("constant_mod16",     24, 20, 75),
    ("two_frame_telecine", 30, 20, 75),
    ("two_frame_telecine", 24, 20, 75),
    ("interlaced_stripes", 30, 20, 75),
    ("interlaced_stripes", 24, 20, 75),
    ("two_frame_telecine", 24, 10, 50),  # threshold sensitivity
    ("two_frame_telecine", 24, 40, 150),
]

GOLDEN_GRID = [
    # The upstream-oracled cells, at their default ref/blend/diMode.
    *[t + ("TOP", 0, 3) for t in UPSTREAM_GRID],
    # ref axis — no external oracle (upstream hardcodes TOP).
    ("two_frame_telecine", 24, 20, 75, "BOTTOM", 0, 3),
    ("two_frame_telecine", 24, 20, 75, "ALL",    0, 3),
    ("two_frame_telecine", 24, 20, 75, "NONE",   0, 3),
    ("interlaced_stripes", 30, 20, 75, "BOTTOM", 0, 3),
    # diMode axis — interlaced_stripes classifies every frame ip='I', so
    # these exercise the deinterlace dispatch (diMode=3 is pinned above).
    ("interlaced_stripes", 30, 20, 75, "TOP", 0, 0),
    ("interlaced_stripes", 30, 20, 75, "TOP", 0, 1),
    ("interlaced_stripes", 30, 20, 75, "TOP", 0, 2),
    ("interlaced_stripes", 24, 20, 75, "TOP", 0, 1),
    # blend axis — motion_flicker is the only fixture whose 5-frame blocks
    # pass shouldBlendBlock.
    ("motion_flicker", 24, 20, 75, "TOP", 0, 3),
    ("motion_flicker", 24, 20, 75, "TOP", 1, 3),
]

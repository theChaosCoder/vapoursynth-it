"""Golden-hash comparison: Zig port vs the upstream C++ reference's *canonical*
output.

The C reference plugin (`it.IT`, reference/vapoursynth-cpp-api4/libit.so) is
NON-DETERMINISTIC: for identical input it emits 2-3 different outputs depending
on accumulated VapourSynth core state (proven during the flake investigation —
`num_threads=1` and a large cache do not fix it). zit.IT is provably
deterministic (see test_determinism.py) and matches the C reference's canonical
output when the reference is rendered in a clean, isolated state.

So rather than comparing against the live (flaky) reference, this test compares
zit against committed golden hashes captured from the C reference in isolation,
where `zit == reference` was asserted at capture time. That keeps the "zit
matches the upstream" guarantee while being fully deterministic — the live C
comparison lives in the generator and is re-run only on demand:

    uv run python scripts/gen_upstream_golden.py
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest
import vapoursynth as vs

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import gen_testclip                              # noqa: E402

GOLDEN_PATH = Path(__file__).resolve().parent / "upstream_golden.json"

# Same matrix scripts/gen_upstream_golden.py captures — keep them in sync.
PARAM_GRID = [
    ("constant_color",     30, 20, 75),
    ("constant_color",     24, 20, 75),
    ("constant_large",     24, 20, 75),
    ("constant_mod16",     24, 20, 75),
    ("two_frame_telecine", 30, 20, 75),
    ("two_frame_telecine", 24, 20, 75),
    ("interlaced_stripes", 30, 20, 75),
    ("interlaced_stripes", 24, 20, 75),
    ("two_frame_telecine", 24, 10, 50),
    ("two_frame_telecine", 24, 40, 150),
]

_GOLDEN: dict[str, list[str]] = (
    json.loads(GOLDEN_PATH.read_text()) if GOLDEN_PATH.exists() else {}
)


def _hash(clip: vs.VideoNode, n: int) -> str:
    f = clip.get_frame(n)
    h = hashlib.md5()
    for p in range(f.format.num_planes):
        h.update(bytes(f[p]))
    return h.hexdigest()


@pytest.mark.parametrize("fixture_name,fps,threshold,pthreshold", PARAM_GRID)
def test_zig_matches_golden(core, fixture_name, fps, threshold, pthreshold):
    key = f"{fixture_name}-{fps}-{threshold}-{pthreshold}"
    golden = _GOLDEN.get(key)
    assert golden is not None, (
        f"no golden for {key} — run `uv run python scripts/gen_upstream_golden.py`"
    )
    src = gen_testclip.FIXTURES[fixture_name]()
    zig = core.zit.IT(src, fps=fps, threshold=threshold, pthreshold=pthreshold)

    assert zig.num_frames == len(golden), (
        f"{key}: frame count {zig.num_frames} != golden {len(golden)}"
    )
    mismatches = [
        f"  frame {n:04d}: zig={zh} golden={golden[n]}"
        for n in range(zig.num_frames)
        if (zh := _hash(zig, n)) != golden[n]
    ]
    assert not mismatches, (
        f"{key}: zit diverged from the golden reference:\n" + "\n".join(mismatches)
    )

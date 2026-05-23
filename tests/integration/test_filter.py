"""End-to-end regression and property tests for the `zit` plugin.

Two complementary axes:

1.  **Property tests** — invariants that hold by construction regardless of
    pixel content. These catch the most damaging regressions (crashes,
    frame-count drift, format corruption, non-determinism).
2.  **Golden-hash tests** — md5 of every output frame against a pinned
    fixture file. These pin the *current* behaviour as a regression guard.
    Truly independent bit-equivalence against the upstream C++ IT plugin
    is currently deferred (see docs/upstream_reference.md for the why);
    until that's in place, intentional algorithm changes need to be
    accompanied by a deliberate `scripts/regen_golden.py` run plus a
    review of the diff.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
import vapoursynth as vs

GOLDEN = Path(__file__).parent / "fixtures" / "golden_hashes.txt"


def _frame_md5(clip: vs.VideoNode, n: int) -> str:
    f = clip.get_frame(n)
    h = hashlib.md5()
    for p in range(f.format.num_planes):
        h.update(bytes(f[p]))
    return h.hexdigest()


def _load_golden() -> dict[tuple[str, int, int, int, int], str]:
    out: dict[tuple[str, int, int, int, int], str] = {}
    for line in GOLDEN.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fx, fps, th, pth, idx, md5 = line.split("|")
        out[(fx, int(fps), int(th), int(pth), int(idx))] = md5
    return out


GOLDEN_HASHES = _load_golden()


# ---------------------------------------------------------------------------
# Property tests — invariants
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("fixture_name", [
    "constant_color", "constant_large", "constant_mod16",
    "two_frame_telecine", "interlaced_stripes",
])
def test_fps30_keeps_frame_count(core, fixtures, fixture_name):
    src = fixtures[fixture_name]()
    out = core.zit.IT(src, fps=30)
    assert out.num_frames == src.num_frames


@pytest.mark.parametrize("fixture_name,expected", [
    ("constant_color", 24),       # 30 -> 24
    ("constant_large", 24),       # 30 -> 24
    ("constant_mod16", 16),       # 20 -> 16
    ("two_frame_telecine", 16),   # 20 -> 16
    ("interlaced_stripes", 16),   # 20 -> 16
])
def test_fps24_decimates_5_to_4(core, fixtures, fixture_name, expected):
    src = fixtures[fixture_name]()
    out = core.zit.IT(src, fps=24)
    assert out.num_frames == expected


def test_fps24_rescales_fps_metadata(core, fixtures):
    src = fixtures["constant_color"]()
    out = core.zit.IT(src, fps=24)
    # 30000/1001 * 4/5 == 24000/1001
    assert (out.fps_num, out.fps_den) == (24000, 1001)


def test_output_format_matches_input(core, fixtures):
    src = fixtures["constant_color"]()
    out = core.zit.IT(src)
    assert out.format.id == src.format.id
    assert out.width == src.width
    assert out.height == src.height


def test_determinism_same_clip_twice(core, fixtures):
    src = fixtures["two_frame_telecine"]()
    out_a = core.zit.IT(src, fps=24)
    out_b = core.zit.IT(src, fps=24)
    for n in range(out_a.num_frames):
        assert _frame_md5(out_a, n) == _frame_md5(out_b, n), f"non-deterministic at frame {n}"


# ---------------------------------------------------------------------------
# Validation error paths
# ---------------------------------------------------------------------------

def test_rejects_rgb_input(core):
    src = core.std.BlankClip(format=vs.RGB24, length=5, width=128, height=96)
    with pytest.raises(vs.Error, match="YUV420P8"):
        core.zit.IT(src).get_frame(0)


def test_rejects_invalid_fps(core, fixtures):
    src = fixtures["constant_color"]()
    with pytest.raises(vs.Error, match="fps must be 24 or 30"):
        core.zit.IT(src, fps=60)


# ---------------------------------------------------------------------------
# Golden-hash regression
# ---------------------------------------------------------------------------

GOLDEN_BY_PARAMS: dict[tuple[str, int, int, int], dict[int, str]] = {}
for (fx, fps, th, pth, idx), md5 in GOLDEN_HASHES.items():
    GOLDEN_BY_PARAMS.setdefault((fx, fps, th, pth), {})[idx] = md5


@pytest.mark.parametrize("fixture_name,fps,threshold,pthreshold",
                        sorted(GOLDEN_BY_PARAMS.keys()))
def test_golden_hashes_match(core, fixtures, fixture_name, fps, threshold, pthreshold):
    src = fixtures[fixture_name]()
    out = core.zit.IT(src, fps=fps, threshold=threshold, pthreshold=pthreshold)
    expected = GOLDEN_BY_PARAMS[(fixture_name, fps, threshold, pthreshold)]
    assert len(expected) == out.num_frames, (
        f"golden hash count mismatch: {len(expected)} pinned, {out.num_frames} produced"
    )
    mismatches: list[str] = []
    for n in range(out.num_frames):
        actual = _frame_md5(out, n)
        if actual != expected[n]:
            mismatches.append(f"  frame {n:04d}: expected {expected[n]} got {actual}")
    assert not mismatches, "\n".join(mismatches)

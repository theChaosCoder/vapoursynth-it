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


def _load_golden() -> dict[tuple[str, int, int, int, str, int, int, int], str]:
    out: dict[tuple[str, int, int, int, str, int, int, int], str] = {}
    for line in GOLDEN.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fx, fps, th, pth, ref, blend, dimode, idx, md5 = line.split("|")
        out[(fx, int(fps), int(th), int(pth), ref, int(blend), int(dimode), int(idx))] = md5
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


@pytest.mark.parametrize("num,den,expected", [
    (25, 2, (10, 1)),
    (25, 4, (5, 1)),
    (1, 4, (1, 5)),
    (29, 2, (58, 5)),
    (9223372036854775805, 1, (7378697629483820644, 1)),
])
def test_fps24_reduces_rate_before_checking_overflow(core, num, den, expected):
    src = core.std.BlankClip(width=128, height=96, length=10,
                            format=vs.YUV420P8, fpsnum=num, fpsden=den)
    out = core.zit.IT(src)
    assert (out.fps_num, out.fps_den) == expected
    props = out.get_frame(0).props
    assert (props["_DurationNum"], props["_DurationDen"]) == expected[::-1]


@pytest.mark.parametrize("num,den", [(2**63 - 1, 1), (1, 2**63 - 1)])
def test_fps24_rejects_unrepresentable_rate(core, num, den):
    src = core.std.BlankClip(width=128, height=96, length=10,
                            format=vs.YUV420P8, fpsnum=num, fpsden=den)
    with pytest.raises(vs.Error, match="output frame rate exceeds"):
        core.zit.IT(src)
    out = core.zit.IT(src, fps=30)
    assert (out.fps_num, out.fps_den) == (num, den)


def test_output_format_matches_input(core, fixtures):
    src = fixtures["constant_color"]()
    out = core.zit.IT(src)
    assert out.format.id == src.format.id
    assert out.width == src.width
    assert out.height == src.height


# ---------------------------------------------------------------------------
# Frame properties
# ---------------------------------------------------------------------------

def test_standard_frame_props_progressive(core, fixtures):
    """After IVTC the output is progressive: _FieldBased must be 0, and the
    duration must reflect the output (not input) framerate."""
    src = fixtures["constant_color"]()
    out = core.zit.IT(src, fps=24)
    f = out.get_frame(0)
    p = dict(f.props)
    assert p["_FieldBased"] == 0, "output of IVTC must be marked progressive"
    # fps=24 -> 24000/1001, so duration = 1001/24000 sec per frame
    assert p["_DurationNum"] == 1001
    assert p["_DurationDen"] == 24000


def test_combed_flag_set_per_frame(core, fixtures):
    """`_Combed` reflects the algorithm's ip='P'/'I' classification per frame."""
    src = fixtures["constant_color"]()
    out = core.zit.IT(src)
    # Constant clip -> every frame ip='P', so _Combed=0.
    for n in range(out.num_frames):
        assert out.get_frame(n).props["_Combed"] == 0


def test_source_props_are_inherited(core, fixtures):
    """Source-side metadata (`_SARNum`, `_Matrix`, etc.) must survive the filter."""
    src = fixtures["constant_color"]()
    src_with_meta = core.std.SetFrameProp(src, prop="_SARNum", intval=1)
    src_with_meta = core.std.SetFrameProp(src_with_meta, prop="_SARDen", intval=1)
    src_with_meta = core.std.SetFrameProp(src_with_meta, prop="_Matrix", intval=6)
    out = core.zit.IT(src_with_meta)
    p = dict(out.get_frame(0).props)
    assert p.get("_SARNum") == 1
    assert p.get("_SARDen") == 1
    assert p.get("_Matrix") == 6


def test_it_diagnostic_props_present(core, fixtures):
    """The custom `IT*` diagnostic props must be set on every output frame."""
    src = fixtures["two_frame_telecine"]()
    out = core.zit.IT(src, fps=24)
    p = dict(out.get_frame(0).props)
    for key in ("ITMatch", "ITMflag", "ITIpFlag", "ITIvC", "ITIvP", "ITIvN",
                "ITIvM", "ITDiffP0", "ITDiffP1", "ITDiffS0", "ITDiffS1",
                "ITBlended"):
        assert key in p, f"missing diagnostic prop: {key}"
    # Char-typed props are auto-decoded by the VS Python wrapper.
    def _to_str(v):
        return v.decode("utf8") if isinstance(v, (bytes, bytearray)) else v
    assert _to_str(p["ITMatch"]) in {"C", "P", "N", "c", "p", "n", "U"}
    assert _to_str(p["ITIpFlag"]) in {"P", "I", "U"}


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
    with pytest.raises(vs.Error, match="(YUV|integer)"):
        core.zit.IT(src).get_frame(0)


def test_rejects_invalid_fps(core, fixtures):
    src = fixtures["constant_color"]()
    with pytest.raises(vs.Error, match="fps must be 24 or 30"):
        core.zit.IT(src, fps=60)


def test_rejects_420_height_not_multiple_of_4(core):
    """height % 4 == 2 (e.g. NTSC 720x486) makes the 4:2:0 field-interleaved
    chroma row mapping run one row past the chroma plane (OOB reads/writes,
    uninitialized last chroma row), so it must be refused at creation."""
    src = core.std.BlankClip(format=vs.YUV420P8, length=5, width=720, height=486)
    with pytest.raises(vs.Error, match="multiple of 4"):
        core.zit.IT(src)


def test_accepts_422_height_not_multiple_of_4(core):
    """4:2:2 chroma is full-height, so the mod-4 restriction must not apply."""
    src = core.std.BlankClip(format=vs.YUV422P8, length=10, width=720, height=486)
    out = core.zit.IT(src)
    out.get_frame(0)
    out.get_frame(out.num_frames - 1)


@pytest.mark.parametrize("kwargs", [
    {"threshold": -1},
    {"threshold": 100_001},
    {"pthreshold": -1},
    {"pthreshold": 100_001},
])
def test_rejects_out_of_range_thresholds(core, fixtures, kwargs):
    """Unvalidated values overflowed adjPara's i32 math (UB in ReleaseFast)."""
    src = fixtures["constant_color"]()
    with pytest.raises(vs.Error, match="must be in"):
        core.zit.IT(src, **kwargs)


def test_rejects_variable_frame_rate(core):
    """fpsNum == 0 marks VFR; decimation and _Duration* props are
    meaningless there."""
    src = core.std.BlankClip(format=vs.YUV420P8, length=10, width=128, height=96,
                             fpsnum=0, fpsden=1)
    with pytest.raises(vs.Error, match="constant frame rate"):
        core.zit.IT(src)


def test_rejects_fps24_on_too_short_clip(core):
    """numFrames*4/5 == 0 for a single-frame clip — createVideoFilter would
    choke on a 0-frame VideoInfo, so refuse it with a clear message."""
    src = core.std.BlankClip(format=vs.YUV420P8, length=1, width=128, height=96)
    with pytest.raises(vs.Error, match="at least 2"):
        core.zit.IT(src, fps=24)


# ---------------------------------------------------------------------------
# Golden-hash regression
# ---------------------------------------------------------------------------

GOLDEN_BY_PARAMS: dict[tuple[str, int, int, int, str, int, int], dict[int, str]] = {}
for (fx, fps, th, pth, ref, blend, dimode, idx), md5 in GOLDEN_HASHES.items():
    GOLDEN_BY_PARAMS.setdefault((fx, fps, th, pth, ref, blend, dimode), {})[idx] = md5


@pytest.mark.parametrize("fixture_name,fps,threshold,pthreshold,ref,blend,dimode",
                        sorted(GOLDEN_BY_PARAMS.keys()))
def test_golden_hashes_match(core, fixtures, fixture_name, fps, threshold, pthreshold,
                             ref, blend, dimode):
    src = fixtures[fixture_name]()
    out = core.zit.IT(src, fps=fps, threshold=threshold, pthreshold=pthreshold,
                      ref=ref, blend=blend, diMode=dimode)
    expected = GOLDEN_BY_PARAMS[(fixture_name, fps, threshold, pthreshold, ref, blend, dimode)]
    assert len(expected) == out.num_frames, (
        f"golden hash count mismatch: {len(expected)} pinned, {out.num_frames} produced"
    )
    mismatches: list[str] = []
    for n in range(out.num_frames):
        actual = _frame_md5(out, n)
        if actual != expected[n]:
            mismatches.append(f"  frame {n:04d}: expected {expected[n]} got {actual}")
    assert not mismatches, "\n".join(mismatches)

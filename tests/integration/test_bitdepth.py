"""End-to-end validation of the 10/12/16-bit YUV420 pipelines.

Three layers:

1.  **Acceptance** — the filter accepts each bit-depth, preserves format,
    and produces the expected output frame count.
2.  **Flat-input identity** — for a flat-color clip, IT(...) returns the
    same flat color, exact (within ±1 LSB) at every supported bit-depth.
3.  **Cross-bit-depth consistency** — for an interlaced-stripes pattern
    where the 10-bit input is the 8-bit input left-shifted by 2, the
    10-bit IT output must equal the 8-bit IT output left-shifted by 2,
    pixel-for-pixel. Same for 12-bit (<<4) and 16-bit (<<8). This is the
    strongest validation we can do without an external high-bit-depth
    oracle.

Run via:

    pytest tests/integration/test_bitdepth.py
"""

from __future__ import annotations

import struct

import pytest
import vapoursynth as vs


# (depth, vs format, shift) — `shift` is how much to left-shift the 8-bit
# baseline values to land in this depth's normal range.
DEPTHS = [
    (10, vs.YUV420P10, 2),
    (12, vs.YUV420P12, 4),
    (16, vs.YUV420P16, 8),
]


def _read_luma_u8_or_u16(frame: vs.VideoFrame, bits: int, n_samples: int = 16) -> list[int]:
    luma = bytes(frame[0])
    if bits == 8:
        return list(luma[:n_samples])
    return [struct.unpack_from("<H", luma, 2 * i)[0] for i in range(n_samples)]


def _make_flat_clip(core: vs.Core, vs_fmt: int, color: int, length: int = 20) -> vs.VideoNode:
    return core.std.BlankClip(
        format=vs_fmt,
        width=128,
        height=96,
        length=length,
        fpsnum=30000,
        fpsden=1001,
        color=[color, color, color],
    )


def _make_interlaced_stripes(core: vs.Core, vs_fmt: int, bright: int, dark: int, length: int = 30) -> vs.VideoNode:
    """Classic interlaced-stripes pattern (even rows bright, odd rows dark)
    parameterized by bit-depth color values. Mirrors gen_testclip's
    8-bit `interlaced_stripes` so the cross-bit-depth test compares like
    with like."""
    b = core.std.BlankClip(format=vs_fmt, width=128, height=96, length=length, fpsnum=30000, fpsden=1001, color=[bright, bright, bright])
    d = core.std.BlankClip(format=vs_fmt, width=128, height=96, length=length, fpsnum=30000, fpsden=1001, color=[dark, dark, dark])
    sep_b = core.std.SeparateFields(b, tff=True)
    sep_d = core.std.SeparateFields(d, tff=True)
    fields = core.std.Interleave([sep_b[::2], sep_d[1::2]])
    return core.std.DoubleWeave(fields, tff=True)[::2]


# ---------------------------------------------------------------------------
# Layer 1: acceptance
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bits,vs_fmt,_", DEPTHS)
def test_accepts_and_preserves_format(core, bits, vs_fmt, _):
    clip = _make_flat_clip(core, vs_fmt, color=1 << (bits - 1))
    out = core.zit.IT(clip, fps=30)
    assert out.format.id == vs_fmt
    assert out.format.bits_per_sample == bits
    assert out.width == clip.width
    assert out.height == clip.height
    assert out.num_frames == clip.num_frames


@pytest.mark.parametrize("bits,vs_fmt,_", DEPTHS)
def test_fps24_decimates(core, bits, vs_fmt, _):
    clip = _make_flat_clip(core, vs_fmt, color=1 << (bits - 1), length=20)
    out = core.zit.IT(clip, fps=24)
    assert out.num_frames == 16  # 20 * 4/5
    assert out.format.bits_per_sample == bits


# ---------------------------------------------------------------------------
# Layer 2: flat-input identity
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bits,vs_fmt,_", DEPTHS)
@pytest.mark.parametrize("fps", [30, 24])
@pytest.mark.parametrize("dimode", [1, 2, 3])
def test_flat_input_returns_flat_output(core, bits, vs_fmt, _, fps, dimode):
    color = 1 << (bits - 1)  # mid-range
    clip = _make_flat_clip(core, vs_fmt, color, length=20)
    out = core.zit.IT(clip, fps=fps, diMode=dimode)
    # Check several frames so we exercise different match positions.
    for n in (0, out.num_frames // 2, out.num_frames - 1):
        samples = _read_luma_u8_or_u16(out.get_frame(n), bits)
        for v in samples:
            assert abs(v - color) <= 1, f"bits={bits} fps={fps} diMode={dimode} frame={n}: expected ~{color}, got {v}"


# ---------------------------------------------------------------------------
# Layer 3: cross-bit-depth consistency
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bits,vs_fmt,shift", DEPTHS)
@pytest.mark.parametrize("params", [
    {},
    {"fps": 24},
    {"diMode": 1},
    {"diMode": 2},
    {"fps": 24, "blend": True},
    {"ref": "ALL"},
])
def test_high_bit_depth_matches_shifted_8bit(core, bits, vs_fmt, shift, params):
    """Run IT on 8-bit and on (8-bit << shift) input; the high-bit-depth
    output must equal the 8-bit output left-shifted, exact."""
    bright_8, dark_8 = 220, 20
    bright_n, dark_n = bright_8 << shift, dark_8 << shift

    clip8 = _make_interlaced_stripes(core, vs.YUV420P8, bright_8, dark_8, length=30)
    clip_n = _make_interlaced_stripes(core, vs_fmt, bright_n, dark_n, length=30)
    out8 = core.zit.IT(clip8, **params)
    out_n = core.zit.IT(clip_n, **params)

    assert out8.num_frames == out_n.num_frames

    # Sample a representative set of frames.
    frame_indices = [0, out8.num_frames // 3, out8.num_frames // 2, out8.num_frames - 1]
    for n in frame_indices:
        f8 = out8.get_frame(n)
        f_n = out_n.get_frame(n)
        # Compare every plane bit-for-bit (after scaling 8-bit up).
        for p in range(f8.format.num_planes):
            luma8 = bytes(f8[p])
            luma_n = bytes(f_n[p])
            expected_len = len(luma8) * (2 if bits > 8 else 1)
            assert len(luma_n) == expected_len, f"plane {p} byte-length mismatch"
            for i, v8 in enumerate(luma8):
                vn = struct.unpack_from("<H", luma_n, 2 * i)[0] if bits > 8 else luma_n[i]
                expected = v8 << shift
                assert vn == expected, (
                    f"bits={bits} params={params} frame={n} plane={p} i={i}: "
                    f"expected {expected} (= {v8} << {shift}), got {vn}"
                )


# ---------------------------------------------------------------------------
# Layer 4: validation — invalid formats are rejected
# ---------------------------------------------------------------------------

def test_rejects_yuv422(core):
    clip = core.std.BlankClip(format=vs.YUV422P8, width=128, height=96, length=10)
    with pytest.raises(vs.Error, match="(subsampling|4:2:0|4:4:4)"):
        core.zit.IT(clip)


def test_rejects_yuv444_for_now(core):
    """YUV444 will arrive in Phase 2; until then validateInput must reject it."""
    clip = core.std.BlankClip(format=vs.YUV444P8, width=128, height=96, length=10)
    with pytest.raises(vs.Error, match="(subsampling|4:2:0|4:4:4)"):
        core.zit.IT(clip)


def test_rejects_9bit(core):
    """We accept exactly 8/10/12/16 — odd depths like 9-bit must be refused."""
    clip = core.std.BlankClip(format=vs.YUV420P9, width=128, height=96, length=10)
    with pytest.raises(vs.Error, match="(bit|8/10/12/16)"):
        core.zit.IT(clip)


def test_rejects_float(core):
    clip = core.std.BlankClip(format=vs.YUV420PS, width=128, height=96, length=10)
    with pytest.raises(vs.Error, match="(integer|YUV)"):
        core.zit.IT(clip)

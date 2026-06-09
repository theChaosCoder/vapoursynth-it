"""End-to-end validation of the 10/12/16-bit YUV420 pipelines.

Layers:

1.  **Acceptance** — the filter accepts each bit-depth, preserves format,
    and produces the expected output frame count.
2.  **Flat-input identity** — for a flat-color clip, IT(...) returns the
    same flat color, exact (within ±1 LSB) at every supported bit-depth.
3.  **Cross-bit-depth consistency** — for an interlaced-stripes pattern
    where the 10-bit input is the 8-bit input left-shifted by 2, the
    10-bit IT output must equal the 8-bit IT output left-shifted by 2,
    pixel-for-pixel. Same for 12-bit (<<4) and 16-bit (<<8).
4.  **Validation** — invalid formats / bit-depths are rejected.
5.  **Sub-8-bit precision (oracle-free)** — Layer 3 zeroes every low
    `(bits-8)` bit, so it never exercises the precision code. These tests
    pin what is checkable without a high-bit-depth oracle: exact low-bit
    round-trip, no silent truncation to 8-bit, and in-range averaging.

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

def test_accepts_yuv422(core):
    """4:2:2 is supported: a flat clip stays flat across all planes, and an
    interlaced clip runs the deinterlacer without error (no 4:2:2 oracle)."""
    color = 110
    out = core.zit.IT(_make_flat_clip(core, vs.YUV422P8, color))
    f = out.get_frame(out.num_frames // 2)
    assert all(abs(b - color) <= 1 for b in bytes(f[0])[:64]), "4:2:2 luma not flat"
    assert all(abs(b - color) <= 1 for b in bytes(f[1])[:32]), "4:2:2 U not flat"
    assert all(abs(b - color) <= 1 for b in bytes(f[2])[:32]), "4:2:2 V not flat"
    stripes = _make_interlaced_stripes(core, vs.YUV422P8, 220, 20, length=20)
    sf = core.zit.IT(stripes).get_frame(0)
    assert all(0 <= b <= 255 for b in bytes(sf[0])[:128]), "4:2:2 interlaced out of range"


@pytest.mark.parametrize("dimode", [0, 1, 2, 3])
def test_yuv444_planes_stay_equal(core, dimode):
    """4:4:4 with U=V=Y in must give U=V=Y out: the chroma kernels process
    identically to luma at full resolution, across every diMode path. (width
    128 -> stride 128 -> no padding, so the plane bytes compare cleanly.)"""
    clip = _make_interlaced_stripes(core, vs.YUV444P8, bright=220, dark=20, length=30)
    out = core.zit.IT(clip, diMode=dimode)
    for n in (0, out.num_frames // 2, out.num_frames - 1):
        f = out.get_frame(n)
        y, u, v = bytes(f[0]), bytes(f[1]), bytes(f[2])
        assert y == u == v, f"diMode={dimode} frame={n}: 4:4:4 planes diverged"


def test_rejects_9bit(core):
    """We accept exactly 8/10/12/16 — odd depths like 9-bit must be refused."""
    clip = core.std.BlankClip(format=vs.YUV420P9, width=128, height=96, length=10)
    with pytest.raises(vs.Error, match="(bit|8/10/12/16)"):
        core.zit.IT(clip)


def test_rejects_float(core):
    clip = core.std.BlankClip(format=vs.YUV420PS, width=128, height=96, length=10)
    with pytest.raises(vs.Error, match="(integer|YUV)"):
        core.zit.IT(clip)


# ---------------------------------------------------------------------------
# Layer 5: sub-8-bit precision (oracle-free)
# ---------------------------------------------------------------------------
#
# The cross-bit-depth test (Layer 3) feeds `8bit << shift`, so every low
# `(bits-8)` bit is zero — the precision-handling code (wide diffs,
# `>> (bits-8)` downscales, `<< (bits-8)` thresholds) collapses to the 8-bit
# result and is never actually exercised. There is no external high-bit-depth
# oracle, so the tests below pin the properties we *can* assert without one:
# low bits survive the output path exactly, two inputs that are 8-bit-identical
# but differ in the low bits produce correspondingly different output (nothing
# silently truncates to 8 bit), and the wide-precision averaging paths stay in
# range on low-bit input. Correctness of the *decision* math on sub-8-bit
# precision remains unverified by construction (it needs an oracle Layer 3
# can't provide).

# bit-depth -> a mid-range value with non-zero low bits set
LOWBIT_VALUES = [
    (10, vs.YUV420P10, 0x2A7),   # 679;   >>2 = 169
    (12, vs.YUV420P12, 0xA5F),   # 2655;  >>4 = 165
    (16, vs.YUV420P16, 0xABCD),  # 43981; >>8 = 171
]


@pytest.mark.parametrize("bits,vs_fmt,value", LOWBIT_VALUES)
@pytest.mark.parametrize("fps", [30, 24])
def test_hbd_low_bits_preserved_exact(core, bits, vs_fmt, value, fps):
    """A flat clip whose value has low bits set must round-trip *exactly*.

    Flat input is judged progressive (ip='P'), so the output is a pure field
    copy: the value must survive bit-for-bit, not get truncated to 8-bit."""
    clip = _make_flat_clip(core, vs_fmt, value, length=20)
    out = core.zit.IT(clip, fps=fps)
    for n in (0, out.num_frames // 2, out.num_frames - 1):
        for v in _read_luma_u8_or_u16(out.get_frame(n), bits, n_samples=32):
            assert v == value, f"bits={bits} fps={fps} frame={n}: expected {value}, got {v}"


@pytest.mark.parametrize("bits,vs_fmt", [(b, f) for b, f, _ in LOWBIT_VALUES])
def test_hbd_low_bits_are_not_truncated(core, bits, vs_fmt):
    """Two flat clips identical after `>> (bits-8)` but differing in the low
    bits must produce *different* output. If anything in the pipeline silently
    rounded pixels to 8-bit, both would collapse to the same value."""
    shift = bits - 8
    base = 0xAB << shift              # 8-bit value 0xAB, low bits zero
    v_hi = base | ((1 << shift) - 1)  # same 8-bit value, all low bits set
    assert (base >> shift) == (v_hi >> shift)  # 8-bit-identical by construction
    assert base != v_hi

    out_lo = core.zit.IT(_make_flat_clip(core, vs_fmt, base, length=12), fps=30)
    out_hi = core.zit.IT(_make_flat_clip(core, vs_fmt, v_hi, length=12), fps=30)
    s_lo = _read_luma_u8_or_u16(out_lo.get_frame(0), bits)
    s_hi = _read_luma_u8_or_u16(out_hi.get_frame(0), bits)
    assert s_lo != s_hi, f"bits={bits}: low bits truncated — {base}/{v_hi} collapsed to {s_lo}"
    assert all(v == base for v in s_lo)
    assert all(v == v_hi for v in s_hi)


@pytest.mark.parametrize("bits,vs_fmt,shift", DEPTHS)
@pytest.mark.parametrize("dimode", [1, 2, 3])
def test_hbd_lowbit_interlaced_stays_in_range(core, bits, vs_fmt, shift, dimode):
    """Interlaced content with non-zero low bits drives the wide-precision
    averaging paths (deinterlace / simple-blur / one-field). No oracle, but
    every output sample must stay within [0, 2**bits) — catches overflow or a
    too-narrow accumulator in the blend math on real high-bit-depth input."""
    bright = (220 << shift) | ((1 << shift) - 1)
    dark = (20 << shift) | 1
    clip = _make_interlaced_stripes(core, vs_fmt, bright, dark, length=30)
    out = core.zit.IT(clip, diMode=dimode)
    hi = 1 << bits
    for n in (0, out.num_frames // 2, out.num_frames - 1):
        samples = _read_luma_u8_or_u16(out.get_frame(n), bits, n_samples=64)
        assert all(0 <= v < hi for v in samples), \
            f"bits={bits} diMode={dimode} frame={n}: out of range {samples}"

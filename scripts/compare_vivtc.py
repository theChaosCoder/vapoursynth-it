#!/usr/bin/env python3
"""Indirect comparison of zit against VIVTC (VFM + VDecimate).

VIVTC and IT are *different* IVTC algorithms — VIVTC was ported from
Donald Graft's TIVTC and uses a different field-match scoring heuristic.
We don't expect byte-identical output. What we *do* expect is that on
properly telecined NTSC source most output frames either match
bit-for-bit or differ only on a small minority of pixels — and that
both filters preserve frame counts (fps=30: N in, N out; fps=24: N in,
floor(N*4/5) out).

This script:
  1. Runs a 200-frame excerpt of a VOB through both filters at fps=30
     (zit) vs VFM (vivtc) and at fps=24 (zit) vs VFM→VDecimate (vivtc).
  2. Reports per-frame md5 matches, pixel-level diff statistics, and
     frame-count agreement.
  3. Sweeps every zit parameter combo and prints output hash signatures
     so we can see *which* options actually take effect.
  4. Times both pipelines over a 500-frame slice to compare speed.
"""

from __future__ import annotations

import hashlib
import sys
import time
from pathlib import Path

import numpy as np
import vapoursynth as vs

ROOT = Path(__file__).resolve().parent.parent
ZIG = ROOT / "zig-out" / "lib" / "libzit.so"


def hash_frame(clip: vs.VideoNode, n: int) -> str:
    f = clip.get_frame(n)
    h = hashlib.md5()
    for p in range(f.format.num_planes):
        h.update(bytes(f[p]))
    return h.hexdigest()


def diff_stats(a: vs.VideoNode, b: vs.VideoNode, n: int) -> tuple[int, int, int]:
    """Per-frame stats: (#different pixels in Y, total Y pixels, max abs diff)."""
    fa = a.get_frame(n)
    fb = b.get_frame(n)
    ya = np.asarray(fa[0]).astype(np.int16)
    yb = np.asarray(fb[0]).astype(np.int16)
    d = np.abs(ya - yb)
    return int((d > 0).sum()), int(d.size), int(d.max())


def section(title: str) -> None:
    print()
    print("=" * 72)
    print(title)
    print("=" * 72)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} <path-to-telecined-NTSC-source>", file=sys.stderr)
        return 1
    src_path = Path(argv[1])
    if not src_path.exists():
        print(f"missing: {src_path}", file=sys.stderr)
        return 1

    core = vs.core
    core.std.LoadPlugin(str(ZIG))

    full = core.bs.VideoSource(str(src_path))
    src = full[0:200]
    src500 = full[0:500]
    print(f"source: {src_path.name} {src.width}x{src.height} "
          f"fps={src.fps_num}/{src.fps_den}")

    # ------------------------------------------------------------------
    section("1. fps=30 (field-matching only) — zit vs VIVTC VFM order=1")
    zit_30 = core.zit.IT(src, fps=30)
    vfm = core.vivtc.VFM(src, order=1)  # TFF

    assert zit_30.num_frames == vfm.num_frames == src.num_frames, "frame counts differ"
    print(f"  frame counts ok: {zit_30.num_frames} both sides")

    md5_match = 0
    pixel_match = 0
    diffs_collected: list[tuple[int, int, int]] = []
    SAMPLE = list(range(0, 200, 10))   # 20 sampled frames for stats
    for n in SAMPLE:
        zh = hash_frame(zit_30, n)
        vh = hash_frame(vfm, n)
        if zh == vh:
            md5_match += 1
        else:
            d_count, d_total, d_max = diff_stats(zit_30, vfm, n)
            if d_count == 0:
                pixel_match += 1
            diffs_collected.append((n, d_count, d_max))

    print(f"  md5 match: {md5_match}/{len(SAMPLE)} sampled frames")
    if diffs_collected:
        print(f"  diff samples (frame, diff_pix, max_abs):")
        for n, c, m in diffs_collected[:8]:
            pct = 100 * c / (zit_30.width * zit_30.height)
            print(f"    n={n:3d}  pixels_diff={c:6d} ({pct:.1f}%)  max|Δ|={m:3d}")

    # ------------------------------------------------------------------
    section("2. fps=24 (decimation) — zit vs VIVTC VFM→VDecimate")
    zit_24 = core.zit.IT(src, fps=24)
    vivtc_24 = core.vivtc.VDecimate(core.vivtc.VFM(src, order=1))

    print(f"  zit_24:   {zit_24.num_frames} frames, fps={zit_24.fps_num}/{zit_24.fps_den}")
    print(f"  vivtc_24: {vivtc_24.num_frames} frames, fps={vivtc_24.fps_num}/{vivtc_24.fps_den}")
    cmp_len = min(zit_24.num_frames, vivtc_24.num_frames)

    md5_match = 0
    for n in range(0, cmp_len, 10):
        zh = hash_frame(zit_24, n)
        vh = hash_frame(vivtc_24, n)
        if zh == vh:
            md5_match += 1
    samples = (cmp_len + 9) // 10
    print(f"  md5 match: {md5_match}/{samples} sampled frames")

    # ------------------------------------------------------------------
    # Pick a high-motion 200-frame window. The opening of typical content is a
    # mostly-static title card so most params have no visible effect there.
    # Frames ~10000 are usually well into the actual programme.
    moving = full[10000:10200]
    section("3. zit parameter sweep on a high-motion excerpt [10000:10200]")
    print(f"  format: <params>  ->  hashes at frames spread across the window")
    grid = [
        {},                                            # default
        {"fps": 30},
        {"fps": 24, "threshold": 10},
        {"fps": 24, "threshold": 40},
        {"fps": 24, "pthreshold": 30},
        {"fps": 24, "pthreshold": 150},
        {"fps": 30, "ref": "TOP"},
        {"fps": 30, "ref": "BOTTOM"},
        {"fps": 30, "ref": "ALL"},
        {"fps": 30, "ref": "NONE"},
        {"fps": 24, "blend": 1},
        {"fps": 24, "diMode": 0},
        {"fps": 24, "diMode": 1},
        {"fps": 24, "diMode": 2},
        {"fps": 24, "diMode": 3},
    ]
    SIG_FRAMES = (10, 50, 90, 130, 170)
    for cfg in grid:
        try:
            out = core.zit.IT(moving, **cfg)
            label = ",".join(f"{k}={v}" for k, v in cfg.items()) or "(defaults)"
            sigs = []
            for fn in SIG_FRAMES:
                clamped = min(fn, out.num_frames - 1)
                sigs.append(hash_frame(out, clamped)[:8])
            print(f"  {label:42s}  " + " ".join(sigs) + f"  N={out.num_frames}")
        except Exception as e:
            print(f"  {label:42s}  ERROR: {str(e)[:60]}")

    # Also surface which params actually changed output relative to default.
    section("3b. Which params changed output (high-motion excerpt)?")
    default_hashes = [hash_frame(core.zit.IT(moving), n) for n in range(0, 160, 8)]
    diffmap: list[tuple[str, int, int]] = []
    for cfg in grid[1:]:
        if cfg.get("fps") == 30:
            # fps=30 baseline differs from fps=24 inherently; compare to its own baseline.
            base = [hash_frame(core.zit.IT(moving, fps=30), n) for n in range(0, 200, 10)]
            out = core.zit.IT(moving, **cfg)
            other = [hash_frame(out, n) for n in range(0, 200, 10)]
        else:
            base = default_hashes
            out = core.zit.IT(moving, **cfg)
            other = [hash_frame(out, n) for n in range(0, 160, 8)]
        diffs = sum(1 for a, b in zip(base, other) if a != b)
        total = len(base)
        label = ",".join(f"{k}={v}" for k, v in cfg.items())
        diffmap.append((label, diffs, total))
    for label, d, t in diffmap:
        marker = "DIFF" if d > 0 else "same"
        print(f"  {label:42s}  {marker}  ({d}/{t} sampled frames differ)")

    # ------------------------------------------------------------------
    section("4. Speed test (500 frames each)")
    pipelines = [
        ("zit fps=30 (default)",   lambda: core.zit.IT(src500, fps=30)),
        ("zit fps=24 (default)",   lambda: core.zit.IT(src500, fps=24)),
        ("zit fps=24 diMode=1",    lambda: core.zit.IT(src500, fps=24, diMode=1)),
        ("zit fps=24 diMode=2",    lambda: core.zit.IT(src500, fps=24, diMode=2)),
        ("zit fps=24 blend=1",     lambda: core.zit.IT(src500, fps=24, blend=1)),
        ("vivtc VFM order=1",      lambda: core.vivtc.VFM(src500, order=1)),
        ("vivtc VFM+VDecimate",    lambda: core.vivtc.VDecimate(core.vivtc.VFM(src500, order=1))),
    ]

    for label, build in pipelines:
        out = build()
        t0 = time.perf_counter()
        for n in range(out.num_frames):
            out.get_frame(n)
        elapsed = time.perf_counter() - t0
        fps_rate = out.num_frames / elapsed
        print(f"  {label:35s}  {out.num_frames:4d} frames  "
              f"{elapsed:6.2f}s  {fps_rate:6.1f} fps")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

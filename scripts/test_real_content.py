"""Real-content robustness test for zit.IT.

Decodes a real (telecined NTSC) clip via BestSource, runs zit.IT across every
chroma sampling x bit depth, and checks:
  1. no crash / no overflow (the local SAFE build aborts on HBD overflow),
  2. access-order determinism (sequential vs reversed render must hash equal),
  3. valid output range for the bit depth.
Plus dumps a few IVTC output frames to /tmp as PNG for visual inspection.

There is no bit-oracle for 4:2:2/4:4:4 (the C reference is 4:2:0 and
non-deterministic), so this is a robustness + visual check, not bit-equality.

    .venv/bin/python scripts/test_real_content.py <clip> [start_frame] [n_frames]

Needs `bs` (vapoursynth-bestsource) and numpy in the venv.
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

import numpy as np
import vapoursynth as vs

ROOT = Path(__file__).resolve().parent.parent
core = vs.core
core.num_threads = 1
core.std.LoadPlugin(str(ROOT / "zig-out" / "lib" / "libzit.so"))

CLIP = sys.argv[1]
START = int(sys.argv[2]) if len(sys.argv) > 2 else 9000
N = int(sys.argv[3]) if len(sys.argv) > 3 else 80

FORMATS = [
    ("420p8", vs.YUV420P8, 8), ("420p10", vs.YUV420P10, 10), ("420p16", vs.YUV420P16, 16),
    ("422p8", vs.YUV422P8, 8), ("422p10", vs.YUV422P10, 10), ("422p16", vs.YUV422P16, 16),
    ("444p8", vs.YUV444P8, 8), ("444p10", vs.YUV444P10, 10), ("444p16", vs.YUV444P16, 16),
]


def whole_hash(node, order):
    m = hashlib.md5()
    frames = {n: node.get_frame(n) for n in order}
    for n in range(node.num_frames):
        f = frames[n]
        for p in range(f.format.num_planes):
            m.update(np.asarray(f[p]).tobytes())
    return m.hexdigest()


def range_ok(node, bits):
    maxv = (1 << bits) - 1
    step = max(1, node.num_frames // 8)
    for n in range(0, node.num_frames, step):
        f = node.get_frame(n)
        for p in range(f.format.num_planes):
            a = np.asarray(f[p])
            if int(a.min()) < 0 or int(a.max()) > maxv:
                return f"frame {n} plane {p}: [{a.min()},{a.max()}] outside [0,{maxv}]"
    return None


def maxdiff_vs_8bit(o8, oh, shift):
    md = 0
    for n in range(o8.num_frames):
        f8, fh = o8.get_frame(n), oh.get_frame(n)
        for p in range(f8.format.num_planes):
            a8 = np.asarray(f8[p]).astype(np.int32)
            ah = np.asarray(fh[p]).astype(np.int32) >> shift
            md = max(md, int(np.abs(ah - a8).max()))
    return md


def main() -> int:
    src = core.bs.VideoSource(CLIP)[START:START + N]
    src = core.resize.Point(src, format=vs.YUV420P8)  # normalize base
    print(f"source: {src.width}x{src.height} {N} frames from #{START}")

    fails = []
    for name, fmt, bits in FORMATS:
        conv = core.resize.Point(src, format=fmt)
        out = core.zit.IT(conv, fps=24)  # IVTC mode (telecined NTSC -> 24p)
        try:
            order = list(range(out.num_frames))
            h_seq = whole_hash(out, order)            # 1+2: render (no crash) seq
            h_rev = whole_hash(out, order[::-1])       # 2: reversed access order
            det = h_seq == h_rev
            rng = range_ok(out, bits)                  # 3: range
            ok = det and rng is None
            print(f"  {name:7s} fps24: {out.num_frames} frames | no-crash OK | "
                  f"determinism {'OK' if det else 'DIFFER'} | range {'OK' if rng is None else rng}")
            if not ok:
                fails.append(f"{name}: det={det} range={rng}")
        except Exception as e:  # noqa: BLE001
            print(f"  {name:7s} FAIL: {type(e).__name__}: {e}")
            fails.append(f"{name}: {e}")

    # Bit-depth consistency: IT(HBD) >> shift vs IT(8-bit), same sampling. The
    # HBD input is the 8-bit one shifted exactly (Expr), so a diff > 1 means a
    # bit-depth-dependent decision (the residual <=1 is output-pavgb rounding).
    print("bit-depth consistency (max |IT(HBD)>>shift - IT(8bit)|):")
    for cs, f8, f10, f16 in (
        ("420", vs.YUV420P8, vs.YUV420P10, vs.YUV420P16),
        ("422", vs.YUV422P8, vs.YUV422P10, vs.YUV422P16),
        ("444", vs.YUV444P8, vs.YUV444P10, vs.YUV444P16),
    ):
        c8 = core.resize.Point(src, format=f8)
        o8 = core.zit.IT(c8, fps=24)
        d10 = maxdiff_vs_8bit(o8, core.zit.IT(core.std.Expr([c8], "x 4 *", f10), fps=24), 2)
        d16 = maxdiff_vs_8bit(o8, core.zit.IT(core.std.Expr([c8], "x 256 *", f16), fps=24), 8)
        print(f"  {cs}: 10-bit={d10}  16-bit={d16}")
        if d10 > 1 or d16 > 1:
            fails.append(f"{cs}: bit-depth diff > 1 (10={d10}, 16={d16})")

    # Visual dump: 420p8 IVTC output -> PNG via ffmpeg.
    dump = core.zit.IT(src, fps=24)
    for n in (0, dump.num_frames // 2, dump.num_frames - 1):
        f = dump.get_frame(n)
        raw = b"".join(np.asarray(f[p]).tobytes() for p in range(3))
        rawp = Path(f"/tmp/zit_real_ivtc_f{n:03d}.yuv")
        rawp.write_bytes(raw)
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo",
             "-pix_fmt", "yuv420p", "-s", f"{dump.width}x{dump.height}",
             "-i", str(rawp), "-frames:v", "1", str(rawp.with_suffix(".png"))],
            check=False,
        )
        print(f"  dumped /tmp/zit_real_ivtc_f{n:03d}.png")

    print("\nRESULT:", "ALL OK" if not fails else f"{len(fails)} FAIL: {fails}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())

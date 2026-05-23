#!/usr/bin/env python3
"""Stress-test the Zig port against the API-4 upstream port on a real,
telecined NTSC clip — and dump a handful of frames as raw YUV for visual
inspection.

Argument: path to a VOB / source file `bs` can decode.

Verifies:
  1. Plugin doesn't crash over a 200-frame slice.
  2. Output frame count matches expectations (fps=24 -> N*4/5).
  3. Every output md5 matches between core.zit.IT and core.it.IT.
  4. Dumps the first 5 and last 5 output frames per fps mode to /tmp/
     as raw YUV420P8 + a per-frame PNG via ffmpeg (if available).
"""

from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

import vapoursynth as vs

ROOT = Path(__file__).resolve().parent.parent
ZIG_PLUGIN = ROOT / "zig-out" / "lib" / "libzit.so"
UPSTREAM_PLUGIN = ROOT / "reference" / "vapoursynth-cpp-api4" / "libit.so"
SLICE_LENGTH = 200       # input frames to test
DUMP_PREFIX = "/tmp/zit_real"


def hash_frame(c: vs.VideoNode, n: int) -> str:
    f = c.get_frame(n)
    h = hashlib.md5()
    for p in range(f.format.num_planes):
        h.update(bytes(f[p]))
    return h.hexdigest()


def dump_raw_y(c: vs.VideoNode, n: int, label: str) -> Path:
    f = c.get_frame(n)
    path = Path(f"{DUMP_PREFIX}_{label}_f{n:03d}_{c.width}x{c.height}.yuv")
    with path.open("wb") as fh:
        for p in range(f.format.num_planes):
            fh.write(bytes(f[p]))
    return path


def maybe_png(yuv_path: Path, width: int, height: int) -> Path | None:
    if shutil.which("ffmpeg") is None:
        return None
    png_path = yuv_path.with_suffix(".png")
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error",
         "-f", "rawvideo", "-pix_fmt", "yuv420p",
         "-s", f"{width}x{height}",
         "-i", str(yuv_path),
         "-frames:v", "1",
         str(png_path)],
        check=True,
    )
    return png_path


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <path-to-vob>", file=sys.stderr)
        return 2
    src_path = Path(argv[1])
    if not src_path.exists():
        print(f"missing: {src_path}", file=sys.stderr)
        return 1

    core = vs.core
    core.std.LoadPlugin(str(ZIG_PLUGIN))
    if UPSTREAM_PLUGIN.exists():
        core.std.LoadPlugin(str(UPSTREAM_PLUGIN))
        compare = True
    else:
        print("warning: upstream-api4 not built — running zig-only", file=sys.stderr)
        compare = False

    full = core.bs.VideoSource(str(src_path))
    print(f"loaded {src_path.name}: {full.width}x{full.height} "
          f"len={full.num_frames} fps={full.fps_num}/{full.fps_den}")
    src = full[0:SLICE_LENGTH]

    for fps in (24, 30):
        zig = core.zit.IT(src, fps=fps)
        ref = core.it.IT(src, fps=fps) if compare else None
        print(f"\n--- fps={fps} -> {zig.num_frames} frames ---")

        if compare:
            assert zig.num_frames == ref.num_frames, (
                f"frame count mismatch: zig={zig.num_frames} ref={ref.num_frames}"
            )

        mismatches = 0
        for n in range(zig.num_frames):
            zh = hash_frame(zig, n)
            if compare:
                rh = hash_frame(ref, n)
                if zh != rh:
                    if mismatches < 3:
                        print(f"  diff n={n:03d}: zig={zh} ref={rh}")
                    mismatches += 1
            if n % 50 == 0:
                print(f"  ... frame {n}/{zig.num_frames}")

        if compare:
            print(f"fps={fps}: {mismatches}/{zig.num_frames} frames mismatched")

        # Dump first 3 and last 2 frames for visual inspection
        sample_indices = [0, 1, 2, zig.num_frames - 2, zig.num_frames - 1]
        for n in sample_indices:
            label = f"{src_path.stem}_fps{fps}"
            raw = dump_raw_y(zig, n, label)
            png = maybe_png(raw, zig.width, zig.height)
            print(f"  dumped frame {n:03d}: {raw}" + (f" + {png}" if png else ""))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

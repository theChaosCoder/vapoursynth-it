#!/usr/bin/env python3
"""Compare Zig-port output frame-by-frame against the API4-ported upstream.

The upstream library lives at `reference/vapoursynth-cpp-api4/libit.so` and
is built by `reference/vapoursynth-cpp-api4/Makefile` (see the project's
top-level README/PLAN for the build incantation). It is loaded as `core.it`,
the Zig port as `core.zit`.

For each fixture × parameter combination this script:
  1. Runs the same source clip through both plugins.
  2. Md5-hashes every output frame.
  3. Prints a one-line summary per (fixture, params, frame).
  4. Returns non-zero if any frame differs.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import vapoursynth as vs                       # noqa: E402
import gen_testclip                            # noqa: E402

ZIG_PLUGIN = ROOT / "zig-out" / "lib" / "libzit.so"
UPSTREAM_PLUGIN = ROOT / "reference" / "vapoursynth-cpp-api4" / "libit.so"

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


def hash_frame(clip: vs.VideoNode, n: int) -> str:
    f = clip.get_frame(n)
    h = hashlib.md5()
    for p in range(f.format.num_planes):
        h.update(bytes(f[p]))
    return h.hexdigest()


def main() -> int:
    if not ZIG_PLUGIN.exists():
        print(f"missing: {ZIG_PLUGIN}", file=sys.stderr)
        return 1
    if not UPSTREAM_PLUGIN.exists():
        print(f"missing: {UPSTREAM_PLUGIN}\nbuild it via "
              f"`cd reference/vapoursynth-cpp-api4 && PKG_CONFIG_PATH= "
              f"./configure --c --cxx=clang++ "
              f"--extra-cxxflags='-std=c++17' && make`",
              file=sys.stderr)
        return 1

    core = vs.core
    if not any(p.namespace == "zit" for p in core.plugins()):
        core.std.LoadPlugin(str(ZIG_PLUGIN))
    if not any(p.namespace == "it" for p in core.plugins()):
        core.std.LoadPlugin(str(UPSTREAM_PLUGIN))

    total = 0
    mismatched = 0
    matched_fixtures: list[str] = []
    mismatched_fixtures: list[str] = []

    for fixture, fps, th, pth in PARAM_GRID:
        src = gen_testclip.FIXTURES[fixture]()
        zig = core.zit.IT(src, fps=fps, threshold=th, pthreshold=pth)
        ref = core.it.IT(src, fps=fps, threshold=th, pthreshold=pth)

        if zig.num_frames != ref.num_frames:
            print(f"FAIL frame count: {fixture} fps={fps} th={th} pth={pth}: "
                  f"zig={zig.num_frames} ref={ref.num_frames}")
            mismatched_fixtures.append(f"{fixture}|{fps}|{th}|{pth}")
            mismatched += zig.num_frames + ref.num_frames
            total += zig.num_frames + ref.num_frames
            continue

        per_frame_mismatch = 0
        for n in range(zig.num_frames):
            zh = hash_frame(zig, n)
            rh = hash_frame(ref, n)
            total += 1
            if zh != rh:
                if per_frame_mismatch < 3:
                    print(f"  {fixture}|fps={fps}|th={th}|pth={pth}|n={n:04d}: "
                          f"zig={zh} ref={rh}")
                per_frame_mismatch += 1
                mismatched += 1

        tag = f"{fixture}|{fps}|{th}|{pth}"
        if per_frame_mismatch == 0:
            matched_fixtures.append(tag)
        else:
            mismatched_fixtures.append(f"{tag} ({per_frame_mismatch}/{zig.num_frames})")

    print(f"\nMatched fixtures ({len(matched_fixtures)}):")
    for f in matched_fixtures:
        print(f"  {f}")
    print(f"\nMismatched fixtures ({len(mismatched_fixtures)}):")
    for f in mismatched_fixtures:
        print(f"  {f}")
    print(f"\nTotal frames: {total} | mismatched: {mismatched}")
    return 0 if mismatched == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

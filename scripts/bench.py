"""Wall-clock benchmark for the zit plugin.

Builds a synthetic interlaced 720x480 clip, runs `core.zit.IT(...)` over it
in a few configurations, and reports frames/sec for each. Use to validate
SIMD changes or compare candidate optimisations against a baseline.

Usage:
    zig build --release=fast      # IMPORTANT — Debug builds are 10×+ slower
    python scripts/bench.py
    # or with taskset for lower variance:
    taskset -c 1 python scripts/bench.py

Each scenario runs RUNS times with a **fresh filter chain per run** —
VS caches rendered frames per-node, so reusing the same chain across runs
would mostly measure cache lookups. A fresh `core.zit.IT(...)` per run
forces every measured frame to actually go through the filter.
"""

from __future__ import annotations

import statistics
import sys
import time
from pathlib import Path
from typing import Callable

import vapoursynth as vs

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import gen_testclip  # noqa: E402

PLUGIN = ROOT / "zig-out" / "lib" / "libzit.so"

WIDTH, HEIGHT = 720, 480
CLIP_FRAMES = 15000  # 24fps decimation drops to ~12k output; 10k+100 fits
WARMUP = 100      # pulled cold to fault in code/data, not counted
MEASURE = 10000   # frames timed after warmup — large N averages out noise
RUNS = 3          # 3× 10k is already ~10–15s/scenario; more would test patience


def time_pull(clip: vs.VideoNode, start: int, count: int) -> float:
    """Pull `count` frames starting at index `start`, return wall-clock seconds."""
    t0 = time.perf_counter()
    for n in range(start, start + count):
        _ = clip.get_frame(n)
    return time.perf_counter() - t0


def bench(label: str, make_filter: Callable[[], vs.VideoNode]) -> None:
    fps_runs: list[float] = []
    for _ in range(RUNS):
        # Fresh chain per run — VS frame cache is per-node, so reusing the
        # same `clip` across runs would mostly measure cache lookups after
        # the first run.
        clip = make_filter()
        # Cold warmup to fault in pages / JIT; not timed.
        time_pull(clip, 0, WARMUP)
        elapsed = time_pull(clip, WARMUP, MEASURE)
        fps_runs.append(MEASURE / elapsed)

    median = statistics.median(fps_runs)
    spread = max(fps_runs) - min(fps_runs)
    spread_pct = 100.0 * spread / median if median > 0 else 0.0
    print(f"  {label:<30}  {median:7.1f} fps   (spread {spread_pct:4.1f}%)")


def main() -> None:
    if not PLUGIN.exists():
        sys.exit(f"Plugin not built: {PLUGIN}\nRun: zig build --release=fast")

    core = vs.core
    core.std.LoadPlugin(str(PLUGIN))

    src = gen_testclip.interlaced_stripes(WIDTH, HEIGHT, CLIP_FRAMES)
    print(f"Clip: {src.width}x{src.height} length={src.num_frames} "
          f"warmup={WARMUP} measure={MEASURE} runs={RUNS}")
    print()

    bench("one_field (default)",   lambda: core.zit.IT(src))
    bench("diMode=1 DEINTERLACE",  lambda: core.zit.IT(src, fps=30, diMode=1))
    bench("diMode=2 SIMPLE_BLUR",  lambda: core.zit.IT(src, fps=30, diMode=2))
    bench("fps=24 + blend",        lambda: core.zit.IT(src, fps=24, blend=1))
    bench("ref=ALL",               lambda: core.zit.IT(src, fps=30, ref="ALL"))


if __name__ == "__main__":
    main()

"""Generate golden hashes for the upstream-comparison test.

The C reference plugin (`it.IT`, reference/vapoursynth-cpp-api4/libit.so) is
NON-DETERMINISTIC: for identical input it emits 2-3 different outputs depending
on accumulated VapourSynth core state (proven — see the flake investigation).
zit.IT is provably deterministic and matches the C reference's *canonical*
output when the reference is rendered in a clean, isolated state.

This script renders both plugins ONCE in such a clean state, asserts they agree
(so the captured hash genuinely is the upstream's intended output), and writes
the per-frame hashes to `tests/integration/upstream_golden.json`. The runtime
test then compares zit against these golden hashes deterministically — no flake,
while still encoding the verified "zit matches the C reference" property.

Re-run this (in isolation) only when the algorithm legitimately changes:
    uv run python scripts/gen_upstream_golden.py
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import vapoursynth as vs  # noqa: E402
import gen_testclip  # noqa: E402
from param_grid import UPSTREAM_GRID as PARAM_GRID  # noqa: E402

ZIT = ROOT / "zig-out" / "lib" / "libzit.so"
UPSTREAM = ROOT / "reference" / "vapoursynth-cpp-api4" / "libit.so"
GOLDEN = ROOT / "tests" / "integration" / "upstream_golden.json"


def _hash(clip: vs.VideoNode, n: int) -> str:
    f = clip.get_frame(n)
    h = hashlib.md5()
    for p in range(f.format.num_planes):
        h.update(bytes(f[p]))
    return h.hexdigest()


def main() -> int:
    c = vs.core
    c.num_threads = 1
    c.std.LoadPlugin(str(ZIT))
    c.std.LoadPlugin(str(UPSTREAM))

    golden: dict[str, list[str]] = {}
    for fixture_name, fps, threshold, pthreshold in PARAM_GRID:
        key = f"{fixture_name}-{fps}-{threshold}-{pthreshold}"
        src = gen_testclip.FIXTURES[fixture_name]()
        zig = c.zit.IT(src, fps=fps, threshold=threshold, pthreshold=pthreshold)
        ref = c.it.IT(src, fps=fps, threshold=threshold, pthreshold=pthreshold)
        assert zig.num_frames == ref.num_frames, key

        zig_hashes = [_hash(zig, n) for n in range(zig.num_frames)]
        ref_hashes = [_hash(ref, n) for n in range(ref.num_frames)]
        # Verify zit matches the C reference in this clean context: the golden
        # is only trustworthy if the two agree here.
        mism = [n for n in range(len(zig_hashes)) if zig_hashes[n] != ref_hashes[n]]
        if mism:
            print(f"FAIL {key}: zit != C reference at frames {mism[:8]} — "
                  f"reference not canonical in this run, do not commit", file=sys.stderr)
            return 1
        golden[key] = zig_hashes
        print(f"ok  {key}: {len(zig_hashes)} frames")

    GOLDEN.write_text(json.dumps(golden, indent=2) + "\n")
    print(f"wrote {GOLDEN} ({len(golden)} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

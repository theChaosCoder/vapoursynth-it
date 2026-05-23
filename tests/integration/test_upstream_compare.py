"""Bit-exact comparison: Zig port vs API-4-ported upstream C++ reference.

This test is skipped when the upstream library is missing. To build it:

    scripts/build_upstream_api4.sh

When present, every fixture/parameter combination must produce
byte-identical output between `core.zit.IT` and `core.it.IT` — that's the
strongest claim of the project.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import pytest
import vapoursynth as vs

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import gen_testclip                              # noqa: E402

UPSTREAM_PLUGIN = ROOT / "reference" / "vapoursynth-cpp-api4" / "libit.so"

# Same matrix the golden-hash test pins. Each entry must produce the same
# bytes from both implementations.
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


def _hash(clip: vs.VideoNode, n: int) -> str:
    f = clip.get_frame(n)
    h = hashlib.md5()
    for p in range(f.format.num_planes):
        h.update(bytes(f[p]))
    return h.hexdigest()


@pytest.fixture(scope="session")
def upstream_loaded(core):
    if not UPSTREAM_PLUGIN.exists():
        pytest.skip(
            f"upstream reference not built ({UPSTREAM_PLUGIN}). "
            f"Run scripts/build_upstream_api4.sh."
        )
    if not any(p.namespace == "it" for p in core.plugins()):
        core.std.LoadPlugin(str(UPSTREAM_PLUGIN))
    return core


@pytest.mark.parametrize("fixture_name,fps,threshold,pthreshold", PARAM_GRID)
def test_zig_matches_upstream(upstream_loaded, fixtures, fixture_name, fps, threshold, pthreshold):
    src = fixtures[fixture_name]()
    zig = upstream_loaded.zit.IT(src, fps=fps, threshold=threshold, pthreshold=pthreshold)
    ref = upstream_loaded.it.IT(src, fps=fps, threshold=threshold, pthreshold=pthreshold)

    assert zig.num_frames == ref.num_frames, (
        f"frame count mismatch: zig={zig.num_frames} ref={ref.num_frames}"
    )
    mismatches: list[str] = []
    for n in range(zig.num_frames):
        zh = _hash(zig, n)
        rh = _hash(ref, n)
        if zh != rh:
            mismatches.append(f"  frame {n:04d}: zig={zh} ref={rh}")
    assert not mismatches, "\n".join(mismatches)

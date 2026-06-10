"""Determinism / access-order-independence guard.

IT caches cross-frame decisions lazily in per-instance state (`frame_info`,
`block_info`) filled on demand as frames are pulled. This test pins that the
**output is identical regardless of the order** in which frames are requested
— i.e. no lazily-cached value leaks an access-order dependency into the
result.

Why it matters: under VapourSynth's parallel prefetch a node's
`arAllFramesReady` calls can run out of request order. If any cross-frame
state read depended on that order, the output would change run-to-run and
surface as a rare flaky mismatch (e.g. against the upstream oracle). One
latent order-sensitive read exists today — `decide()`'s previous-block lookup
(`block_info[base/5 - 1]`) — but it must not change the emitted frames; this
test is the regression guard that keeps it (and any future cross-frame state)
honest.

Each access order is run on a **fresh** IT node so its internal cache starts
empty and is filled purely in that order.
"""

from __future__ import annotations

import hashlib

import pytest

import gen_testclip


def _clip_hash(node, order):
    def all_planes(n):
        f = node.get_frame(n)
        return b"".join(bytes(f[p]) for p in range(f.format.num_planes))

    frames = {n: all_planes(n) for n in order}
    m = hashlib.md5()
    for n in range(node.num_frames):
        m.update(frames[n])
    return m.hexdigest()


# Each entry maps frame_count -> the order to pull frames in. All must yield
# the identical whole-clip hash.
ORDERS = {
    "sequential": lambda N: list(range(N)),
    "reversed": lambda N: list(reversed(range(N))),
    "last-first": lambda N: [N - 1] + list(range(N)),
    "strided": lambda N: [n for n in range(N) if n % 3 == 0] + list(range(N)),
}


# Telecine + interlaced exercise the fps=24 decimation (decide/block_info) and
# the deinterlace path; constant_large adds a non-128 width; motion_flicker is
# the only fixture whose blocks pass the blend gate, so blend=1 there guards
# blendInto's cross-block (base-1) rendering against access-order dependence.
@pytest.mark.parametrize("fixture", ["interlaced_stripes", "two_frame_telecine", "constant_large", "motion_flicker"])
@pytest.mark.parametrize("fps", [24, 30])
@pytest.mark.parametrize("blend", [0, 1])
def test_output_is_access_order_independent(core, fixture, fps, blend):
    def fresh():
        return core.zit.IT(gen_testclip.FIXTURES[fixture](), fps=fps, threshold=20, pthreshold=75, blend=blend)

    n_frames = fresh().num_frames
    baseline = None
    baseline_name = ""
    for name, order_fn in ORDERS.items():
        h = _clip_hash(fresh(), order_fn(n_frames))
        if baseline is None:
            baseline, baseline_name = h, name
        else:
            assert h == baseline, (
                f"{fixture} fps={fps}: access order '{name}' produced {h}, "
                f"but '{baseline_name}' produced {baseline} — output depends on "
                f"frame request order (non-deterministic under prefetch)"
            )

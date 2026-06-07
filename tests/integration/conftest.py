"""Shared pytest fixtures.

Loads the freshly-built `libzit.so` into the VapourSynth core exactly once
per test session, so the tests don't pay the dlopen cost repeatedly.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import vapoursynth as vs                    # noqa: E402
import gen_testclip                          # noqa: E402

PLUGIN_PATH = ROOT / "zig-out" / "lib" / "libzit.so"


@pytest.fixture(scope="session")
def core():
    if not PLUGIN_PATH.exists():
        pytest.skip(f"plugin not built: {PLUGIN_PATH} (run `zig build` first)")
    c = vs.core
    # Pin to a single worker thread for the whole suite. These are
    # correctness/oracle tests, not concurrency stress: determinism matters
    # more than speed. VapourSynth's parallel prefetch can run a node's
    # arAllFramesReady calls out of request order, and IT caches cross-frame
    # decisions lazily (frame_info/block_info) — so multi-threaded prefetch
    # can, very rarely, surface an access-order-dependent decimation and make
    # the upstream-comparison flake. One thread = strictly sequential =
    # reproducible. (Order-independence of the *output* itself is asserted
    # separately in test_determinism.py.)
    c.num_threads = 1
    # VapourSynth refuses to load the same plugin twice; check first.
    already_loaded = any(p.namespace == "zit" for p in c.plugins())
    if not already_loaded:
        c.std.LoadPlugin(str(PLUGIN_PATH))
    return c


@pytest.fixture(scope="session")
def fixtures():
    return gen_testclip.FIXTURES

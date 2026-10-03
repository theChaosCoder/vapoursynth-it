"""Shared pytest fixtures.

Loads the freshly-built `libzit.so` into the VapourSynth core exactly once
per test session, so the tests don't pay the dlopen cost repeatedly.
"""

from __future__ import annotations

import os
import platform
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import vapoursynth as vs                    # noqa: E402
import gen_testclip                          # noqa: E402

_LIB_NAME = {
    "Darwin": "libzit.dylib",
    "Windows": "zit.dll",
}.get(platform.system(), "libzit.so")
# Zig installs shared libs under lib/ on POSIX but bin/ for Windows DLLs.
_CANDIDATES = [ROOT / "zig-out" / sub / _LIB_NAME for sub in ("lib", "bin")]
PLUGIN_PATH = next((p for p in _CANDIDATES if p.exists()), _CANDIDATES[0])


@pytest.fixture(scope="session")
def core():
    if not PLUGIN_PATH.exists():
        msg = f"plugin not built: {PLUGIN_PATH} (run `zig build` first)"
        if os.environ.get("ZIT_REQUIRE_PLUGIN"):
            # In CI a missing plugin is a broken build/layout, not a reason
            # to silently skip every end-to-end guarantee.
            pytest.fail(msg)
        pytest.skip(msg)
    c = vs.core
    # Pin to a single worker thread for the whole suite. These are
    # correctness/oracle tests. Keep the upstream reference sequential;
    # test_determinism.py explicitly enables multiple workers and shuffled
    # asynchronous requests when testing zit's request-order independence.
    c.num_threads = 1
    # VapourSynth refuses to load the same plugin twice; check first.
    already_loaded = any(p.namespace == "zit" for p in c.plugins())
    if not already_loaded:
        c.std.LoadPlugin(str(PLUGIN_PATH))
    return c


@pytest.fixture(scope="session")
def fixtures():
    return gen_testclip.FIXTURES

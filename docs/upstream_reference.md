# Upstream bit-exact comparison

The PLAN.md Phase 3 target was: feed identical test clips through the Zig
port and the upstream C++ `--c` build, and require **byte-identical
output** on every frame. As of 2026-05-23 that is achieved — see the
matched results below — via a mechanical port of upstream to VapourSynth
API 4 living under `reference/vapoursynth-cpp-api4/`.

## What's wired up

`scripts/regen_golden.py` produces self-referential md5 hashes from the
Zig build. `tests/integration/test_filter.py` checks them on every run
plus a small set of invariants (frame count, fps metadata, format,
determinism, error paths).

`scripts/build_upstream_api4.sh` builds the upstream reference
(`reference/vapoursynth-cpp-api4/libit.so`). It is loaded by
`tests/integration/test_upstream_compare.py` as `core.it` and compared
frame-by-frame against the Zig port (`core.zit`). All 10
fixture × parameter combinations match bit-exact (198 frames, zero
mismatches).

`scripts/compare_upstream.py` is the same comparison as a standalone
script — useful when diagnosing a regression to print the first few
diverging md5s instead of just asserting.

## Why we had to port upstream to API 4

The original upstream targets VapourSynth **API 3**. Three concrete
blockers got in the way of using it as-is under the modern VS R76
installed on this host:

1. **Build vs modern clang**. The upstream's `__C` preprocessor define
   (used to select the pure-C code path) collides with parameter names
   in clang/gcc's `<crc32intrin.h>` — `_mm_crc32_u16(unsigned int __C,
   unsigned short __D)`. The build fails with cascading "expected ')'"
   errors that have nothing to do with the IT plugin itself.
2. **`x86intrin.h` needs C++17.** Upstream pins `-std=c++11`; under
   clang 22 the intrinsic headers fail to parse without `-std=c++17`.
3. **API 3 → API 4 instanceData ABI change**. Even after the build, the
   plugin segfaults at the first `get_frame` call: API 3's
   `VSFilterGetFrame` takes `void **instanceData` (pointer to a slot for
   arbitrary state), API 4 takes `void *instanceData` (the value
   itself). The compat shim in VS R55+ keeps loading but the
   single-deref upstream does (`*instanceData`) reads from the wrong
   location.

The API-4 port in `reference/vapoursynth-cpp-api4/` resolves all three.

## What the port covers

All renames and shims required to compile and run the C path under VS
API 4. The algorithm itself is untouched. The full diff list is in
`reference/vapoursynth-cpp-api4/README.md`. Two notable behavioural
fixes that the port *needed* (independent of the API migration):

* `GetFramePre` now requests `[base-2, base+6]` (fps=24) or `[n-2, n+2]`
  (fps=30) instead of the upstream's tight `[base, base+5]` / `{n}`.
  Upstream got away with the narrow range under API 3 because its
  in-filter `vsapi->getFrame` was the sync API and could fetch any
  cached frame; API 4 requires `getFrameFilter` which only returns
  *requested* frames.
* `IScriptEnvironment::GetFrame(n)` now clips `n` to
  `[0, numFrames-1]`. Upstream's algorithm reads `n-1` even at frame 0;
  under API 3 the sync API clipped silently. The Zig port already did
  the same clipping in its plane helpers.

These are not algorithm changes — they are framework-level fixes
identical to what we did in the Zig port. The bit-exact match confirms
they are equivalent.

## Maintenance

If a future change to the Zig port alters output bytes, the upstream-
compare test will fail before the self-referential golden test does
(because the upstream is what the goldens *should* be). At that point:

1. If the change is intentional: re-build upstream, re-run
   `compare_upstream.py` to confirm we still match, then re-run
   `scripts/regen_golden.py` to refresh the pinned hashes.
2. If the change is a bug: fix the Zig port; the upstream comparison
   tells you exactly which fixture and frame index diverged.

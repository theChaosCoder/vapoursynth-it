# Upstream bit-exact comparison

The PLAN.md Phase 3 target was: feed identical test clips through the Zig
port and the upstream C++ `--c` build, and require **byte-identical
output** on every frame. As of 2026-05-23 that is achieved — see the
matched results below — via a mechanical port of upstream to VapourSynth
API 4 living under `reference/vapoursynth-cpp-api4/`.

## What's wired up

The oracle parameter grids live in one module, `scripts/param_grid.py`:
`UPSTREAM_GRID` (what the C reference can oracle — it hardcodes
ref=TOP/one_field/blend=0) and `GOLDEN_GRID` (a superset adding
ref/diMode/blend rows pinned self-referentially).

`scripts/regen_golden.py` produces self-referential md5 hashes from the
Zig build over `GOLDEN_GRID` (with a provenance header: timestamp + zit
commit). `tests/integration/test_filter.py` checks them on every run
plus a set of invariants (frame count, fps metadata, format, error
paths); `test_determinism.py` separately asserts access-order
independence.

**The upstream comparison does NOT run the C reference live.** The C
reference plugin is non-deterministic: for identical input it emits 2–3
different outputs depending on accumulated VapourSynth core state
(root-caused during the flake investigation; `num_threads=1` does not
fix it — it reads uninitialized members in reachable paths). Instead,
`tests/integration/upstream_golden.json` holds hashes captured from the
reference *in a clean, isolated state*, where `zit == reference` was
asserted at capture time. `tests/integration/test_upstream_compare.py`
compares zit against those committed hashes — deterministic, and still
an external oracle.

To re-capture (only after an intentional output change):

1. `scripts/build_upstream_api4.sh` — builds
   `reference/vapoursynth-cpp-api4/libit.so`.
2. `uv run python scripts/gen_upstream_golden.py` — renders both plugins
   in isolation, asserts zit matches the reference frame-by-frame, and
   rewrites `upstream_golden.json`. If the assertion fails, fix zit (or
   review the intentional divergence) — never commit goldens that didn't
   match at capture.

`scripts/compare_upstream.py` is the live comparison as a standalone
diagnostic — useful for printing the first diverging md5s, but expect
occasional false mismatches from the reference's non-determinism.

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

If a future change to the Zig port alters output bytes, both the
upstream-golden test and the self-referential golden test fail. At that
point:

1. If the change is a bug: fix the Zig port; the failing test names the
   exact fixture and frame index that diverged.
2. If the change is intentional **and** touches an upstream-oracled path
   (8-bit 4:2:0, ref=TOP, diMode=3, blend=0): rebuild the reference and
   re-run `scripts/gen_upstream_golden.py` (it asserts zit == reference
   at capture). Then run `scripts/regen_golden.py` for the
   self-referential file.
3. If the change only affects extension paths (HBD, 4:2:2/4:4:4, other
   ref/diMode/blend values): run `scripts/regen_golden.py` and **verify in
   the diff that the upstream-oracled rows did not change** — the
   regeneration script pins zit's own output, so an unreviewed regen can
   silently bless a regression. The provenance header records what was
   generated when, from which commit.

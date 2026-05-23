# Upstream bit-exact comparison — deferred

The PLAN.md Phase 3 target was: feed identical test clips through the Zig
port and the upstream C++ `--c` build, and require **byte-identical output**
on every frame. The current state is a partial achievement of that goal —
this note explains the gap and the path forward.

## What works today

`scripts/regen_golden.py` and `tests/integration/test_filter.py` produce
and re-check **golden md5 hashes** for the Zig port's output across a
range of fixtures (constant, telecined, interlaced) and parameters
(fps 24/30, threshold variations). These hashes guard against unintended
regressions inside the Zig port itself.

The integration suite also asserts a set of **invariants** that hold
regardless of pixel content:

* `fps=30` keeps the input frame count
* `fps=24` produces `floor(N * 4 / 5)` frames
* output format == input format
* the same clip processed twice produces identical hashes (determinism)
* invalid inputs raise the expected `vs.Error`

## What does not work yet — and why

The upstream VapourSynth-IT plugin at
<https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT> targets
**VapourSynth API 3**. We did manage to build it locally against this
project's `clang++ -std=c++17` toolchain after two workarounds:

1. Renaming the upstream's `__C` preprocessor flag to `__ITC` — `__C` is
   also a parameter name in clang's `<crc32intrin.h>` (`_mm_crc32_u16`).
2. Dropping `vs_it_mmx.cpp` and `vs_it_sse.cpp` from the make sources —
   they use MSVC `_asm { ... }` blocks that don't compile under
   clang on Linux. The pure-C path (`__ITC`) is unaffected.

That produces a usable `libit.so`. It loads into VapourSynth R76's
API-3-compat shim (the `it` namespace appears in `core.plugins()`).
The first `out.get_frame(0)` call, however, segfaults at offset
`+0x79` inside `IT::GetFrame`, which is the prologue (`++m_iCounter;
env->m_iRealFrame = n;`). The most likely cause is the API 3 → API 4
`instanceData` ABI change:

* API 3: `VSFilterGetFrame` receives `void **instanceData` (pointer to a
  slot for arbitrary state).
* API 4: `void *instanceData` (the value itself).

The upstream `itGetFrame` dereferences as if the slot were still
present (`INSTANCE * d = static_cast<INSTANCE *>(*instanceData);`), so
under the compat layer it ends up dereferencing whatever happens to sit
where the slot once was.

## Path forward (not gated on Phase 3)

Two concrete options, neither blocking Phase 4+:

1. **Run upstream in a container with an older VS.** Build a docker
   image with VapourSynth R55..R60 (the last that supported API 3
   natively) and run a side-by-side comparison harness against the
   golden hashes. A skeleton `scripts/upstream_compare_docker.sh` is the
   natural home for this.
2. **Mechanically port upstream to API 4 in a throwaway branch.** Rename
   `VSNodeRef → VSNode`, `propGet* → mapGet*`, `setError → mapSetError`,
   `VapourSynthPluginInit → VapourSynthPluginInit2 + VSPLUGINAPI`, and
   replace `createFilter` with `createVideoFilter`. Then run the
   comparison directly under VS R76. The trade-off is that the
   "independence" of the reference shrinks once you patch it.

Until one of those is in place, the golden hashes pinned in
`tests/integration/fixtures/golden_hashes.txt` are **self-referential**:
they certify that the Zig port behaves consistently across builds, not
that it behaves identically to the canonical IT.

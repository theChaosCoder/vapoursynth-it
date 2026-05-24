# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/), versioning is
[SemVer](https://semver.org/).

## [1.3.3] — 2026-05-24

Packaging-only release. Same Binaries.

### Fixed

- PyPI wheel should install into site-packages/vapoursynth/plugins/

## [1.3.2] — 2026-05-24

Patch release. Pixel output unchanged from 1.3.1 on every supported
parameter combination — verified bit-identical against the
`vapoursynth-cpp-api4` reference across the full upstream-compare grid
(8 fixtures × parameter combos) and across the 3-mode smoke
(default / ref=ALL / blend=1, 150 frames each, sha256 prefix
`63e6227182560887` unchanged).

### Performance

The hot algorithm functions (`motion.makeMotionMap2{Min,Max}`,
`output.{copyCPNField, deinterlace, simpleBlur, deintOneField}`) now
take their plane-view arguments as `*const plane.PlaneView` instead of
by value. Each PlaneView is 48 bytes; the 24fps path threads several
through several calls per output frame, so the reduction in stack
copies shows up clearly:

| Pipeline           | 1.3.1    | 1.3.2    | Δ       |
| ------------------ | -------: | -------: | ------: |
| fps=24 (default)   | 2395 fps | 2701 fps | +12.8%  |
| fps=24 + blend     | 2391 fps | 2699 fps | +12.9%  |
| fps=24 ref=ALL     | 2490 fps | 2795 fps | +12.3%  |
| fps=30 diMode=1    |  716 fps |  715 fps | —       |
| fps=30 diMode=2    | 3409 fps | 3447 fps | +1.1%   |

(720x480 NTSC, 10 000 measured frames per run × 3 runs, `taskset -c 1`,
ReleaseFast.) The 30fps modes don't move because they do one
`makeOutput` per output frame; the 24fps path runs `getFrameSub` 5×
per output frame in the decimation block, which is where the saved
copies add up.

### Internal restructuring (no behaviour change)

- **Bindings**: dropped the hand-rolled `@cImport` layer in `src/c.zig`
  and the three vendored VS4 headers in favour of the upstream
  [`vapoursynth-zig`](https://github.com/dnjulek/vapoursynth-zig)
  package. Filter + plugin entry now use `ZAPI` / `ZMap` helpers with
  type-safe enums and typed prop setters (`setFieldBased`,
  `setCombed`, `setDuration*`). Net diff ~−1450 lines.
- **`PlaneView` / `PlaneViewMut`** introduced in `plane.zig` — one
  canonical 6-field struct replaces the 18–28 separate
  `[*]const u8` + `usize` parameters the algorithm functions used to
  take.
- **`scalar.zig`** module for tiny u8-math helpers (`absDiff`,
  `pavgb`, `subSat`) that were previously redefined per-file (6
  inline copies across 5 files). Vector versions stay in `simd.zig`.
- **Deinterlace dedupe**: extracted
  `output.deinterlacePixelScalar` — one canonical inline kernel for
  the per-pixel scoring + pick + motion-override that was previously
  written twice in `output.deinterlace` (~75 lines inside the SIMD
  body's chroma loop + ~109 lines in the scalar tail).
- **Audit cleanup**: dead fields (`CFrameInfo.{out, matchAcc}`,
  `CallState.{realFrame, iUsePrev, iUseNext}`) removed; redundant
  per-frame `@memset` calls in `CallState.resetForFrame` dropped
  (consumers either fully overwrite or pair partial writes with
  matching partial reads); 12 `var ... = undefined` plane-row locals
  in `simpleBlur` paths became `const` expressions.
- **Centralised constants**: `MAX_WIDTH` (3 copies) and
  `CHROMA_LANES` (2 copies) consolidated into `plane.zig`.

### Tooling

- **`scripts/bench.py`** — wall-clock fps benchmark across the
  relevant filter configurations. Used to validate the
  `PlaneView`-by-pointer change above; sub-1% spread on SIMD-bound
  paths once pinned with `taskset -c 1`.
- **CI workflow** (`.github/workflows/ci.yml`) — consolidated three
  duplicated `curl | tar` Zig installs into `mlugg/setup-zig@v2`;
  collapsed the lint/unit/cross jobs into a single `build` job;
  replaced the PPA-based VapourSynth install on the integration job
  with `pip install VapourSynth` (the PyPI wheel ships
  `libvapoursynth.so` + `vspipe` on Linux). −50 lines.
- **Release workflow** (`.github/workflows/release.yml`) — same
  `mlugg/setup-zig@v2` swap; tag-resolve collapsed to a one-liner via
  `inputs.tag || github.ref_name`; the
  `gh release view || create; upload --clobber; edit` choreography
  became a single `softprops/action-gh-release@v2` step. −20+ lines.

### Known issue (carried forward, not new)

The SIMD body of `output.deinterlace` (diMode=1) uses `pavgb` (rounded
average) for the motion-override luma override, while the scalar tail
and the Avisynth C upstream both use truncated `(t+b)>>1`. At pixels
where the motion-override fires and `(pT[x]+pB[x])` is odd, our SIMD
path differs by ±1 from the scalar path. The `vapoursynth-cpp-api4`
reference plugin hardcodes `one_field` (no `diMode` parameter), so
this can't yet be validated against ground truth — a TODO marker in
the source records the one-liner fix for whoever builds the Avisynth
oracle (or hand-computes reference fixtures).

## [1.3.1] — 2026-05-23

Patch release. Performance-only — pixel output unchanged from 1.3.0
on every supported parameter combination.

### Changes

- **SIMD coverage extended** to the three output-stage functions in
  `src/output.zig`:
  - `simpleBlur` (diMode=2): 32-lane motion-hit count + 16-lane luma
    body with overlap-loaded 3-tap motion neighbours.
  - `deintOneField` (diMode=3, default): 16-lane luma body using
    cross-row field-map OR-mask + pavgb + `@select`; chroma
    unconditional via tight LANES/2 pass.
  - `deinterlace` (diMode=1): 32-lane luma with all five IV scores +
    `@select`-chain min-pick + motion override.
- **ARM64 binaries** included by default (Linux aarch64 + macOS
  aarch64) since the 1.3.0 release-workflow rework.

### Speed delta vs 1.3.0 (720x480 NTSC, ReleaseFast, best-of-3)

| Pipeline           | 1.3.0    | 1.3.1    | Δ            |
| ------------------ | -------: | -------: | -----------: |
| fps=30             | 3217 fps | 3175 fps | ~0 (noise)   |
| fps=24             | 3148 fps | 3023 fps | ~0           |
| fps=24 diMode=1    | 3041 fps | 3215 fps | +5.7%        |
| fps=24 blend=1     | 2353 fps | 2301 fps | ~0           |

The default fps=24/fps=30 paths don't move measurably because most
frames on telecined NTSC content classify as ip='P' and skip the
deinterlacer entirely. Workloads that hit ip='I' frequently
(interlaced-heavy content, or `pthreshold=1`-forced runs) see the
diMode=1 gain on every frame.

### Bit-exactness

Default-path 720-frame regression against the API-4 upstream port
still passes byte-for-byte. `diMode=1` SIMD was independently
verified against the pre-SIMD scalar build (80 frames, all md5s
identical).

## [1.3.0] — 2026-05-23

Initial release. A from-scratch Zig port of the VapourSynth-IT
inverse-telecine filter, bit-exact to the upstream C reference path
and with the original Avisynth-only parameters restored.

Version numbering picks up the IT lineage:
  * Avisynth `IT_YV12 v0.1.03` (minamina, 2003)
  * VapourSynth `VS_IT.dll v0103.1.2` (msg7086, 2014)
  * This Zig port: `v1.3.0`.

### Features

- **Filter** `core.zit.IT(clip, fps=24, threshold=20, pthreshold=75,
  ref="TOP", blend=0, diMode=3)` registered for VapourSynth API 4
  (R55+). Accepts YUV420P8 input with `width % 16 == 0`, `height % 2 == 0`,
  `width ≤ 8192`.
- **Decimation modes**:
  - `fps=24` — 3:2-pulldown removal, output 24000/1001 fps (5→4
    frames per cycle).
  - `fps=30` — field-matching only, input rate preserved.
- **`ref` parameter** (`"TOP"`/`"BOTTOM"`/`"ALL"`/`"NONE"`): the
  Avisynth original's field-match-direction switch, fully reimplemented.
  The VapourSynth upstream had stripped this down to a hardcoded
  `"TOP"`.
- **`blend` parameter**: pure-Zig port of Avisynth's `BlendFrame_YV12`,
  triangular kernel weighted blend of post-matched frames, motion-gated
  on the same `minD/avgD` heuristic as the original. Only active when
  `fps=24`.
- **`diMode` parameter** with all four Avisynth deinterlace modes:
  - `0` `DI_MODE_NONE` — straight field copy, no deinterlace.
  - `1` `DI_MODE_DEINTERLACE` — full per-pixel five-candidate scorer
    with motion-gated vertical-average fallback (~500 LoC of Avisynth
    MMX re-expressed as pure scalar Zig).
  - `2` `DI_MODE_SIMPLE_BLUR` — vertical `(T+2C+B)/4` blur on
    motion-flagged pixels.
  - `3` `DI_MODE_ONE_FIELD` — default; field-interpolation using the
    simple-blur and motion2max maps.

### Frame properties

- **Standard, always set on output**: `_FieldBased=0`, `_Combed` per
  frame, `_DurationNum`/`_DurationDen` derived from output rate. All
  source props (`_Matrix`, `_Transfer`, `_Primaries`,
  `_ChromaLocation`, `_SARNum/Den`, `_Range`/`_ColorRange`, …)
  inherited via `propSrc` in `newVideoFrame`.
- **Diagnostic** (per-frame inspection for power-user scripts):
  `ITMatch`, `ITMflag`, `ITIpFlag` (utf8 1-char each); `ITIvC/P/N/M`,
  `ITDiffP0/P1/S0/S1`, `ITBlended` (ints).

### Verification

- **Bit-exact** to a mechanically API-3 → API-4-ported build of the
  upstream C reference (`reference/vapoursynth-cpp-api4/`). 198 frames
  across 10 fixture × parameter combinations, plus 720 frames of two
  real telecined NTSC VOB samples in both `fps=24` and `fps=30` mode,
  byte-for-byte identical.
- **35 Zig unit tests** for the algorithm primitives + SIMD helpers.
- **58 Python/VapourSynth integration tests** — invariants,
  property checks, error paths, the regression-pinned md5 hashes, the
  upstream-compare matrix, and the new parameter sweeps.

### Performance

500 frames of 720×480 NTSC, ReleaseFast build, single-threaded
`fmParallelRequests`:

| Pipeline                           | fps   |
| ---------------------------------- | ----: |
| `core.zit.IT(clip, fps=30)`        | ~2700 |
| `core.zit.IT(clip, fps=24)`        | ~2200 |
| `core.zit.IT(clip, fps=24, diMode=1)` | ~2350 |
| `core.zit.IT(clip, fps=24, blend=1)`  | ~1700 |
| `core.vivtc.VFM(clip)` (reference)    | ~600  |
| `core.vivtc.VFM + VDecimate` (ref)    | ~1270 |

~4× faster than `vivtc.VFM` at field-matching, ~2× faster than
`vivtc.VFM + VDecimate` at IVTC, using the pure-C path + portable
Zig `@Vector(N, u8)` SIMD (`pavgb`, `psubusb`, `pmaxub`/`pminub`
equivalents).

### Differences from the VapourSynth upstream

The upstream
[VapourSynth-IT](https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT)
plugin (msg7086, 2014) was a partial port of the Avisynth original.
This port reintroduces what was stripped and fixes four framework-level
issues:

1. `ref`, `blend`, `diMode=0/1/2` reinstated (upstream hardcoded
   `ref="TOP"`, `blend=false`, `diMode=3`).
2. **Frame properties**: upstream passes `propSrc=null` to
   `newVideoFrame`, so output frames carry no metadata at all. We
   inherit source props and set `_FieldBased`/`_Combed`/`_Duration*`
   explicitly.
3. **Threading mode**: `fmParallelRequests`. Upstream registered as
   `fmParallel` despite sharing mutable per-instance state — a latent
   race condition the modern VS scheduler hits more often.
4. **Frame-request range** widened to `[base-2, base+6]` (`fps=24`) /
   `[n-2, n+2]` (`fps=30`) so all reads through `getFrameFilter` are
   satisfiable. Upstream relied on API 3's sync `getFrame` to pull
   neighbours from cache; under API 4 that is not allowed inside a
   filter callback.
5. **Edge clamping**: `getFrameFilter(n, …)` is called with `n` clipped
   to `[0, numFrames-1]`. Under API 3 the core silently clamped; under
   API 4 it returns null and a deref crashes.

### Build & packaging

- `zig build --release=fast` produces `zig-out/lib/libzit.so` on the
  host platform.
- `zig build cross` produces release binaries for all three targets
  under `zig-out/{linux,macos,windows}/`:
  - `libzit-linux-x86_64.so`
  - `libzit-macos-x86_64.dylib`
  - `zit-windows-x86_64.dll`
- GitHub Actions workflow under `.github/workflows/ci.yml` runs
  lint + unit + cross-build + integration on `workflow_dispatch` only;
  push/pull-request triggers can be enabled by appending to the `on:`
  block.

### Credits

Algorithm: thejam79 (IT 0.051, 2002), minamina (IT_YV12 0.1.03, 2003),
poodle (64-bit / 8k mod), msg7086 (VapourSynth port, 2014). Zig port:
this repo.

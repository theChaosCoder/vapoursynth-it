# zit — Inverse Telecine for VapourSynth (Zig port)

A Zig port of the [VapourSynth-IT](https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT)
plugin (3:2-pulldown removal for NTSC), with the Avisynth-original
parameters restored, high-bit-depth and 4:2:2/4:4:4 support, full
frame-property support, and `@Vector`-based SIMD.

Verified bit-exact against the upstream `--c` reference path across the
integration test grid (8-bit 4:2:0, the only format upstream supports)
and on real-world telecined NTSC VOB samples.

## Status

| Item | State |
| --- | --- |
| Algorithm port (~5200 LoC Zig) | ✅ |
| Bit-exact vs upstream C path | ✅ 8-bit 4:2:0 (198 fixture + 720 real-VOB frames) |
| 10/12/16-bit, 4:2:2, 4:4:4 | ✅ decisions bit-depth-deterministic; no external oracle exists (upstream is YV12-only) — guarded by consistency + golden tests |
| All Avisynth params (`ref`, `blend`, `diMode`) | ✅ |
| Frame properties | ✅ standard + diagnostic |
| SIMD via `@Vector` | ✅ ~2× over scalar, ~4× over VIVTC VFM |
| Cross-compile Linux / macOS (x86_64 + aarch64), Windows x86_64 | ✅ |
| CI workflow | ✅ lint + unit (Debug & ReleaseFast) + cross + gating integration suite |
| AI-assisted port | ✅ Anthropic's Claude — verified byte-for-byte against the upstream C reference |

## Quick start

```python
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource("source.vob")
clip = core.zit.IT(clip)          # default: fps=24, ref="TOP", diMode=3
clip.set_output()
```

## Plugin reference

Plugin **namespace**: `zit`. Function: `IT`.

Full signature:

```python
core.zit.IT(
    clip,
    fps=24,
    threshold=20,
    pthreshold=75,
    ref="TOP",
    blend=0,
    diMode=3,
)
```

### Parameters

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `clip` | `vnode` | — | Input clip. Integer YUV, 8/10/12/16-bit, 4:2:0 / 4:2:2 / 4:4:4. Width a multiple of 16 and ≤ 8192; height even (a multiple of 4 for 4:2:0), ≤ 8192; constant format and frame rate. |
| `fps` | `int` | `24` | `24` = inverse telecine (decimate 5→4, output rate is 4/5 of the input, e.g. 30000/1001 → 24000/1001 fps), `30` = field-matching only (input fps preserved). |
| `threshold` | `int` | `20` | Field-match decision sensitivity. Lower = more aggressive matching. Valid range 0–100000. |
| `pthreshold` | `int` | `75` | Progressive-classification threshold for `_Combed`. Adjusted internally for resolution. Below: frame is `ip='P'` (clean match); above: `ip='I'` (deinterlaced). Valid range 0–100000. |
| `ref` | `data` | `"TOP"` | Field-order / match-search direction (case-insensitive). One of: `TOP`, `BOTTOM`, `ALL`, `NONE` (see below). |
| `blend` | `int` (0/1) | `0` | When `1` and `fps=24`, blends adjacent post-matched frames with a triangular kernel for smoother 24p output. Motion-gated — only fires on high-motion 5-frame blocks. Ignored when `fps=30`. |
| `diMode` | `int` | `3` | Deinterlace strategy applied when a frame is classified `ip='I'`. See below. |

In `fps=24` mode, decimation carries the cadence forward from earlier blocks.
Seeking and parallel prefetch produce the same output as linear playback.
The first seek ahead analyzes any missing predecessors in small batches;
later requests reuse those decisions. This can add latency to the first seek.

### `ref` values

| Value | Avisynth name | Effect |
| --- | --- | --- |
| `"TOP"` | `REF_PREV` | Field match looks at the **previous** frame as the bottom-field source. Standard for TFF source. **Same as the VapourSynth upstream's behaviour.** |
| `"BOTTOM"` | `REF_NEXT` | Field match looks at the **next** frame. Use for BFF source. |
| `"ALL"` | `REF_ALL` | Evaluates both prev and next, picks the one with stronger evidence. |
| `"NONE"` | `REF_NONE` | Skips field-matching entirely; every frame is treated as interlaced and dispatched to the deinterlacer. |

### `diMode` values

| Value | Avisynth name | Behaviour |
| --- | --- | --- |
| `0` | `DI_MODE_NONE` | No deinterlace. Just field-copy from the chosen match (same as the clean-match path). |
| `1` | `DI_MODE_DEINTERLACE` | The full Avisynth deinterlacer: per-pixel scores C, P, N, avg(C,P), avg(C,N) and picks the lowest interlace score, with motion-gated vertical-average fallback. |
| `2` | `DI_MODE_SIMPLE_BLUR` | Vertical `(T + 2·C + B) / 4` blur on pixels flagged by the motion map. |
| `3` | `DI_MODE_ONE_FIELD` | **Default.** Field-interpolation using motion + simple-blur maps. The VapourSynth upstream hardcodes this mode. |

## Frame properties on output

### Standard (always set)

| Key | Type | Description |
| --- | --- | --- |
| `_FieldBased` | int | Always `0`. Output is progressive after IVTC. |
| `_Combed` | int | `0` if the algorithm matched cleanly (`ip='P'`), `1` if it had to deinterlace (`ip='I'`). |
| `_DurationNum`, `_DurationDen` | int | Per-frame duration derived from the **output** framerate. At `fps=24` mode this becomes `1001 / 24000` per frame instead of the source's `1001 / 30000`. |
| `_Matrix`, `_Transfer`, `_Primaries`, `_ChromaLocation`, `_Range`/`_ColorRange`, `_SARNum`/`_SARDen` | int | Inherited from the source frame via `propSrc`. Pass-through unchanged. |

### Diagnostic (set for inspection/scripting)

| Key | Type | Description |
| --- | --- | --- |
| `ITMatch` | utf8 (1 char) | Match decision: `'C'`, `'P'`, `'N'` (uppercase = strong, lowercase = weak), `'U'` if not evaluated. |
| `ITMflag` | utf8 (1 char) | Decimation code in `fps=24` mode: `'D'`/`'d'`/`'x'`/`'y'`/`'z'`/`'+'`/`'.'`. `'U'` in `fps=30` mode. |
| `ITIpFlag` | utf8 (1 char) | `'P'` (progressive) or `'I'` (interlaced); `'U'` if not run. |
| `ITIvC`, `ITIvP`, `ITIvN`, `ITIvM` | int | Interlace-evidence counters from EvalIV against C, P, N, and the chosen match M. |
| `ITDiffP0`, `ITDiffP1`, `ITDiffS0`, `ITDiffS1` | int | Motion-map stats: rough motion (P0/P1) and saturated motion (S0/S1) on even/odd field rows. |
| `ITBlended` | int (0/1) | `1` if the `blend=true` code path produced this output frame. |

Convention follows VFM/VDecimate (camelCase, plugin-name prefix, no dots
— VS API 4 silently rejects keys with dots).

## Building from source

Requires Zig 0.17.0 (also used by CI and release builds). The VapourSynth
API 4 bindings come from the
[`vapoursynth-zig`](https://github.com/dnjulek/vapoursynth-zig) package
pinned in `build.zig.zon`, explicitly configured for API 4.0 (VapourSynth R55+).

```bash
zig build --release=fast            # native shared library -> zig-out/lib/libzit.so
zig build test                       # unit tests (also run with --release=fast in CI)
zig build cross                      # release artefacts for all five targets
```

Cross-compile produces (ReleaseFast, stripped):
- `zig-out/linux-x86_64/libzit.so`, `zig-out/linux-aarch64/libzit.so`
- `zig-out/macos-x86_64/libzit.dylib`, `zig-out/macos-aarch64/libzit.dylib`
- `zig-out/windows-x86_64/zit.dll`

Release binaries target glibc 2.17+, macOS 10.9+ (Intel), and macOS 11.0+
(Apple Silicon). `scripts/build_pypi_wheels.py` checks binary deployment
requirements against the wheel tags before packaging. Run the compatibility
regressions after cross-compiling with
`python -m unittest discover -s tests/packaging -v`.

## Installation

### Via pip (recommended)

```bash
pip install vapoursynth-zit
```

The wheel installs the platform-matched binary into VapourSynth's
auto-discovery path (`site-packages/vapoursynth/plugins/`), so
`core.zit.IT(...)` is available without any further `LoadPlugin`
calls.

Pre-built wheels are available for Linux (x86_64, aarch64), macOS
(x86_64, aarch64), and Windows (x86_64).

### Manual install (zip from a release)

If you'd rather not pull in pip, grab the matching `*.zip` from the
[Releases page](https://github.com/theChaosCoder/vapoursynth-it/releases)
and drop the binary into a VapourSynth plugin directory:

* Linux: `/usr/local/lib/vapoursynth/`
* macOS: `~/Library/ApplicationSupport/VapourSynth/plugins/`
* Windows: `vapoursynth64/plugins/` next to `vsedit.exe`

## Performance

Measured 2026-10-03 on an AMD Ryzen 5 9600X, VapourSynth **R81RC1 / API 4.3**,
Python 3.14.7, Zig 0.17.0 ReleaseFast/native (`fmUnordered`), and the
`vapoursynth-vivtc` 2.0 wheel. Both VOBs are 720×480 YUV420P8 at 30000/1001
fps. VIVTC was refreshed with `uv pip`; 2.0 remains the latest PyPI release.
The zit and VIVTC binary hashes are identical to the earlier R76 benchmark.

Median **output frames/second** over five runs. Each run uses a fresh filter
chain and processes 3000 input frames after a 250-input-frame warmup, starting
at input frame 9000. Source frames are predecoded and held in a fixed cache;
the benchmark asserts that no source evaluation occurs during the runs.
Timing includes bounded asynchronous frame requests (prefetch equals the
worker count), without encoding, pixel copying, or hashing. Run order is
randomized. These are filter-throughput measurements, not encode speeds.

| Source | VS workers | zit fps=30 | VFM | zit fps=24 | VFM → VDecimate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `eyeVTS_01_1.VOB` | 1 | 6732 | 986 | 5815 | 775 |
| `eyeVTS_01_1.VOB` | 8 | 8078 | 4757 | 6748 | 3360 |
| `gbVTS_01_1.VOB` | 1 | 4097 | 810 | 3430 | 632 |
| `gbVTS_01_1.VOB` | 8 | 4517 | 4219 | 3741 | 3053 |

VFM uses `order=1, field=1`, otherwise defaults; VDecimate uses defaults.
The main zit columns include its default deinterlacing fallback (`diMode=3`).
[VFM has no such postprocessing](https://github.com/vapoursynth/vivtc#vivtc).
With zit's fallback disabled (`fps=30, diMode=0`), the eight-worker results
are **8051 fps** (eye) and **7870 fps** (gb), respectively 1.69× and 1.87×
VFM. This is a throughput comparison between different algorithms, not an
image-quality or pixel-equivalence claim.

Both plugins run on the CPU. VFM uses `fmParallel` and scales substantially
with multiple workers; zit's processing remains serialized. With eight
workers, default zit field matching is 1.70× VFM on eye and 1.07× on gb.
The full zit IVTC pipeline is 2.01× / 1.23× VFM → VDecimate on these clips.
The cached-source control measured 57–59k fps, well above the filter rates.

Compared with the [R76 measurements](docs/benchmarks/2026-10-03-vivtc.json),
the median throughput changed as follows (same input interval, parameters,
plugin binaries, Python version, and request scheduling in the harness):

| Source | VS workers | zit fps=30 | VFM | zit fps=24 | VFM → VDecimate |
| --- | ---: | ---: | ---: | ---: | ---: |
| eye | 1 | −9.8% | −4.2% | −8.3% | −2.5% |
| eye | 8 | +11.0% | −1.4% | +6.8% | +0.2% |
| gb | 1 | −7.1% | −3.4% | −6.2% | −2.7% |
| gb | 8 | +4.7% | +2.9% | +3.8% | −1.0% |

These are observations from two benchmark batches, not isolated kernel
measurements. Small changes, particularly the multi-worker VFM results,
overlap the observed run ranges. All 200 integration tests also pass on R81RC1.

[R81RC1 raw measurements, ranges, and binary hashes](docs/benchmarks/2026-10-03-vivtc-r81rc1.json)
are recorded alongside the reproducible harness. To use the same runtime
(Python 3.12+ required):

```bash
zig build --release=fast
uv pip install --python .venv/bin/python --upgrade "VapourSynth==81rc1" vapoursynth-vivtc
.venv/bin/python scripts/bench_vivtc.py /path/to/eyeVTS_01_1.VOB /path/to/gbVTS_01_1.VOB \
  --json build/bench_vivtc_r81rc1.json
```

VIVTC is autoloaded from the environment. For a separate binary, pass
`--vivtc-plugin /path/to/vivtc.so`; the harness records the loaded file's hash
and rejects an explicit path that differs from an already loaded plugin.

## Differences from the VapourSynth upstream

The VapourSynth upstream (`HomeOfVapourSynthEvolution/VapourSynth-IT`)
ported only a subset of the Avisynth original. This port reintroduces
everything plus fixes a few latent bugs:

1. **Avisynth-original parameters back**: `ref` (TOP/BOTTOM/ALL/NONE),
   `blend`, `diMode` (0/1/2/3). The upstream hardcoded
   `ref="TOP"`/`blend=false`/`diMode=3` and removed the parameters.
2. **Frame properties** (`_FieldBased`, `_Combed`, `_Duration*`,
   inheritance of source props, plus `IT*` diagnostics). Upstream calls
   `newVideoFrame(propSrc=null)` so output frames carry no metadata,
   which breaks downstream `core.resize.*` colorspace handling.
3. **Threading**: registered as `fmUnordered` to serialize state access and
   request planning. Decimation blocks are analyzed in source order, making
   seeking and prefetch deterministic. Upstream uses `fmParallel` despite
   sharing mutable per-instance state across calls.
4. **Frame request range**: widened to cover what the algorithm actually
   reads (`[base-2, base+6]` for fps=24, `[n-2, n+2]` for fps=30 — plus
   `[base-3, base+7]` when `blend=true`). Upstream relied on the
   API 3 sync `getFrame` to retrieve neighbours, which is no longer
   permitted from inside `getFrameFilter` under API 4.
5. **Edge clamping** of frame indices passed to `getFrameFilter`. The
   upstream algorithm fetches `n-1` even at `n=0`; under API 3 the core
   silently clamped, under API 4 it returns null and dereferences crash.

The reference build under `reference/vapoursynth-cpp-api4/` applies the
same framework-level fixes (otherwise it would segfault under VS R76)
and is what the bit-exact comparison test runs against.

## Repository layout

```
src/
├── plugin.zig    # VapourSynth plugin entry (VapourSynthPluginInit2)
├── filter.zig    # Filter instance + getFrame lifecycle + frame-prop setting
├── state.zig     # CFrameInfo, CTFblockInfo, CallState
├── plane.zig     # syp/dyp accessors, adjPara, clipFrame/X/Y
├── edge.zig      # makeDeMap                (SIMD)
├── eval_iv.zig   # evalIv                    (SIMD)
├── motion.zig    # makeMotionMap, makeMotionMap2Max/Min, makeSimpleBlurMap (SIMD)
├── scene.zig     # checkSceneChange          (SIMD)
├── decide.zig    # compCp / compCn / decide / setFt
├── output.zig    # copyCPNField / deintOneField / simpleBlur / deinterlace
├── blend.zig     # BlendFrame_YV12 port
├── simd.zig      # @Vector helpers (pavgb, absDiff, subSat, expandPairs)
└── scalar.zig    # scalar twins of the SIMD helpers (pavgbScore, toMapByte)

reference/
├── avisynth/                # original IT_YV12 0.1.03 source (read-only)
├── vapoursynth-cpp/         # upstream VS-IT @ 6fc9be8 (read-only)
└── vapoursynth-cpp-api4/    # mechanical API3→API4 port of upstream; build for bit-exact comparison

tests/integration/           # pytest suite — properties, golden hashes, upstream-compare, determinism, bit depth
scripts/                     # gen_testclip / param_grid / regen_golden / compare_upstream / compare_vivtc / ...
docs/upstream_reference.md   # design notes
```

## Credits

- Original IT 0.051 — **thejam79** (2002)
- Avisynth IT_YV12 0.1.03 — **minamina** (2003)
- 64-bit / 8k mod — **poodle**
- VapourSynth port — **msg7086** (2014)
- Zig port — this repo

## License

GPL-2.0-or-later (inherited from upstream). See [`LICENSE`](LICENSE).

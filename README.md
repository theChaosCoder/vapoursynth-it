# zit — Inverse Telecine for VapourSynth (Zig port)

A Zig port of the [VapourSynth-IT](https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT)
plugin (3:2-pulldown removal for NTSC), with the Avisynth-original
parameters restored, full frame-property support, and `@Vector`-based
SIMD.

Verified bit-exact against the upstream `--c` reference path across the
integration test grid and on real-world telecined NTSC VOB samples.

## Status

| Item | State |
| --- | --- |
| Algorithm port (8 modules, ~2200 LoC Zig) | ✅ |
| Bit-exact vs upstream C path | ✅ (198 fixture + 720 real-VOB frames) |
| All Avisynth params (`ref`, `blend`, `diMode`) | ✅ |
| Frame properties | ✅ standard + diagnostic |
| SIMD via `@Vector` | ✅ ~2× over scalar, ~4× over VIVTC VFM |
| Cross-compile Linux / macOS / Windows x86_64 | ✅ |
| CI workflow | ✅ (lint + unit + cross + best-effort integration) |
| v1.3.0 release | ✅ |
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
| `clip` | `vnode` | — | Input clip. Must be **YUV420P8**, width a multiple of 16, height even, width ≤ 8192. |
| `fps` | `int` | `24` | `24` = inverse telecine (decimate 5→4, output 24000/1001 fps), `30` = field-matching only (input fps preserved). |
| `threshold` | `int` | `20` | Field-match decision sensitivity. Lower = more aggressive matching. |
| `pthreshold` | `int` | `75` | Progressive-classification threshold for `_Combed`. Adjusted internally for resolution. Below: frame is `ip='P'` (clean match); above: `ip='I'` (deinterlaced). |
| `ref` | `data` | `"TOP"` | Field-order / match-search direction (case-insensitive). One of: `TOP`, `BOTTOM`, `ALL`, `NONE` (see below). |
| `blend` | `int` (0/1) | `0` | When `1` and `fps=24`, blends adjacent post-matched frames with a triangular kernel for smoother 24p output. Motion-gated — only fires on high-motion 5-frame blocks. Ignored when `fps=30`. |
| `diMode` | `int` | `3` | Deinterlace strategy applied when a frame is classified `ip='I'`. See below. |

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

Requires Zig 0.16.0+. Headers (VapourSynth API 4) are vendored in
`vendor/vapoursynth/`.

```bash
zig build --release=fast            # native shared library -> zig-out/lib/libzit.so
zig build test                       # 35 unit tests
zig build cross                      # cross-compiled artefacts under zig-out/{linux,macos,windows}/
```

Cross-compile produces:
- `zig-out/linux/libzit.so` (x86_64, ~170 KB)
- `zig-out/macos/libzit.dylib` (x86_64)
- `zig-out/windows/zit.dll` (x86_64) + `.pdb`

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

500 frames of a 720×480 NTSC telecined VOB, ReleaseFast build:

| Pipeline | fps |
| --- | --- |
| `core.zit.IT(clip, fps=30)` | **2697** |
| `core.zit.IT(clip, fps=24)` | 2236 |
| `core.zit.IT(clip, fps=24, diMode=1)` | 2355 |
| `core.zit.IT(clip, fps=24, diMode=2)` | 2459 |
| `core.zit.IT(clip, fps=24, blend=1)` | 1725 |
| `core.vivtc.VFM(clip, order=1)` | 596 |
| `core.vivtc.VFM` → `core.vivtc.VDecimate` | 1271 |

`zit fps=30` is ~4.5× faster than `vivtc.VFM`; `zit fps=24` is ~1.8×
faster than `vivtc.VFM + VDecimate`.

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
3. **Threading**: registered as `fmParallelRequests`. Upstream uses
   `fmParallel` despite sharing mutable per-instance state across calls
   — a latent race condition that VS R55+ exposes more often.
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
├── c.zig         # @cImport of vendored VS API 4 headers
├── state.zig     # CFrameInfo, CTFblockInfo, CallState
├── plane.zig     # syp/dyp accessors, adjPara, clipFrame/X/Y/YH
├── edge.zig      # makeDeMap                (SIMD)
├── eval_iv.zig   # evalIv                    (SIMD)
├── motion.zig    # makeMotionMap, makeMotionMap2Max/Min, makeSimpleBlurMap (SIMD)
├── scene.zig     # checkSceneChange          (SIMD)
├── decide.zig    # compCp / compCn / decide / setFt
├── output.zig    # copyCPNField / deintOneField / simpleBlur / deinterlace
├── blend.zig     # BlendFrame_YV12 port
└── simd.zig      # @Vector helpers (pavgb, absDiff, subSat, expandPairs)

reference/
├── avisynth/                # original IT_YV12 0.1.03 source (read-only)
├── vapoursynth-cpp/         # upstream VS-IT @ 6fc9be8 (read-only)
└── vapoursynth-cpp-api4/    # mechanical API3→API4 port of upstream; build for bit-exact comparison

tests/integration/           # 58 pytest cases — property checks, golden hashes, upstream-compare
scripts/                     # gen_testclip / regen_golden / compare_upstream / compare_vivtc / test_real_video
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

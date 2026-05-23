# Zig port of VapourSynth-IT (namespace `zit`)

> Inverse-Telecine plugin (3:2-pulldown removal) for VapourSynth,
> originally the Avisynth plugin `IT.dll` (thejam79 2002,
> minamina 2003), ported to VapourSynth in 2014 by msg7086. This
> project re-implements the same algorithm in **Zig**, with usable
> binaries for **Linux, macOS, Windows (64-bit)** and reproducible
> tests.

- Upstream reference: <https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT>
  (commit `6fc9be8`, locally unpacked under `/tmp/vs-it-ref/`).
- Original Avisynth source: `Avisynth_IT_YV12/src/` (provided locally).
- Target GitHub repo: <https://github.com/theChaosCoder/vapoursynth-it>
  (already exists, private, default branch empty at start).
- License: GPL-2.0-or-later (inherited from upstream).
- Build toolchain: Zig 0.16.0 (locally installed).

---

## 1. Scope & design decisions

| Item | Decision | Reasoning |
| --- | --- | --- |
| **Language** | Zig 0.16.0 | Native cross-compile (Linux/macOS/Windows), good C ABI, tests built-in. |
| **VapourSynth API** | **API 4** (R55+) | Current standard. C++ upstream still uses API 3 — we migrate. |
| **Plugin namespace** | `zit` | User-chosen (invocation: `core.zit.IT(clip, ...)`). |
| **Function name** | `IT` | Same as upstream, transparent drop-in. |
| **Input format** | YUV420P8 (as upstream) | 1:1 behaviour; bit-exact verification against C++ reference. |
| **Parameters** | `fps`, `threshold`, `pthreshold` (same defaults: 24 / 20 / 75) | As upstream. `ref`, `blend`, `diMode` re-added later (matched to Avisynth original). |
| **Algorithm base** | Pure C path (`__C` in `vs_it_c.cpp`) | Platform-independent, no inline asm / intrinsics required. SIMD added later via Zig `@Vector`. |
| **Bit identity** | Target: bit-exact to upstream C variant | md5 of pixel data versus `--c` build of the C++ version. |
| **Threading** | Initially `fmParallelRequests` | Upstream uses `fmParallel` with shared per-frame state → race condition. Serial = correct. |
| **Build** | `zig build` as single source of truth | Produces `.so`, `.dylib`, `.dll` for x86_64. ARM64 nice-to-have. |
| **Tests** | Zig unit tests + Python/VapourSynth integration tests against golden frames | Algorithm primitives isolated; end-to-end against reference clip. |
| **CI** | GitHub Actions matrix (Linux/macOS/Windows), enabled manually first | User request: "activate CI later". Workflow file with `workflow_dispatch` only. |

### Deliberately not ported (matches upstream state)

- `blend`, `ref`, `diMode` parameters (initial phase: upstream removed them; we restore later).
- YUY2 path (not in upstream).
- MMX/SSE code (`vs_it_mmx.cpp`, `vs_it_sse.cpp`) — the C path is the reference.

### Known upstream bugs to fix

1. `fmParallel` + shared `m_frameInfo[]` → race. **Fix:** serial execution.
2. `freeNode` is commented out inside `itFree` due to a deadlock. **Fix:** correct API-4 lifecycle.
3. Manual `_aligned_malloc`/`free` per frame. **Fix:** reuse per-instance buffers, with a Zig allocator.

---

## 2. Analysis: what's available, what's missing

### Available

- Original Avisynth IT_YV12 0.1.03 sources (`Avisynth_IT_YV12/src/`).
- VapourSynth-IT sources (upstream tarball, locally unpacked; 2479 LoC C/C++).
- Zig 0.16.0 toolchain.
- `gh` CLI authenticated as `theChaosCoder` (with `repo`, `workflow` scopes).
- Target repo exists (private, empty).

### To obtain / generate

- **VapourSynth headers** (`VapourSynth4.h`, `VSHelper4.h`, `VSScript4.h`):
  from the official [vapoursynth/vapoursynth](https://github.com/vapoursynth/vapoursynth)
  repo. Vendored under `vendor/vapoursynth/` (LGPL-compatible).
- **Reference build of the C++ version** for golden frames: built once
  with `--c`, generated md5 lists checked in.
- **Test clips**: synthetic, generated (via `core.std.BlankClip` +
  telecine pattern), no external assets. Keeps the repo small and
  reproducible.
- **CI workflow** (`.github/workflows/ci.yml`) — initial trigger only
  `workflow_dispatch`, others added later.

### Algorithm surface (functions to port)

From `vs_it_c.cpp` / `vs_it_process.cpp` / `vs_it.cpp`:

| Function | Purpose | LoC |
| --- | --- | --- |
| `IT::IT` (constructor) | State arrays, AdjPara, fps tweak | ~30 |
| `GetFramePre`, `GetFrame`, `GetFrameSub`, `MakeOutput` | VS lifecycle | ~120 |
| `EvalIV_YV12` | Per-frame interlace voting | ~70 |
| `MakeDEmap_YV12` | Differential edge map | ~30 |
| `MakeMotionMap_YV12` | Motion detection prev↔curr | ~60 |
| `MakeMotionMap2Max_YV12` | Motion prev/next/max | ~50 |
| `MakeSimpleBlurMap_YV12` | Blur map for deint | ~40 |
| `ChooseBest`, `CompCP` | Match selection C/P/N | ~110 |
| `Decide`, `SetFT` | 5-frame block decimation (24fps pulldown) | ~180 |
| `CopyCPNField`, `DeintOneField_YV12` | Frame output | ~170 |
| `DrawPrevFrame`, `CheckSceneChange` | Scene-change handling | ~60 |
| **Σ core logic** | | **~920 LoC** C++ → ~800–900 LoC Zig expected |

Plus ~100 LoC of API glue (plugin init, filter create, property getters).

---

## 3. Project layout (planned)

```
.
├── build.zig                # cross-compile targets, test steps
├── build.zig.zon            # dependencies (none expected)
├── src/
│   ├── plugin.zig           # VS plugin init, filter registration
│   ├── filter.zig           # IT instance + GetFrame lifecycle
│   ├── algo/
│   │   ├── eval_iv.zig      # EvalIV_YV12
│   │   ├── motion.zig       # MakeMotionMap / MakeMotionMap2Max / MakeSimpleBlurMap
│   │   ├── edge.zig         # MakeDEmap_YV12
│   │   ├── decide.zig       # ChooseBest / Decide / CompCP / SetFT
│   │   ├── output.zig       # CopyCPNField / DeintOneField / DrawPrevFrame
│   │   └── scene.zig        # CheckSceneChange
│   ├── frame_state.zig      # CFrameInfo / CTFblockInfo Zig equivalents
│   └── vs.zig               # @cImport(VapourSynth4.h) + thin wrappers
├── tests/
│   ├── unit/                # in-source tests via `zig build test`
│   └── integration/
│       ├── conftest.py
│       ├── test_golden.py   # process a reference clip, compare md5
│       └── fixtures/
│           └── golden_hashes.txt
├── vendor/
│   └── vapoursynth/         # VapourSynth4.h, VSHelper4.h (LGPL)
├── scripts/
│   ├── make_reference.sh    # builds upstream C++ with --c, emits golden hashes
│   └── gen_testclip.py      # synthetic telecined clip
├── .github/workflows/
│   └── ci.yml               # workflow_dispatch only initially
├── README.md
├── LICENSE                  # GPL-2.0 (from upstream)
└── PLAN.md                  # this document
```

---

## 4. Phased TODO

> Order is intentional: infrastructure first, then a "dumbest" end-to-end
> pass-through (identity filter), then the algorithm piece by piece, with
> golden-frame verification as a safety net.

### Phase 0 — Bootstrap & repo

- [x] Initialise local git repo
- [x] Take `LICENSE` from upstream (GPL-2.0)
- [x] Create `README.md` with "work in progress" notice (later expanded)
- [x] `.gitignore` (zig-out/, zig-cache/, .zig-cache/, build/, *.so, *.dll, *.dylib, __pycache__)
- [x] Commit this `PLAN.md`
- [x] Place VapourSynth headers (`VapourSynth4.h`, `VSHelper4.h`) under `vendor/vapoursynth/`
- [x] Move the Avisynth original sources from `Avisynth_IT_YV12/` to `reference/avisynth/` (read-only docs)
- [x] Upstream reference sources to `reference/vapoursynth-cpp/` (for side-by-side comparison)
- [x] `git remote add origin https://github.com/theChaosCoder/vapoursynth-it.git`
- [x] Initial commit, push to a new `main` branch

### Phase 1 — Build system & skeleton

- [x] `build.zig`: shared-library target `zit` (Linux .so, macOS .dylib, Windows .dll), Linux/macOS PIC
- [x] `build.zig`: cross-compile steps for `x86_64-windows-gnu`, `x86_64-macos`, `x86_64-linux-gnu` (all from a Linux host)
- [x] `build.zig`: `test` step for Zig unit tests
- [x] `src/vs.zig`: `@cImport` of the VapourSynth headers, wrapper types
- [x] `src/plugin.zig`: `VapourSynthPluginInit2` export, registers `IT` in namespace `zit` with argsig `clip:vnode;fps:int:opt;threshold:int:opt;pthreshold:int:opt;`
- [x] `src/filter.zig`: identity filter (input → output 1:1) — smoke test
- [x] Verify: `vspipe -i -` loads the plugin on Linux, `core.zit.IT(clip)` runs without crashing and returns unchanged frames
- [ ] Verify: same smoke test against the Windows DLL via Wine or under a Windows VM (manual, before CI activation)

### Phase 2 — Algorithm port (tests per step)

> Each function gets: Zig implementation + Zig unit test against hand-built
> mini pixel arrays + end-to-end md5 match.

- [x] `frame_state.zig`: `CFrameInfo`, `CTFblockInfo`, allocation/init like upstream
- [x] `algo/edge.zig`: `makeDeMap` + unit test (4×4 block, known output)
- [x] `algo/motion.zig`: `makeMotionMap`, `makeMotionMap2Max`, `makeSimpleBlurMap` + tests
- [x] `algo/eval_iv.zig`: `evalIv` + test
- [x] `algo/decide.zig`: `chooseBest`, `compCp`, `decide`, `setFt` + tests (state-based, block-level)
- [x] `algo/scene.zig`: `checkSceneChange` + test
- [x] `algo/output.zig`: `copyCPNField`, `deintOneField`, `drawPrevFrame` + tests
- [x] `filter.zig`: complete `getFrame` lifecycle, including `requestFrameFilter` for the 5-frame blocks at fps=24
- [x] Clean frame-state reset between calls (no cross-frame leaks)
- [x] Correct handling of clip-boundary edge cases (`clipFrame`)

### Phase 3 — Verification (golden-frame tests)

- [x] `scripts/gen_testclip.py`: 5 synthetic fixtures (flat colour, mod-16 width, telecine, interlaced stripes)
- [x] `reference/vapoursynth-cpp-api4/`: mechanical API3→API4 port of the upstream plugin (algorithm unchanged). `scripts/build_upstream_api4.sh` builds `libit.so`.
- [x] `scripts/regen_golden.py`: emit golden md5s from the Zig build → `tests/integration/fixtures/golden_hashes.txt`
- [x] `scripts/compare_upstream.py`: direct Zig ↔ upstream-API4-port comparison
- [x] `tests/integration/test_filter.py`: 25+ tests — property/invariant + golden hashes + error paths
- [x] `tests/integration/test_upstream_compare.py`: 10 tests — bit-exact Zig ↔ upstream over the full parameter grid (198 frames, 0 mismatched)
- [x] Tests for `fps=24` and `fps=30`
- [x] Tests for different resolutions (128×96, 176×96, 720×480)
- [x] Tests for threshold / pthreshold variation
- [ ] Tests for clip boundaries (first/last 5-frame block) — implicitly covered by fixtures, could be made explicit
- [ ] `--c` vs `--sse` upstream comparison — skipped because the `--c` path is what we treat as ground truth

### Phase 4 — Cross-compile & distribution

- [x] `zig build -Dtarget=x86_64-linux-gnu` → produces `libzit.so`
- [x] `zig build -Dtarget=x86_64-macos` → produces `libzit.dylib`
- [x] `zig build -Dtarget=x86_64-windows-gnu` → produces `zit.dll`
- [ ] Optional: `aarch64-macos`, `aarch64-linux-gnu` targets
- [x] Smoke-test the Linux `.so` locally
- [ ] Smoke-test the Windows `.dll` (Wine or Windows host)
- [ ] Smoke-test the macOS `.dylib` (on a macOS host, later)
- [ ] Release script: `zig build release` packages all three under `dist/zit-<version>-<os>.zip`

### Phase 5 — CI (inactive, prepared)

- [ ] `.github/workflows/ci.yml` with jobs:
  - `lint`: `zig fmt --check`
  - `unit`: `zig build test` on Ubuntu
  - `cross-build`: matrix Linux/macOS/Windows, all from a Linux runner via Zig
  - `integration`: Ubuntu + VapourSynth via apt, loads the Zig plugin, runs pytest
- [ ] Trigger initially `workflow_dispatch:` only (so PR/push doesn't run CI)
- [ ] README note: "CI activation pending"
- [ ] Once everything is green: add `pull_request` and `push: [main]` triggers (separate commit, explicitly initiated by the user)

### Phase 6 — Docs & release

- [x] README with build instructions, example, differences vs the C++ upstream
- [ ] CHANGELOG with "v0.1.0 — initial Zig port"
- [x] Clarify in README: same GPL-2.0 licence, same credits to thejam79/minamina/msg7086
- [ ] Check the repo can be made public (no secret paths, no tokens)
- [ ] Tag `v0.1.0`, GitHub release with three binaries

---

## 5. Open items (default assumptions, override if needed)

| Question | Default assumption |
| --- | --- |
| Make the repository public? | Stays private for now, later `gh repo edit --visibility public` |
| Avisynth original in the repo? | Yes, under `reference/avisynth/` (read-only docs) |
| Bit-exact to the upstream C variant as a hard goal? | Yes. If upstream bugs prevent bit identity: document and tag the test as "differs intentionally". |
| Parallelise threading? | Initially `fmParallelRequests` (correct). Parallel optional later. |
| Pin Zig version long-term? | Yes, `0.16.0` via `minimum_zig_version` in `build.zig.zon`. |
| ARM64 targets in the first release? | Nice-to-have, no blocker. |

---

## 6. Risks

- **Bit identity may not be achievable**: if upstream `--sse` and `--c`
  already diverge, "bit-exact" only makes sense against one path.
  Mitigation: test against `--c`, document in the docs.
- **VapourSynth API 4 migration**: function names changed (`vsapi->`
  often the same semantics but different signature). Mitigation: a thin
  `vs.zig` wrapper layer absorbs the API differences.
- **Test Windows build without a Windows host**: Zig cross-compiles, but
  the finished `.dll` must load in VapourSynth-Windows. Mitigation:
  Wine locally, later CI on `windows-latest`.
- **macOS code-signing**: a dylib for non-developer-tools may need
  signing. Mitigation: note in the README, not a blocker.
- **Performance**: the pure C path is ~30% slower than SSE2 (per
  upstream changelog). Mitigation: add `@Vector(16, u8)` later.

---

## 7. Definition of Done for "v0.1.0"

1. `zig build test` green.
2. Three binaries (`.so`, `.dylib`, `.dll`) produced locally.
3. Integration test: ≥3 test clips, both `fps=24` and `fps=30`, all
   frames md5-identical to the upstream C reference.
4. README documents build, invocation (`core.zit.IT(...)`), limitations.
5. The repository `theChaosCoder/vapoursynth-it` contains source code,
   plan, CI skeleton (inactive), release v0.1.0 with three binaries.

# VapourSynth-IT upstream — API 4 port

This tree is a **mechanical migration** of the upstream
[VapourSynth-IT](https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT)
plugin (commit `6fc9be8`, originally targeting VapourSynth API 3) to
VapourSynth **API 4**. It exists exclusively as a **bit-exact
reference** for the Zig port — see `docs/upstream_reference.md` for
the why.

The algorithm itself is unchanged. The diff against
`reference/vapoursynth-cpp/` is purely API-shim:

| Change                                | Reason                                              |
| ------------------------------------- | --------------------------------------------------- |
| `VSNodeRef` → `VSNode`                | renamed in API 4                                    |
| `VSFrameRef` → `VSFrame`              | renamed in API 4                                    |
| `propGetInt` → `mapGetIntSaturated`   | maps replaced "prop" terminology                    |
| `propGetNode` → `mapGetNode`          | same                                                |
| `setError` → `mapSetError`            | same                                                |
| `vsapi->createFilter`                 | → `vsapi->createVideoFilter` + `VSFilterDependency` |
| `vsapi->setVideoInfo` (in `itInit`)   | gone in API 4; passed to `createVideoFilter` directly. `itInit` deleted. |
| `VapourSynthPluginInit`               | → `VapourSynthPluginInit2(VSPlugin*, const VSPLUGINAPI*)` |
| `void **instanceData`                 | → `void *instanceData` (no double indirection)      |
| `cmYUV`                               | → `cfYUV`                                           |
| `vi->format->...`                     | → `vi->format....` (format is now a value, not a pointer) |
| `vsapi->getFrame(n, node, nullptr, 0)` (sync) inside `getFrame` callback | → `getFrameFilter(n, node, frameCtx)` (the only legal option under API 4) |
| `IScriptEnvironment::GetFrame(n)`     | clips `n` to `[0, numFrames-1]` (upstream relied on the API 3 sync API tolerating out-of-range; `getFrameFilter` does not) |
| `GetFramePre` request range           | widened from `[base, base+5]` / `{n}` to `[base-2, base+6]` / `[n-2, n+2]` to cover the same frame reach upstream got for free from the sync API |
| `fmParallel`                          | → `fmParallelRequests` (the upstream's `fmParallel` claim is racy against the shared `m_frameInfo[]`; VS R4 serialises requests under this mode) |
| `vsapi->freeNode(d->node)` in `itFree` | restored (upstream had this commented out due to an API 3 Linux deadlock that does not reproduce here) |
| `vs_bitblt`                           | aliased to `vsh::bitblt` via macro                  |
| `vs_aligned_malloc` / `_aligned_free` | rewired to `vsh::vsh_aligned_malloc<unsigned char>` / `vsh::vsh_aligned_free` |
| `using namespace vsh;`                | added so the bare `bitblt` / aligned-malloc names resolve |
| SIMD source files                     | removed (`vs_it_mmx.cpp`, `vs_it_sse.cpp`) — they use MSVC inline asm that doesn't compile under clang/g++ on Linux; we only need the `__C` reference path |
| `__C` define                          | not renamed here; clang's `<crc32intrin.h>` collision is sidestepped by forcing `-std=c++17` |

## Building

```bash
cd reference/vapoursynth-cpp-api4
PKG_CONFIG_PATH= ./configure --c --cxx=clang++ --extra-cxxflags='-std=c++17'
make
```

That produces `libit.so` in this directory. Load it into VapourSynth as
`core.it`; the Zig port loads as `core.zit`. Both can coexist in the
same core, which is exactly what `scripts/compare_upstream.py` and
`tests/integration/test_upstream_compare.py` do to verify bit-identity.

`scripts/build_upstream_api4.sh` automates the above.

## Bit-exact identity to the Zig port

As of 2026-05-23 the Zig port and this API-4 reference produce
**byte-identical output** across the integration test grid
(10 fixture × parameter combinations, 198 frames total). The CI
integration test `tests/integration/test_upstream_compare.py` enforces
this on every run where `libit.so` is present.

## License

GPL-2.0-or-later — same as upstream. All credit for the algorithm
remains with thejam79 (2002), minamina (2003), and msg7086 (2014).

# zit — Inverse Telecine for VapourSynth (Zig port)

> ⚠️ **Work in progress.** This is a fresh Zig port of the
> [VapourSynth-IT](https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT)
> plugin. Nothing is functional yet — see [`PLAN.md`](PLAN.md) for the roadmap.

Inverse-Telecine / 3:2-Pulldown removal filter, originally an Avisynth
plugin by [thejam79](https://web.archive.org/web/*/thejam79*) (2002) and
[minamina](https://web.archive.org/web/*/minamina*) (2003), ported to
VapourSynth by [msg7086](https://github.com/msg7086) in 2014. This repo
re-implements the same algorithm in [Zig](https://ziglang.org/) targeting
VapourSynth API 4, with cross-compiled binaries for Linux, macOS and
Windows (x86_64).

## Status

| Item | State |
| --- | --- |
| Plan & TODO | ✅ [`PLAN.md`](PLAN.md) |
| Build system | ⏳ pending |
| Algorithm port | ⏳ pending |
| Golden-frame tests | ⏳ pending |
| CI | 🚧 workflow file pending, activation later |

## Planned usage

```python
import vapoursynth as vs
core = vs.core

clip = core.std.BlankClip(format=vs.YUV420P8, length=300,
                         fpsnum=30000, fpsden=1001, width=720, height=480)
clip = core.zit.IT(clip, fps=24, threshold=20, pthreshold=75)
```

Plugin namespace: **`zit`**. Function: `IT(clip, fps=24, threshold=20, pthreshold=75)`.

## Credits

- Original IT 0.051 — thejam79 (2002)
- Avisynth IT_YV12 0.1.03 — minamina (2003)
- 64-bit / 8k mod — poodle
- VapourSynth port — msg7086 (2014)
- Zig port — this repo

## License

GPL-2.0-or-later (inherited from upstream). See [`LICENSE`](LICENSE).

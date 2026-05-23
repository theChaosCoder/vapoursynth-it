# Vendored VapourSynth API 4 headers

Files in this directory are taken verbatim from
[vapoursynth/vapoursynth](https://github.com/vapoursynth/vapoursynth)
(master branch, fetched 2026-05-23):

- `VapourSynth4.h` — core API 4 definitions
- `VSHelper4.h` — utility macros and inline helpers
- `VSConstants4.h` — color-space / format constants

These headers are **LGPL-2.1-or-later** (see `COPYING.LESSER`). The rest of
this project is GPL-2.0-or-later, which is compatible with linking against
LGPL code.

We only ship the headers — no VapourSynth code/binaries. The plugin is
loaded at runtime by a VapourSynth core the user already has installed.

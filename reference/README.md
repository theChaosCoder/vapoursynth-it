# Reference sources

These trees are **read-only references** for the Zig port. They are checked
in so the algorithm can be cross-referenced line-by-line during the port,
and so the C++ upstream can be built locally for golden-frame generation.

## `avisynth/`

Original Avisynth `IT_YV12 v0.1.03` plugin source. Useful as historical
reference — shows the pre-VapourSynth state of the algorithm (still
contains MMX inline asm in `di.cpp`). Not built by us.

- License: GPL-2.0-or-later
- Authors: thejam79 (IT 0.051, 2002), minamina (YV12 mod, 2003)

## `vapoursynth-cpp/`

Upstream VapourSynth-IT C++ port at commit `6fc9be8`. This is the **bit-exact
reference** for the Zig port — specifically the `__C` build path
(`./configure --c && make`). The script `scripts/make_reference.sh` (Phase 3)
will build this and emit per-frame md5 hashes that the Zig port must match.

- License: GPL-2.0-or-later
- Author: msg7086 (2014)
- Upstream: <https://github.com/HomeOfVapourSynthEvolution/VapourSynth-IT>

Do **not** modify files in this directory. If a divergence from upstream
behaviour is needed, document it in `PLAN.md` and the Zig source, not by
patching the reference.

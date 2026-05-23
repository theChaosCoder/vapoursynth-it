"""Synthetic test clip fixtures used by the integration tests.

Each fixture has known structure (e.g. a 3:2 pulldown of two distinct film
frames) so that the IT filter's behaviour can be reasoned about — not just
hashed.

All clips are YUV420P8 with dimensions that satisfy IT's constraints
(width mod 16 == 0, height even).
"""

from __future__ import annotations

import vapoursynth as vs

core = vs.core


def _solid(width: int, height: int, length: int, fpsnum: int, fpsden: int, color):
    return core.std.BlankClip(
        format=vs.YUV420P8,
        width=width,
        height=height,
        length=length,
        fpsnum=fpsnum,
        fpsden=fpsden,
        color=color,
    )


def constant_color(width: int = 128, height: int = 96, length: int = 30):
    """A flat color — IT should output unchanged frames (the simplest case)."""
    return _solid(width, height, length, 30000, 1001, [128, 128, 128])


def two_frame_telecine(width: int = 128, height: int = 96, num_film_frames: int = 8):
    """Synthetic 3:2 pulldown of two distinct 'film' frames.

    Source:  F0  F1  F0  F1  F0  F1  F0  F1  ...  (24p)
    Pulldown produces 10 fields per 4 source frames:
        F0t F0b | F0t F1b | F1t F1b | F1t F0b | F0t F0b ...   (the AA BB BC CD DD pattern)

    We approximate this by interleaving fields from two distinct flat-colour
    frames. After running IT(fps=24), the output should contain 4*N/5 frames
    where the per-frame content reflects whichever of the two film frames the
    matcher picked. We don't assert per-pixel here — that's the golden test.
    """
    # Two "film" frames as flat colours that differ heavily in luma so motion
    # is unambiguous.
    fa = _solid(width, height, 1, 30000, 1001, [40, 128, 128])
    fb = _solid(width, height, 1, 30000, 1001, [200, 128, 128])

    # Build a 3:2 pulldown approximation: alternate top/bottom fields from
    # fa/fb according to the pattern. For simplicity, the synthesised clip
    # just repeats fa five times then fb five times — this is enough to
    # exercise the decimation logic even if it isn't a strict 3:2 cadence.
    one_cycle = core.std.Splice([fa] * 5 + [fb] * 5)
    num_cycles = max(1, num_film_frames // 4)
    return core.std.Loop(one_cycle, times=num_cycles)


def interlaced_stripes(width: int = 128, height: int = 96, length: int = 20):
    """Even rows dark, odd rows bright — classic interlace-mismatch pattern.

    IT should flag this as interlaced (ip='I') and engage the deinterlacer.
    """
    bright = _solid(width, height, length, 30000, 1001, [220, 128, 128])
    dark = _solid(width, height, length, 30000, 1001, [20, 128, 128])
    sep_bright = core.std.SeparateFields(bright, tff=True)
    sep_dark = core.std.SeparateFields(dark, tff=True)
    # Even fields from bright, odd fields from dark -> stripes
    fields = core.std.Interleave([sep_bright[::2], sep_dark[1::2]])
    return core.std.DoubleWeave(fields, tff=True)[::2]


# Public fixture catalogue used by tests / scripts.
FIXTURES = {
    "constant_color":     lambda: constant_color(128, 96, 30),
    "constant_large":     lambda: constant_color(720, 480, 30),
    "constant_mod16":     lambda: constant_color(176, 96, 20),
    "two_frame_telecine": lambda: two_frame_telecine(128, 96, num_film_frames=8),
    "interlaced_stripes": lambda: interlaced_stripes(128, 96, 20),
}


if __name__ == "__main__":
    print("available fixtures:")
    for name, factory in FIXTURES.items():
        clip = factory()
        print(f"  {name:<22} {clip.width}x{clip.height} length={clip.num_frames} "
              f"fps={clip.fps_num}/{clip.fps_den}")

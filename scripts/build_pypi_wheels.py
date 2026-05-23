#!/usr/bin/env python3
"""Assemble platform-tagged wheels from the `zig build cross` output.

VapourSynth-zit ships as five binary wheels — one per `(os, arch)`
combination Zig produces — plus a thin source distribution. The wheels
are *not* built by an upstream Python toolchain (hatchling /
meson-python / cibuildwheel) because the actual compile is done by
`zig build`. Instead this script takes the already-built binaries in
`zig-out/<plat>/`, packages each into a PEP 427 wheel by hand, and
drops the result under `dist/`.

Layout inside each wheel::

    vapoursynth_zit-<ver>.dist-info/
        METADATA      (Python project metadata)
        WHEEL         (wheel format declaration)
        RECORD        (sha256 + size of every file)
        licenses/LICENSE
    vapoursynth/plugins/
        libzit.so  (Linux)
      | libzit.dylib  (macOS)
      | zit.dll  (Windows)

That last directory is the convention VapourSynth's Python bindings
use to auto-discover pip-installed plugins. Once `pip install
vapoursynth-zit` finishes, `import vapoursynth as vs; vs.core.zit.IT`
Just Works.

Pre-conditions:
  * `zig build cross` has been run — `zig-out/{linux,macos,windows}-*/`
    contain the respective binaries.

Usage:
  python scripts/build_pypi_wheels.py
"""

from __future__ import annotations

import base64
import hashlib
import io
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZIG_OUT = ROOT / "zig-out"
DIST = ROOT / "dist"

PROJECT_NAME = "vapoursynth-zit"
DIST_NAME = "vapoursynth_zit"   # PEP 503-normalised + underscore for filenames
VERSION = "1.3.0"

# (Zig target dir, binary filename, wheel platform tag).
#
# The wheel platform tags follow PEP 425. Zig cross-compiles against
# GNU libc; the broadest compatible manylinux tag for that ABI is
# `manylinux2014`. macOS we conservatively tag for `10.9+` (intel) /
# `11.0+` (arm64) because Zig's defaults already target those.
PLATFORMS = [
    ("linux-x86_64",   "libzit.so",     "manylinux2014_x86_64.manylinux_2_17_x86_64"),
    ("linux-aarch64",  "libzit.so",     "manylinux2014_aarch64.manylinux_2_17_aarch64"),
    ("macos-x86_64",   "libzit.dylib",  "macosx_10_9_x86_64"),
    ("macos-aarch64",  "libzit.dylib",  "macosx_11_0_arm64"),
    ("windows-x86_64", "zit.dll",       "win_amd64"),
]


def _read(p: Path) -> bytes:
    return p.read_bytes()


def _sha256_b64(data: bytes) -> str:
    """PEP 376 RECORD format: `sha256=<urlsafe base64, no padding>`."""
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def _metadata() -> str:
    """Generate METADATA per PEP 621 / core metadata 2.4. We embed only
    what's strictly required + a short description from README.md."""
    readme_excerpt = (ROOT / "README.md").read_text(encoding="utf-8")
    return (
        "Metadata-Version: 2.4\n"
        f"Name: {PROJECT_NAME}\n"
        f"Version: {VERSION}\n"
        "Summary: Inverse-telecine plugin for VapourSynth — Zig port of IT, "
        "with the original Avisynth parameters restored\n"
        "Home-page: https://github.com/theChaosCoder/vapoursynth-it\n"
        "Author: theChaosCoder\n"
        "License-Expression: GPL-2.0-or-later\n"
        "License-File: LICENSE\n"
        "Project-URL: Repository, https://github.com/theChaosCoder/vapoursynth-it\n"
        "Project-URL: Issues, https://github.com/theChaosCoder/vapoursynth-it/issues\n"
        "Project-URL: Changelog, https://github.com/theChaosCoder/vapoursynth-it/blob/main/CHANGELOG.md\n"
        "Keywords: video,vapoursynth,ivtc,inverse-telecine,deinterlace,telecine,pulldown\n"
        "Classifier: Development Status :: 5 - Production/Stable\n"
        "Classifier: Environment :: Plugins\n"
        "Classifier: Operating System :: MacOS\n"
        "Classifier: Operating System :: Microsoft :: Windows\n"
        "Classifier: Operating System :: POSIX :: Linux\n"
        "Classifier: Topic :: Multimedia :: Video\n"
        "Classifier: Topic :: Multimedia :: Video :: Conversion\n"
        "Requires-Python: >=3.9\n"
        "Requires-Dist: VapourSynth>=55\n"
        "Description-Content-Type: text/markdown\n"
        "\n"
        f"{readme_excerpt}"
    )


def _wheel_file(plat_tag: str) -> str:
    return (
        "Wheel-Version: 1.0\n"
        "Generator: zit/build_pypi_wheels.py\n"
        "Root-Is-Purelib: false\n"
        f"Tag: py3-none-{plat_tag.split('.')[0]}\n"
    )


def build_wheel(zig_dir: str, binname: str, plat_tag: str) -> Path:
    src = ZIG_OUT / zig_dir / binname
    if not src.exists():
        raise SystemExit(
            f"missing artefact: {src}\n  run `zig build cross` first."
        )
    DIST.mkdir(exist_ok=True)

    # The primary platform tag we use in the filename / Tag: header is
    # the manylinux/macosx/win short form. We attach the full alias list
    # only in the WHEEL `Tag:` line (PEP 427 allows multiple).
    primary = plat_tag.split(".")[0]
    wheel_filename = f"{DIST_NAME}-{VERSION}-py3-none-{primary}.whl"
    out = DIST / wheel_filename

    bin_data = _read(src)
    license_data = _read(ROOT / "LICENSE")
    metadata = _metadata().encode("utf-8")
    wheel = _wheel_file(plat_tag).encode("utf-8")

    distinfo = f"{DIST_NAME}-{VERSION}.dist-info"
    plugin_path = f"{DIST_NAME}-{VERSION}.data/data/vapoursynth/plugins/{binname}"

    entries = [
        (plugin_path, bin_data),
        (f"{distinfo}/METADATA", metadata),
        (f"{distinfo}/WHEEL", wheel),
        (f"{distinfo}/licenses/LICENSE", license_data),
    ]

    # Build RECORD last — it indexes everything else.
    record_lines = []
    for name, data in entries:
        record_lines.append(f"{name},{_sha256_b64(data)},{len(data)}")
    record_lines.append(f"{distinfo}/RECORD,,")
    record = "\n".join(record_lines).encode("utf-8") + b"\n"
    entries.append((f"{distinfo}/RECORD", record))

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries:
            zf.writestr(name, data)

    print(f"  built {out.name}  ({out.stat().st_size:>8d} bytes)")
    return out


def main() -> int:
    print(f"Building {PROJECT_NAME} {VERSION} wheels from {ZIG_OUT}/")
    if not ZIG_OUT.exists():
        raise SystemExit("zig-out/ missing — run `zig build cross` first.")
    for zig_dir, binname, plat_tag in PLATFORMS:
        build_wheel(zig_dir, binname, plat_tag)
    print(f"\n{len(PLATFORMS)} wheels in {DIST.relative_to(ROOT)}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

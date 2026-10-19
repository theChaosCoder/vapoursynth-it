"""Checks against the actual `zig build cross` artifacts; stdlib only."""

import ctypes as ct
import platform
import re
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from build_pypi_wheels import PLATFORMS, validate_binary  # noqa: E402


class BinaryCompatibilityTests(unittest.TestCase):
    def test_shipped_binaries_fit_their_wheel_tags(self):
        for directory, filename, tag in PLATFORMS:
            with self.subTest(platform=directory):
                validate_binary((ROOT / "zig-out" / directory / filename).read_bytes(), tag)

    def test_rejects_newer_glibc_symbols(self):
        for arch in ("x86_64", "aarch64"):
            with self.subTest(arch=arch):
                data = (ROOT / f"zig-out/linux-{arch}/libzit.so").read_bytes()
                # Bump whatever the binary requires most, in place: which
                # versions Zig links against varies with its release and arch.
                versions = re.findall(rb"GLIBC_\d+(?:\.\d+)+(?=\0)", data)
                self.assertTrue(versions, "no GLIBC_* symbol versions found")
                highest = max(versions, key=lambda v: tuple(map(int, v[6:].split(b"."))))
                newer = data.replace(highest + b"\0", re.sub(rb"\d", b"9", highest) + b"\0")
                with self.assertRaisesRegex(ValueError, "newer than wheel tag"):
                    validate_binary(newer, f"manylinux2014_{arch}")
                with self.assertRaisesRegex(ValueError, "newer than wheel tag"):
                    validate_binary(newer, f"manylinux_2_17_{arch}")

    def test_rejects_newer_macos_deployment_version(self):
        for directory, filename, tag in PLATFORMS:
            if not directory.startswith("macos-"):
                continue
            with self.subTest(platform=directory):
                data = bytearray((ROOT / "zig-out" / directory / filename).read_bytes())
                offset = 32
                changed = False
                for _ in range(struct.unpack_from("<I", data, 16)[0]):
                    cmd, size = struct.unpack_from("<II", data, offset)
                    if cmd in (0x24, 0x32):
                        struct.pack_into("<I", data, offset + (8 if cmd == 0x24 else 12), 15 << 16)
                        changed = True
                    offset += size
                self.assertTrue(changed)
                with self.assertRaisesRegex(ValueError, "newer than wheel tag"):
                    validate_binary(data, tag)

    @unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64",
                         "registration probe loads the Linux x86_64 release binary")
    def test_release_plugin_registers_with_api_4_0(self):
        get_api_type = ct.CFUNCTYPE(ct.c_int)
        config_type = ct.CFUNCTYPE(ct.c_int, ct.c_char_p, ct.c_char_p, ct.c_char_p,
                                  ct.c_int, ct.c_int, ct.c_int, ct.c_void_p)
        register_type = ct.CFUNCTYPE(ct.c_int, ct.c_char_p, ct.c_char_p, ct.c_char_p,
                                    ct.c_void_p, ct.c_void_p, ct.c_void_p)
        requested_versions = []
        registered_functions = []

        @get_api_type
        def get_api():
            return 4 << 16

        @config_type
        def config(identifier, namespace, name, version, api, flags, plugin):
            requested_versions.append(api)
            return int(api == 4 << 16)

        @register_type
        def register(name, *args):
            registered_functions.append(name)
            return 1

        class PluginAPI(ct.Structure):
            _fields_ = [("getAPIVersion", get_api_type), ("configPlugin", config_type),
                        ("registerFunction", register_type)]

        api = PluginAPI(get_api, config, register)
        plugin = ct.c_byte()
        lib = ct.CDLL(str(ROOT / "zig-out/linux-x86_64/libzit.so"))
        lib.VapourSynthPluginInit2.argtypes = [ct.c_void_p, ct.POINTER(PluginAPI)]
        lib.VapourSynthPluginInit2.restype = None
        lib.VapourSynthPluginInit2(ct.byref(plugin), ct.byref(api))
        self.assertEqual(requested_versions, [4 << 16])
        self.assertEqual(registered_functions, [b"IT"])


if __name__ == "__main__":
    unittest.main()

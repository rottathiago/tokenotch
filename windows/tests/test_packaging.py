import pathlib
import hashlib
import json
import runpy
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
pe = runpy.run_path(str(ROOT / "windows/scripts/verify-pe.py"))
artifacts = runpy.run_path(str(ROOT / "windows/scripts/stage-artifacts.py"))


class PayloadChecks(unittest.TestCase):
    @staticmethod
    def import_fixture(name, delayed=False):
        data = bytearray(0x600)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 0x80)
        data[0x80:0x84] = b"PE\0\0"
        struct.pack_into("<HH", data, 0x84, 0x8664, 1)
        struct.pack_into("<H", data, 0x94, 240)
        optional = 0x98
        struct.pack_into("<H", data, optional, 0x20B)
        struct.pack_into("<I", data, optional + 108, 16)
        directory = 13 if delayed else 1
        struct.pack_into("<II", data, optional + 112 + directory * 8, 0x1000, 64 if delayed else 40)
        section = optional + 240
        struct.pack_into("<III", data, section + 12, 0x1000, 0x400, 0x200)
        if delayed:
            struct.pack_into("<II", data, 0x200, 1, 0x1080)
        else:
            struct.pack_into("<I", data, 0x20C, 0x1080)
        encoded = name.encode("ascii") + b"\0"
        data[0x280:0x280 + len(encoded)] = encoded
        return data

    def test_static_runtime_gate_checks_normal_and_delayed_imports(self):
        for delayed in [False, True]:
            with tempfile.TemporaryDirectory(prefix="tokenotch-imports-") as temporary:
                path = pathlib.Path(temporary) / "Tokenotch.exe"
                path.write_bytes(self.import_fixture("KERNEL32.dll", delayed))
                self.assertEqual(pe["runtime_imports"](path), {"kernel32.dll"})
                pe["verify_static_runtime"](path)
                for name in ["VCRUNTIME140.dll", "VCRUNTIME140_1.dll", "MSVCP140.dll"]:
                    path.write_bytes(self.import_fixture(name, delayed))
                    with self.assertRaisesRegex(ValueError, "external Visual C"):
                        pe["verify_static_runtime"](path)
                path.write_bytes(self.import_fixture("../outside.dll", delayed))
                with self.assertRaises(ValueError):
                    pe["runtime_imports"](path)

    def test_architecture_is_read_from_payload_not_filename(self):
        for architecture, machine in pe["MACHINES"].items():
            data = bytearray(152)
            data[:2] = b"MZ"
            struct.pack_into("<I", data, 60, 128)
            data[128:132] = b"PE\0\0"
            struct.pack_into("<H", data, 132, machine)
            with tempfile.TemporaryDirectory(prefix="tokenotch-pe-") as temporary:
                path = pathlib.Path(temporary) / "Tokenotch.exe"
                path.write_bytes(data)
                pe["verify"](path, architecture)
                other = "arm64" if architecture == "x64" else "x64"
                with self.assertRaises(ValueError):
                    pe["verify"](path, other)

    def test_truncated_non_pe_and_unbounded_offsets_are_rejected(self):
        for data in [b"", b"MZ", b"not an executable" * 10, b"MZ" + b"\xff" * 62]:
            with tempfile.TemporaryDirectory(prefix="tokenotch-pe-") as temporary:
                path = pathlib.Path(temporary) / "Tokenotch.exe"
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    pe["verify"](path, "x64")

    def test_artifact_names_and_checksums_preserve_architecture(self):
        with tempfile.TemporaryDirectory(prefix="tokenotch-artifacts-") as temporary:
            root = pathlib.Path(temporary)
            (root / "config").mkdir()
            (root / "config/Release.json").write_text(json.dumps({"version": "1.2.3"}))
            (root / "windows/config").mkdir(parents=True)
            (root / "windows/config/release.json").write_text(json.dumps({"channel": "development"}))
            with patch.dict(artifacts["stage"].__globals__, ROOT=root):
                for architecture, target in artifacts["TARGETS"].items():
                    source = root / "windows/target" / target / "release/bundle/nsis"
                    source.mkdir(parents=True)
                    payload = f"synthetic {architecture} installer".encode()
                    (source / "Tokenotch-setup.exe").write_bytes(payload)
                    output = artifacts["stage"](architecture)
                    self.assertEqual(output.name, f"Tokenotch-1.2.3-windows-{architecture}-development-setup.exe")
                    self.assertEqual(output.read_bytes(), payload)
                    self.assertEqual(output.with_suffix(".exe.sha256").read_text(),
                                     f"{hashlib.sha256(payload).hexdigest()}  {output.name}\n")
                    (source / "stale-setup.exe").write_bytes(b"stale")
                    with self.assertRaises(ValueError):
                        artifacts["stage"](architecture)

    def test_installer_hook_uses_native_include_directory(self):
        hook = (ROOT / "windows/config/installer-hooks.nsh").read_text()
        self.assertIn('!addincludedir "${__FILEDIR__}"', hook)
        self.assertIn('!include "minimum-build.nsh"', hook)
        self.assertNotIn('${__FILEDIR__}/minimum-build.nsh', hook)


if __name__ == "__main__":
    unittest.main()

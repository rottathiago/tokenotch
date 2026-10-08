import pathlib
import hashlib
import json
import os
import runpy
import struct
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import Mock, patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
pe = runpy.run_path(str(ROOT / "windows/scripts/verify-pe.py"))
artifacts = runpy.run_path(str(ROOT / "windows/scripts/stage-artifacts.py"))
installer = runpy.run_path(str(ROOT / "windows/scripts/verify-installer.py"))


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
            verify = Mock()
            with patch.dict(artifacts["stage"].__globals__, ROOT=root, verify_installer=verify):
                for channel, suffix in [("development", "-development"), ("release", "")]:
                    (root / "windows/config/release.json").write_text(json.dumps({"channel": channel}))
                    for architecture, target in artifacts["TARGETS"].items():
                        source = root / "windows/target" / target / "release/bundle/nsis"
                        source.mkdir(parents=True, exist_ok=True)
                        payload = f"synthetic {architecture} {channel} installer".encode()
                        built = source / "Tokenotch-setup.exe"
                        built.write_bytes(payload)
                        output = artifacts["stage"](architecture)
                        verify.assert_called_with(built, architecture)
                        self.assertEqual(output.name, f"Tokenotch-1.2.3-windows-{architecture}{suffix}-setup.exe")
                        self.assertEqual(output.read_bytes(), payload)
                        self.assertEqual(output.with_suffix(".exe.sha256").read_text(),
                                         f"{hashlib.sha256(payload).hexdigest()}  {output.name}\n")
                        stale = source / "stale-setup.exe"
                        stale.write_bytes(b"stale")
                        with self.assertRaises(ValueError):
                            artifacts["stage"](architecture)
                        stale.unlink()
                (root / "windows/config/release.json").write_text(json.dumps({"channel": "unknown"}))
                with self.assertRaisesRegex(ValueError, "channel"):
                    artifacts["stage"]("x64")
                (root / "windows/config/release.json").write_text(json.dumps({"channel": "release"}))
                output.unlink()
                output.with_suffix(".exe.sha256").unlink()
                verify.side_effect = ValueError("stale payload")
                with self.assertRaisesRegex(ValueError, "stale payload"):
                    artifacts["stage"]("arm64")
                self.assertFalse(output.exists())
                self.assertFalse(output.with_suffix(".exe.sha256").exists())

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 is required")
    def test_unsigned_packaging_requires_explicit_opt_in(self):
        result = subprocess.run(["pwsh", "-NoProfile", "-File",
                                 str(ROOT / "windows/scripts/package.ps1"), "-Architecture", "x64"],
                                capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Pass -AllowUnsigned", result.stderr)

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 is required")
    def test_build_rejects_smoke_overrides_before_building(self):
        script = (ROOT / "windows/scripts/build.ps1").read_text()
        self.assertLess(script.index("if ($env:TAURI_CONFIG"), script.index("python scripts/release-config.py"))
        if sys.platform != "win32":
            self.skipTest("Native build guard requires Windows")
        architecture = "arm64" if os.environ.get("PROCESSOR_ARCHITECTURE", "").lower() == "arm64" else "x64"
        for variable in ["TAURI_CONFIG", "TOKENOTCH_TEST_HOME"]:
            result = subprocess.run(["pwsh", "-NoProfile", "-File",
                                     str(ROOT / "windows/scripts/build.ps1"), "-Architecture", architecture],
                                    env={**os.environ, variable: "smoke-fixture"},
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Remove smoke overrides explicitly", result.stderr)

    def test_installer_hook_uses_native_include_directory(self):
        hook = (ROOT / "windows/config/installer-hooks.nsh").read_text()
        self.assertIn('!addincludedir "${__FILEDIR__}"', hook)
        self.assertIn('!include "minimum-build.nsh"', hook)
        self.assertNotIn('${__FILEDIR__}/minimum-build.nsh', hook)


class InstallerChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tokenotch-installer-test-")
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / "config").mkdir()
        self.product = {"version": "1.0.0", "companionName": "tokenotch-vscode", "publisher": "rottathiago"}
        (self.root / "config/Release.json").write_text(json.dumps(self.product))
        (self.root / "windows/config").mkdir(parents=True)
        (self.root / "windows/config/release.json").write_text('{"channel":"release"}')
        (self.root / "LICENSE").write_bytes(b"license fixture")
        (self.root / "integrations/VSCode").mkdir(parents=True)
        self.companion = self.root / "integrations/VSCode/TokenotchVSCode.vsix"
        self.write_companion()
        self.patch = patch.dict(installer["verify"].__globals__, ROOT=self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def write_companion(self, package_version="1.0.0", manifest_version="1.0.0"):
        with zipfile.ZipFile(self.companion, "w") as archive:
            archive.writestr("extension/package.json", json.dumps({
                "name": "tokenotch-vscode", "publisher": "rottathiago", "version": package_version}))
            archive.writestr("extension.vsixmanifest",
                             '<PackageManifest xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">'
                             f'<Metadata><Identity Id="tokenotch-vscode" Publisher="rottathiago" Version="{manifest_version}"/>'
                             '</Metadata></PackageManifest>')

    def test_companion_requires_matching_package_and_manifest_identity(self):
        installer["verify_companion"](self.companion)
        for package, manifest in [("0.1.0", "1.0.0"), ("1.0.0", "0.1.0")]:
            self.write_companion(package, manifest)
            with self.assertRaisesRegex(ValueError, "stale companion"):
                installer["verify_companion"](self.companion)
        self.write_companion()
        stale = self.root / "stale.vsix"
        shutil.copy2(self.companion, stale)
        with zipfile.ZipFile(self.companion, "a") as archive:
            archive.writestr("extension/current.js", "current content")
        with self.assertRaisesRegex(ValueError, "current packaged extension"):
            installer["verify_companion"](stale)

    def test_companion_rejects_missing_or_oversized_metadata(self):
        with zipfile.ZipFile(self.companion, "w") as archive:
            archive.writestr("extension/package.json", "{}")
        with self.assertRaisesRegex(ValueError, "missing"):
            installer["verify_companion"](self.companion)
        self.write_companion()
        with zipfile.ZipFile(self.companion, "w") as archive:
            archive.writestr("extension/package.json", " " * 65_537)
        with self.assertRaisesRegex(ValueError, "oversized"):
            installer["verify_companion"](self.companion)

    def test_installer_rejects_missing_resources_and_stale_metadata(self):
        payloads = {name: b"fixture" for name in installer["REQUIRED"]}
        payloads["Tokenotch.exe"] = b"fixture__TAURI_BUNDLE_TYPE_VAR_NSStail"
        binaries = self.root / "windows/target/x86_64-pc-windows-msvc/release"
        binaries.mkdir(parents=True)
        for name in ["Tokenotch.exe", "TokenotchHook.exe"]:
            (binaries / name).write_bytes(payloads[name].replace(b"__TAURI_BUNDLE_TYPE_VAR_NSS", b"__TAURI_BUNDLE_TYPE_VAR_UNK"))
        payloads.update({
            "LICENSE": (self.root / "LICENSE").read_bytes(),
            "Release.json": (self.root / "config/Release.json").read_bytes(),
            "WindowsRelease.json": (self.root / "windows/config/release.json").read_bytes(),
            "TokenotchVSCode.vsix": self.companion.read_bytes(),
        })

        def run(arguments, **kwargs):
            if arguments[1] == "l":
                return subprocess.CompletedProcess(arguments, 0, stdout="\n".join(f"Path = {name}" for name in payloads))
            if arguments[1] == "x":
                kwargs["stdout"].write(payloads[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0)

        with patch("shutil.which", return_value="7z"), patch("subprocess.run", side_effect=run), \
                patch.dict(installer["pe"], verify=Mock(), verify_static_runtime=Mock()):
            installer["verify"](self.root / "setup.exe", "x64")
            for name in ["TokenotchHook.exe", "TokenotchVSCode.vsix", "WindowsRelease.json"]:
                original = payloads.pop(name)
                with self.assertRaisesRegex(ValueError, "missing"):
                    installer["verify"](self.root / "setup.exe", "x64")
                payloads[name] = original
            for name in ["Release.json", "WindowsRelease.json"]:
                original = payloads[name]
                payloads[name] = b"{}"
                with self.assertRaisesRegex(ValueError, f"stale {name}"):
                    installer["verify"](self.root / "setup.exe", "x64")
                payloads[name] = original
            for name in ["Tokenotch.exe", "TokenotchHook.exe"]:
                original = payloads[name]
                payloads[name] = b"stale executable"
                with self.assertRaisesRegex(ValueError, "current release executable"):
                    installer["verify"](self.root / "setup.exe", "x64")
                payloads[name] = original
            payloads["Tokenotch.exe"] = (binaries / "Tokenotch.exe").read_bytes()
            with self.assertRaisesRegex(ValueError, "current release executable"):
                installer["verify"](self.root / "setup.exe", "x64")
            (binaries / "Tokenotch.exe").write_bytes(payloads["Tokenotch.exe"] + b"__TAURI_BUNDLE_TYPE_VAR_UNK")
            with self.assertRaisesRegex(ValueError, "unique Tauri bundle marker"):
                installer["verify"](self.root / "setup.exe", "x64")


if __name__ == "__main__":
    unittest.main()

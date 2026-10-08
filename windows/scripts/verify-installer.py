#!/usr/bin/env python3
"""Inspect an owned installer without executing Windows code."""
import argparse
import json
import pathlib
import runpy
import shutil
import subprocess
import tempfile
import zipfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
TARGETS = {"x64": "x86_64-pc-windows-msvc", "arm64": "aarch64-pc-windows-msvc"}
pe = runpy.run_path(str(ROOT / "windows/scripts/verify-pe.py"))
REQUIRED = {"Tokenotch.exe", "TokenotchHook.exe", "TokenotchVSCode.vsix", "LICENSE",
            "Release.json", "WindowsRelease.json", "uninstall.exe"}


def verify_companion(path):
    config = json.loads((ROOT / "config/Release.json").read_text())
    with zipfile.ZipFile(path) as archive:
        metadata = {}
        for name in ["extension/package.json", "extension.vsixmanifest"]:
            entries = [entry for entry in archive.infolist() if entry.filename == name]
            if len(entries) != 1 or entries[0].file_size > 65_536:
                raise ValueError("Companion metadata is missing, duplicated or oversized")
            metadata[name] = archive.read(entries[0])
    package = json.loads(metadata["extension/package.json"])
    if any(package.get(key) != config[field] for key, field in
           [("name", "companionName"), ("publisher", "publisher"), ("version", "version")]):
        raise ValueError("Installer contains a stale companion package identity")
    manifest = ET.fromstring(metadata["extension.vsixmanifest"])
    identity = manifest.find("{*}Metadata/{*}Identity")
    if identity is None or any(identity.get(key) != config[field] for key, field in
                               [("Id", "companionName"), ("Publisher", "publisher"), ("Version", "version")]):
        raise ValueError("Installer contains a stale companion VSIX identity")
    if path.read_bytes() != (ROOT / "integrations/VSCode/TokenotchVSCode.vsix").read_bytes():
        raise ValueError("Installer companion differs from the current packaged extension")


def verify(installer, architecture):
    archiver = shutil.which("7zz") or shutil.which("7z")
    if not archiver:
        raise ValueError("7-Zip is required for installer inspection; install sevenzip or provide 7zz/7z on PATH")
    listing = subprocess.run([archiver, "l", "-slt", str(installer)], check=True,
                             capture_output=True, text=True).stdout
    entries = {line.removeprefix("Path = ") for line in listing.splitlines() if line.startswith("Path = ")}
    if not REQUIRED.issubset(entries):
        raise ValueError("Installer is missing a required executable, companion, license, metadata file or uninstaller")
    subprocess.run([archiver, "t", "-bso0", str(installer)], check=True)
    with tempfile.TemporaryDirectory(prefix="tokenotch-installer-inspect-") as temporary:
        root = pathlib.Path(temporary)
        for name in REQUIRED - {"uninstall.exe"}:
            output = root / name
            with output.open("wb") as stream:
                subprocess.run([archiver, "x", "-so", str(installer), name],
                               check=True, stdout=stream, stderr=subprocess.PIPE)
            if name.endswith(".exe"):
                pe["verify"](output, architecture)
                pe["verify_static_runtime"](output)
                built = ROOT / "windows/target" / TARGETS[architecture] / "release" / name
                expected = built.read_bytes()
                if name == "Tokenotch.exe":
                    # Tauri patches this marker for NSIS, then restores the original build output.
                    marker = b"__TAURI_BUNDLE_TYPE_VAR_UNK"
                    if expected.count(marker) != 1:
                        raise ValueError("Release executable has no unique Tauri bundle marker")
                    expected = expected.replace(marker, b"__TAURI_BUNDLE_TYPE_VAR_NSS", 1)
                if output.read_bytes() != expected:
                    raise ValueError(f"Installer {name} differs from the current release executable")
            elif name == "LICENSE":
                if output.read_bytes() != (ROOT / "LICENSE").read_bytes():
                    raise ValueError("Installer license differs from the repository notice")
            elif name == "TokenotchVSCode.vsix":
                verify_companion(output)
            else:
                if output.stat().st_size > 65_536:
                    raise ValueError("Installer metadata is oversized")
                expected = ROOT / ("config/Release.json" if name == "Release.json" else "windows/config/release.json")
                if json.loads(output.read_text()) != json.loads(expected.read_text()):
                    raise ValueError(f"Installer contains stale {name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--architecture", required=True, choices=["x64", "arm64"])
    parser.add_argument("installer", type=pathlib.Path)
    args = parser.parse_args()
    verify(args.installer.resolve(strict=True), args.architecture)
    print(f"Verified embedded {args.architecture} payloads, metadata, license and archive integrity; no Windows code was executed.")

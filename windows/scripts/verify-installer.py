#!/usr/bin/env python3
"""Inspect an owned development installer without executing Windows code."""
import argparse
import json
import pathlib
import runpy
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
pe = runpy.run_path(str(ROOT / "windows/scripts/verify-pe.py"))
REQUIRED = {"Tokenotch.exe", "TokenotchHook.exe", "LICENSE", "Release.json", "WindowsRelease.json", "uninstall.exe"}


def verify(installer, architecture):
    archiver = shutil.which("7zz") or shutil.which("7z")
    if not archiver:
        raise ValueError("7-Zip is required for installer inspection; install sevenzip or provide 7zz/7z on PATH")
    listing = subprocess.run([archiver, "l", "-slt", str(installer)], check=True,
                             capture_output=True, text=True).stdout
    entries = {line.removeprefix("Path = ") for line in listing.splitlines() if line.startswith("Path = ")}
    if not REQUIRED.issubset(entries):
        raise ValueError("Installer is missing a required executable, license, metadata file or uninstaller")
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
            elif name == "LICENSE":
                if output.read_bytes() != (ROOT / "LICENSE").read_bytes():
                    raise ValueError("Installer license differs from the repository notice")
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

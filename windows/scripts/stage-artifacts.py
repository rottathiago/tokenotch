#!/usr/bin/env python3
"""Name and checksum development installers without signing or publishing them."""
import argparse
import hashlib
import json
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[2]
TARGETS = {"x64": "x86_64-pc-windows-msvc", "arm64": "aarch64-pc-windows-msvc"}


def stage(architecture):
    config = json.loads((ROOT / "config/Release.json").read_text())
    windows = json.loads((ROOT / "windows/config/release.json").read_text())
    if windows["channel"] != "development":
        raise ValueError("Only development artifacts can be staged")
    source = ROOT / "windows/target" / TARGETS[architecture] / "release/bundle/nsis"
    installers = list(source.glob("*-setup.exe"))
    if len(installers) != 1 or not installers[0].is_file() or installers[0].is_symlink():
        raise ValueError("Expected exactly one regular development installer; inspect stale output")
    output = ROOT / "build/windows" / architecture
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f"Tokenotch-{config['version']}-windows-{architecture}-development-setup.exe"
    checksum = destination.with_suffix(".exe.sha256")
    if destination.is_symlink() or checksum.is_symlink():
        raise ValueError("Artifact output must not follow a symlink")
    shutil.copy2(installers[0], destination)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    checksum.write_text(f"{digest}  {destination.name}\n", encoding="ascii")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--architecture", required=True, choices=sorted(TARGETS))
    args = parser.parse_args()
    print(f"Unsigned development installer: {stage(args.architecture)}")

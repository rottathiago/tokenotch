#!/usr/bin/env python3
"""Stage owned resources without platform-specific image tools."""
import argparse
import pathlib
import shutil
import struct

ROOT = pathlib.Path(__file__).resolve().parents[2]
TARGETS = {"x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc", "aarch64-apple-darwin", "x86_64-apple-darwin"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True, choices=sorted(TARGETS))
    parser.add_argument("--helper", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if not args.helper.is_file() or args.helper.is_symlink():
        raise ValueError("A built regular helper executable is required")
    output = ROOT / "windows/desktop/src-tauri/binaries"
    if output.is_symlink():
        raise ValueError("Resource staging directory must not be a symlink")
    output.mkdir(parents=True, exist_ok=True)
    image = (ROOT / "integrations/VSCode/icon.png").read_bytes()
    if image[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", image[16:24]) != (128, 128):
        raise ValueError("Expected the approved 128-pixel companion icon")
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", 128, 128, 0, 0, 1, 32, len(image), 22)
    (output / "Tokenotch.ico").write_bytes(header + entry + image)
    (output / "Tokenotch.png").write_bytes(image)
    suffix = ".exe" if "windows" in args.target else ""
    shutil.copy2(args.helper, output / f"TokenotchHook-{args.target}{suffix}")
    print(f"Staged Tokenotch resources for {args.target}.")


if __name__ == "__main__":
    main()

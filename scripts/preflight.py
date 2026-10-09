#!/usr/bin/env python3
"""Check native build/install prerequisites without installing or changing tools."""
import argparse
import json
import pathlib
import platform
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLCHAIN_HELP = (
    "Install matching Xcode Command Line Tools with xcode-select --install, or select "
    "full Xcode with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer. "
    "Clear incompatible SDKROOT/TOOLCHAINS overrides."
)
NODE_HELP = "Install Node.js 22.12+ with its bundled npm; repair the installation if either command fails."
PYTHON_HELP = "Install Python 3.9+ and make python3 available on PATH."


def query(command, help_text, errors, source=None):
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True,
                                input=source, timeout=60 if source is not None else 15)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        errors.append(f"{' '.join(command)} failed: {detail or str(error)} {help_text}")
        return None
    if source is None and not result.stdout.strip():
        errors.append(f"{' '.join(command)} returned no tool information. {help_text}")
        return None
    return result.stdout.strip()


def require_version(text, pattern, minimum, label, help_text, errors):
    if text is None:
        return
    match = re.search(pattern, text)
    if not match:
        errors.append(f"Cannot determine {label} version from {text!r}. {help_text}")
        return
    found = tuple(int(part or 0) for part in match.groups())
    if found < minimum:
        required = ".".join(str(part) for part in minimum)
        errors.append(f"{label} {required}+ is required; found {text}. {help_text}")


def check(package=False, skip_build=False, installer_format="all"):
    if sys.version_info < (3, 9):
        raise ValueError(f"Python 3.9+ is required; found {platform.python_version()}. {PYTHON_HELP}")
    if platform.system() != "Darwin":
        raise ValueError("Native Tokenotch builds/installers require macOS. See windows/README.md for Windows.")
    config = json.loads((ROOT / "config/Release.json").read_text())
    minimum_os = tuple(int(part) for part in (config["minimumOS"] + ".0.0").split(".")[:3])
    host = platform.mac_ver()[0]
    errors = []
    require_version(host, r"^(\d+)\.(\d+)(?:\.(\d+))?$", minimum_os, "macOS",
                    "Use a Mac running the supported macOS version or later.", errors)
    if errors:
        raise ValueError("\n".join(errors))
    tools = {"xcrun": TOOLCHAIN_HELP, "codesign": TOOLCHAIN_HELP}
    if not skip_build:
        tools.update({"git": TOOLCHAIN_HELP, "make": TOOLCHAIN_HELP,
                      "node": NODE_HELP, "npm": NODE_HELP})
    if package:
        tools["ditto"] = "Use the macOS system ditto utility."
        if installer_format in ["all", "dmg"]:
            tools["hdiutil"] = "Use the macOS system hdiutil utility to build and verify DMGs."
        if installer_format in ["all", "pkg"]:
            for tool in ["pkgbuild", "productbuild", "pkgutil"]:
                tools[tool] = TOOLCHAIN_HELP
    available = set()
    for tool, help_text in tools.items():
        if shutil.which(tool):
            available.add(tool)
        else:
            errors.append(f"Missing required tool: {tool}. {help_text}")
    report = [f"macOS: {host}", f"Python: {platform.python_version()}"]
    if "xcrun" in available:
        lipo = query(["xcrun", "--find", "lipo"], TOOLCHAIN_HELP, errors)
        if lipo:
            report.append(f"Selected lipo: {lipo}")
        if not skip_build:
            swiftc = query(["xcrun", "--find", "swiftc"], TOOLCHAIN_HELP, errors)
            swift = query(["xcrun", "swiftc", "--version"], TOOLCHAIN_HELP, errors)
            sdk = query(["xcrun", "--show-sdk-path"], TOOLCHAIN_HELP, errors)
            sdk_version = query(["xcrun", "--show-sdk-version"], TOOLCHAIN_HELP, errors)
            require_version(swift, r"Swift version (\d+)\.(\d+)(?:\.(\d+))?", (6, 0, 0),
                            "Swift", TOOLCHAIN_HELP, errors)
            require_version(sdk_version, r"^(\d+)\.(\d+)(?:\.(\d+))?$", minimum_os,
                            "macOS SDK", TOOLCHAIN_HELP, errors)
            if sdk and not pathlib.Path(sdk).name.startswith("MacOSX"):
                errors.append(f"A macOS SDK is required; selected {sdk}. {TOOLCHAIN_HELP}")
            if swiftc and swift:
                report.extend([f"Selected Swift compiler: {swiftc}", swift.splitlines()[0]])
            if sdk and sdk_version:
                report.append(f"macOS SDK: {sdk_version} ({sdk})")
            if not errors:
                query(["xcrun", "swiftc", "-swift-version", "5", "-typecheck", "-target",
                       f"{platform.machine()}-apple-macosx{config['minimumOS']}", "-"],
                      TOOLCHAIN_HELP, errors, source="import AppKit\nimport SwiftUI\nimport SQLite3\n")
                if not errors:
                    report.append("macOS SDK framework imports: verified")
    if "node" in available:
        node = query(["node", "--version"], NODE_HELP, errors)
        require_version(node, r"^v(\d+)\.(\d+)\.(\d+)$", (22, 12, 0), "Node.js", NODE_HELP, errors)
        if node:
            report.append(f"Node.js: {node}")
    if "npm" in available:
        npm = query(["npm", "--version"], NODE_HELP, errors)
        require_version(npm, r"^(\d+)\.(\d+)\.(\d+)$", (0, 0, 0), "npm", NODE_HELP, errors)
        if npm:
            report.append(f"npm: {npm}")
    if errors:
        raise ValueError("\n".join(errors))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", action="store_true", help="also check installer utilities")
    parser.add_argument("--skip-build", action="store_true",
                        help="check only tools needed to package an existing universal app")
    parser.add_argument("--format", choices=["all", "dmg", "pkg"], default="all")
    args = parser.parse_args()
    if args.skip_build and not args.package:
        parser.error("--skip-build requires --package")
    report = check(args.package, args.skip_build, args.format)
    print("\n".join(report))
    print("Native prerequisites passed. No tools were installed or settings changed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"Preflight failed:\n{error}\nSee docs/getting-started.md#build-from-source.", file=sys.stderr)
        sys.exit(1)

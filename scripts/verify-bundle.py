#!/usr/bin/env python3
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1])
config = json.loads((root / "config/Release.json").read_text())
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
if info.get("TokenotchDistributionChannel") not in ["development", "release"]:
    raise SystemExit("Bundle distribution channel is missing")
if "--release" in sys.argv and info["TokenotchDistributionChannel"] != "release":
    raise SystemExit("Development bundle cannot be distributed as a release")
for key, field in {
    "CFBundleIdentifier": "bundleID", "CFBundleShortVersionString": "version",
    "CFBundleVersion": "build", "LSMinimumSystemVersion": "minimumOS",
    "CFBundleName": "name", "CFBundleDisplayName": "name", "CFBundleExecutable": "name",
}.items():
    if info.get(key) != config[field]:
        raise SystemExit(f"Bundle metadata mismatch: {key}")
for path in ["MacOS/Tokenotch", "Helpers/TokenotchHook", "Resources/CopilotUsage/extension.mjs",
             "Resources/TokenotchVSCode.vsix", "Resources/Tokenotch.icns", "Resources/LICENSE",
             "Resources/Release.json",
             "Resources/TokenotchMenuBar.png", "Resources/TokenotchMark.png", "Resources/TokenotchMarkDark.png"]:
    if not (app / "Contents" / path).is_file():
        raise SystemExit(f"Missing bundle resource: {path}")
if (app / "Contents/Resources/LICENSE").read_bytes() != (root / "LICENSE").read_bytes():
    raise SystemExit("Bundled attribution mismatch")
if json.loads((app / "Contents/Resources/Release.json").read_text()) != config:
    raise SystemExit("Bundled release identity is stale")
with zipfile.ZipFile(app / "Contents/Resources/TokenotchVSCode.vsix") as vsix:
    package = json.loads(vsix.read("extension/package.json"))
    for key in ["version", "publisher"]:
        if package[key] != config[key]:
            raise SystemExit(f"Bundled companion {key} is stale")
    if package["name"] != config["companionName"]:
        raise SystemExit("Bundled companion name is stale")
    if vsix.read("extension/src/product.cjs") != (root / "integrations/VSCode/src/product.cjs").read_bytes():
        raise SystemExit("Bundled companion identity is stale")
    if package["license"] != "MIT" or "extension/LICENSE.txt" not in vsix.namelist():
        raise SystemExit("Companion license missing")
    if vsix.read("extension/LICENSE.txt") != (root / "LICENSE").read_bytes():
        raise SystemExit("Companion attribution mismatch")
    if vsix.read("extension/icon.png") != (root / "integrations/VSCode/icon.png").read_bytes():
        raise SystemExit("Companion logo is stale")
    if any("/node_modules/" in name or "/test/" in name for name in vsix.namelist()):
        raise SystemExit("Development files found in companion")
manifest_path = root / "sources/Resources/Brand/TokenotchBrandManifest.json"
manifest = json.loads(manifest_path.read_text())
if (app / "Contents/Resources/TokenotchBrandManifest.json").read_bytes() != manifest_path.read_bytes():
    raise SystemExit("Bundled logo provenance is stale")
if hashlib.sha256((root / manifest["source"]).read_bytes()).hexdigest() != manifest["sourceSHA256"]:
    raise SystemExit("The source logo changed after asset generation")
if hashlib.sha256((root / manifest["appIconSource"]).read_bytes()).hexdigest() != manifest["appIconSourceSHA256"]:
    raise SystemExit("The app icon source changed after asset generation")
for path, digest in manifest["assets"].items():
    if path.startswith("sources/Resources/Brand/"):
        bundled = app / "Contents/Resources" / pathlib.Path(path).name
        if hashlib.sha256(bundled.read_bytes()).hexdigest() != digest:
            raise SystemExit(f"Bundled logo asset is stale: {bundled.name}")
if "--universal" in sys.argv:
    for binary in ["MacOS/Tokenotch", "Helpers/TokenotchHook"]:
        subprocess.run(["lipo", str(app / "Contents" / binary),
                        "-verify_arch", "arm64", "x86_64"], check=True)
print("Bundle identity, resources, and companion verified.")

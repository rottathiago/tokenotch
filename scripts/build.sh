#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/release-config.py
python3 scripts/make-brand-assets.py --check
if [[ "${1:-}" == "--universal" && $# -eq 1 ]]; then
  ARCHITECTURES=(arm64 x86_64)
elif [[ $# -eq 0 ]]; then
  ARCHITECTURES=("$(uname -m)")
else
  echo "Usage: bash scripts/build.sh [--universal]" >&2
  exit 1
fi
make vscode-companion
MIN_OS="$(python3 scripts/release-config.py --field minimumOS)"
for ARCH in "${ARCHITECTURES[@]}"; do
  BIN="build/native-$ARCH"
  mkdir -p "$BIN"
  TARGET="$ARCH-apple-macosx$MIN_OS"
  xcrun swiftc -swift-version 5 -target "$TARGET" -O -parse-as-library \
    -emit-module -emit-library -static -module-name TokenotchCore sources/Core/*.swift \
    -emit-module-path "$BIN/TokenotchCore.swiftmodule" -o "$BIN/libTokenotchCore.a"
  xcrun swiftc -swift-version 5 -target "$TARGET" -O -parse-as-library \
    -I "$BIN" -L "$BIN" -lTokenotchCore -lsqlite3 sources/Hook/*.swift -o "$BIN/TokenotchHook"
  xcrun swiftc -swift-version 5 -target "$TARGET" -O -parse-as-library -module-name Tokenotch \
    -I "$BIN" -L "$BIN" -lTokenotchCore -lsqlite3 \
    sources/App/*.swift sources/Notch/*.swift sources/Settings/*.swift \
    sources/DesignSystem/*.swift sources/L10n.swift -o "$BIN/Tokenotch"
done
# Executable smoke checks link the host slice.
mkdir -p build/native
cp "build/native-$(uname -m)/TokenotchCore.swiftmodule" "build/native-$(uname -m)/libTokenotchCore.a" build/native/
STAGE="$(mktemp -d build/tokenotch-bundle.XXXXXX)"
APP="$STAGE/Tokenotch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/CopilotUsage"
APP_INPUTS=()
HOOK_INPUTS=()
for ARCH in "${ARCHITECTURES[@]}"; do
  APP_INPUTS+=("build/native-$ARCH/Tokenotch")
  HOOK_INPUTS+=("build/native-$ARCH/TokenotchHook")
done
lipo -create "${APP_INPUTS[@]}" -output "$APP/Contents/MacOS/Tokenotch"
lipo -create "${HOOK_INPUTS[@]}" -output "$APP/Contents/Helpers/TokenotchHook"
cp integrations/CopilotUsage/extension.mjs "$APP/Contents/Resources/CopilotUsage/"
cp integrations/VSCode/TokenotchVSCode.vsix LICENSE "$APP/Contents/Resources/"
cp sources/Resources/Brand/*.png sources/Resources/Brand/Tokenotch.icns "$APP/Contents/Resources/"
cp sources/Resources/Brand/TokenotchBrandManifest.json "$APP/Contents/Resources/"
cp config/Release.json "$APP/Contents/Resources/"
python3 scripts/release-config.py --plist "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime "$APP/Contents/Helpers/TokenotchHook"
codesign --force --sign - --options runtime "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/verify-bundle.py "$APP"
if [[ -e build/Tokenotch.app ]]; then
  # Do not merge stale resources into the new bundle.
  mv build/Tokenotch.app "$STAGE/Previous-Tokenotch.app"
fi
mv "$APP" build/Tokenotch.app
python3 - "$STAGE" <<'PY'
import pathlib
import json
import plistlib
import shutil
import sys

stage = pathlib.Path(sys.argv[1])
if stage.is_symlink() or stage.parent.resolve() != pathlib.Path("build").resolve() or not stage.name.startswith("tokenotch-bundle."):
    raise SystemExit("Refusing cleanup outside the owned bundle staging directory.")
previous = stage / "Previous-Tokenotch.app"
if previous.is_symlink():
    previous.unlink()
elif previous.exists():
    if not (previous / "Contents/Info.plist").is_file():
        raise SystemExit("Previous build is not an app bundle; preserved for inspection.")
    identity = plistlib.loads((previous / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
    if identity == json.loads(pathlib.Path("config/Release.json").read_text())["bundleID"]:
        shutil.rmtree(previous)
    else:
        raise SystemExit("Previous bundle identity is not owned by this build; preserved for inspection.")
stage.rmdir()
PY
printf 'Development bundle: build/Tokenotch.app (%s; ad-hoc signed, NOT notarized)\n' "${ARCHITECTURES[*]}"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

case "${1:-}" in
  x64) targets=(x86_64-pc-windows-msvc) ;;
  arm64) targets=(aarch64-pc-windows-msvc) ;;
  all) targets=(x86_64-pc-windows-msvc aarch64-pc-windows-msvc) ;;
  *) echo "Usage: bash windows/scripts/cross-build.sh x64|arm64|all --allow-unsigned" >&2; exit 1 ;;
esac
if [[ "${2:-}" != "--allow-unsigned" || $# -ne 2 ]]; then
  echo "Signing is not configured. Pass --allow-unsigned to create unsigned local installers." >&2
  exit 1
fi
if [[ -n "${TAURI_CONFIG:-}" || -n "${TOKENOTCH_TEST_HOME:-}" ]]; then
  echo "Remove TAURI_CONFIG and TOKENOTCH_TEST_HOME smoke overrides explicitly before building." >&2
  exit 1
fi

for tool in cargo cargo-xwin clang-cl llvm-rc makensis 7zz node npm python3; do
  command -v "$tool" >/dev/null || { echo "Missing cross-build prerequisite: $tool" >&2; exit 1; }
done
python3 scripts/release-config.py
python3 scripts/make-brand-assets.py --check
python3 scripts/check-project.py
npm ci --prefix windows/desktop --ignore-scripts --no-audit --no-fund
npm test --prefix windows/desktop
npm run lint --prefix windows/desktop
npm run build --prefix windows/desktop
npm ci --prefix integrations/VSCode --ignore-scripts --no-audit --no-fund
npm run package --prefix integrations/VSCode
(
  cd windows
  cargo fmt --all -- --check
  cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked
)
for target in "${targets[@]}"; do
  architecture=x64
  if [[ "$target" == aarch64-* ]]; then architecture=arm64; fi
  (
    cd windows
    cargo xwin build -p tokenotch-hook --release --target "$target" --locked
    python3 scripts/prepare.py --target "$target" --helper "target/$target/release/TokenotchHook.exe"
    cargo xwin build -p tokenotch-desktop --features custom-protocol --release --target "$target" --locked
    python3 scripts/verify-pe.py --architecture "$architecture" --static-runtime \
      "target/$target/release/Tokenotch.exe" "target/$target/release/TokenotchHook.exe"
  )
  npm run tauri --prefix windows/desktop -- bundle --features custom-protocol --target "$target" --ci --no-sign
  python3 windows/scripts/stage-artifacts.py --architecture "$architecture"
done
echo "Unsigned Windows installers created. Native Windows execution and acceptance have NOT run."

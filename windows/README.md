# Tokenotch Windows development

This is the beginning of the Windows implementation, **not a supported Windows
release or a working Copilot connection**. The existing Swift macOS application
remains unchanged.

The foundation contains a Rust workspace, shared Swift/Rust hook and live-state fixtures, a
plain-JavaScript Tauri 2 desktop prototype, a native helper diagnostic, and
development packaging/CI for Windows x64 and ARM64. The desktop has a tray,
recoverable settings, a hover-expanding edge widget and session-only positioning.
The Rust core also implements bounded activity/token ledgers and source-aware
OTel normalization, tested independently from the desktop. No hooks, credentials,
local telemetry receiver or persistent usage are enabled.

## Development environments

Use the Mac for editing, portable Rust checks and the browser frontend. Use
actual Windows for Windows APIs, WebView2, installed helpers and desktop testing.
An ARM64 Windows guest on Apple Silicon can run the ARM64 app natively; running
the x64 app under emulation is not native x64 acceptance.

The engineering baseline is Windows 11 24H2 (build 26100) or later, with native
x64 and ARM64 payloads. This is a build target, not a compatibility certification.
Use separate local NTFS checkouts in Windows. Do not share Cargo build output,
`node_modules`, app data or credentials between hosts.

Required development tools:

- Rust 1.98.1 through rustup, including rustfmt and Clippy.
- Node 22.13+ with npm and Python 3.
- On Windows, Microsoft C++ Build Tools, the matching native MSVC/Windows SDK
  components, PowerShell 7 and the WebView2 Evergreen runtime.

The private Cargo/npm package versions describe the development workspace.
The product version comes from the repository's `config/Release.json`.
Run `python3 scripts/release-config.py --write` after changing shared identity.
Windows-only packaging inputs live in `windows/config/`.

## Portable work on the Mac

From the repository root:

Ensure Cargo is on PATH. If rustup was installed without changing your shell
configuration, run `. "$HOME/.cargo/env"` in the current Mac terminal first.

```sh
cd windows
cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked
cargo fmt --all -- --check
cargo clippy -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --all-targets --locked -- -D warnings
cd ..
npm ci --prefix windows/desktop --ignore-scripts --no-audit --no-fund
npm test --prefix windows/desktop
npm run lint --prefix windows/desktop
npm run build --prefix windows/desktop
npm run dev --prefix windows/desktop
```

Open `http://127.0.0.1:1420`. The page explicitly identifies itself as a browser
preview. Appearance controls change only the demonstration, not the Mac desktop.
The widget preview is available at `/?surface=widget`.

Browser interaction checks use Playwright. From `windows/desktop`, run
`npx --no-install playwright install chromium` once, then `npm run test:browser`.
They do not replace native WebView2 acceptance.

`make smoke-contracts` runs the same hook corpus through the Swift implementation
using Command Line Tools. XCTest includes it through `WindowsContractTests`.
The shared corpus covers hook normalization and selected activity, deduplication,
retention and context-invalidation transitions. Rust also tests OTel producer
routing and cache accounting. These do not establish full notice/history parity
or live-client compatibility.

## Building Windows installers on the Mac

Native Windows remains the acceptance environment. When it is unavailable,
the supported cross-build path can produce genuine x64 and ARM64 Windows
executables and unsigned NSIS installers for later Windows testing.

Additional build prerequisites are `cargo-xwin` 0.23.1, LLVM, NSIS and 7-Zip.
The exercised Homebrew tools were LLVM 23.1.2, NSIS 3.13 and 7-Zip 26.03.
`cargo-xwin` downloads the Microsoft CRT/SDK required by MSVC targets.
Keep Tauri's locked runtime/macro/codegen dependency family together; an
uncoordinated Cargo update can select incompatible transitive versions.

After installing those prerequisites, from the repository root:

```sh
export PATH="$HOME/.cargo/bin:$(brew --prefix llvm)/bin:$PATH"
rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc
bash windows/scripts/cross-build.sh all
```

Use `x64` or `arm64` instead of `all` for one architecture. Installers and SHA-256
files are written under `build/windows/<architecture>/`. The script checks the
PE architecture of the embedded app/helper and verifies archive integrity,
metadata and the license notice without executing the installer.
Windows targets statically link the Visual C++ runtime; the payload checker
rejects ordinary or delayed imports requiring a separate VC++ Redistributable.
WebView2 is still required and is handled separately by the installer.

Cross-compilation is experimental in Tauri. It does not verify installation,
WebView2 behavior, native Windows IPC/ACLs, real clients or desktop interaction.
It is not a substitute for either Windows CI job or a signed-release gate.

## Native Windows development

Run from the repository in PowerShell 7, selecting the **native OS architecture**:

```powershell
.\windows\scripts\build.ps1 -Architecture x64
.\windows\scripts\package.ps1 -Architecture x64 -Development
```

Use `-Architecture arm64` on Windows ARM64. The script refuses a different native
OS architecture rather than reporting an emulated run as native. Both builds
are required. It installs locked frontend dependencies, runs checks, builds the
helper, stages architecture-specific resources and builds the desktop.

Unsigned installers and checksums go to `build/windows/<architecture>/`.
Only development packaging exists. Signing, public release publishing and
automatic updates are not implemented.

On a designated disposable Windows environment only:

```powershell
.\windows\scripts\verify-install.ps1 -Architecture x64 `
  -Installer <development-setup.exe> -DisposableEnvironment
```

This installs into a unique temporary location, checks payload architecture,
runs the installed helper diagnostic and invokes the uninstaller. It does not
certify desktop interaction or live clients. Do not use a production installation
or shared user profile for installer tests.

The `Windows development checks` workflow runs both architectures and uploads
development artifacts; it does not publish a release. The x64 hosted image is
Windows Server, so actual Windows 11 desktop acceptance remains separate.

## Remaining implementation gates

Native Windows execution and installer behavior must be verified before this
prototype becomes the CLI preview. The following are still unavailable:

- Windows private-file/ACL and named-pipe transport, owned hook installation,
  real CLI metrics, account sign-in and quota.
- VS Code private-store broker, Local lifecycle and authenticated OTel usage.
- Persistent history, timelines, remembered notices and Windows notifications.
- Saved placement, multi-display coordination, fullscreen hiding, transparent
  hit-region verification and full keyboard/Narrator acceptance.
- Signed installer upgrade/recovery/uninstall acceptance and manual release checks.

The helper supports `--self-test` only. Other invocations fail with a fixed
message and do not read stdin or alter client configuration. Do not configure
clients to launch it as a telemetry hook yet.

Shared contracts are described in [contracts](../contracts/README.md). Existing
[privacy](../docs/tokenotch-privacy.md) and
[integration](../docs/tokenotch-integrations.md) documents remain behavioral
requirements, not evidence that Windows integrations already work.

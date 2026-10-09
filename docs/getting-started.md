# Getting started with Tokenotch

This guide covers installing Tokenotch on **macOS**, connecting your first Copilot
client, and keeping the app up to date. For a short overview, see the
[README](../README.md). For Windows downloads, installation and setup, see the
[Windows guide](../windows/README.md#download-windows).

## Requirements

- **macOS 15 or later**, Apple Silicon or Intel.
- A supported local Copilot client: **GitHub Copilot CLI** and/or **Visual
  Studio Code**. Client availability and acceptance are recorded in the
  [compatibility matrix](compatibility.md); optional Preview capabilities must
  not be treated as guaranteed.

## Install

The official distribution channel is
[GitHub Releases](https://github.com/rottathiago/tokenotch/releases).
Choose either installer from a published release:

- **Tokenotch.dmg**: open it and drag **Tokenotch.app** onto **Applications**.
  The newest DMG is always available at
  [releases/latest/download/Tokenotch.dmg](https://github.com/rottathiago/tokenotch/releases/latest/download/Tokenotch.dmg).
- **Tokenotch.pkg**: open it and follow the installer; it places
  **Tokenotch.app** in `/Applications` (administrator approval required) and
  refuses to downgrade a newer installed version.

### Unsigned downloads

Regular GitHub Releases may contain unsigned DMG and PKG installers. Apple
Developer ID signing and notarization are optional, not publication
requirements. The release notes record the actual signing status, the source
revision and SHA-256 checksums; the only release attachments are the DMG and
PKG. Unsigned apps use ad-hoc signing, not a verified Apple Developer ID, and
have not been notarized by Apple.

macOS may block an unsigned download. After trying to open the installer or
app, use **System Settings > Privacy & Security > Open Anyway** only if you
trust the official download and your Mac permits it. Managed Macs may not allow
this. Do not disable Gatekeeper or strip quarantine. See
[installation help](support.md#unsigned-downloads).

### Build from source

This is the complete macOS development build/install path. It works on
**macOS 15 or later**, on Apple Silicon or Intel, and does not require an Apple
Developer account, signing certificates, or a release tag.

#### 1. Install the required tools

| Tool | Requirement |
| --- | --- |
| Apple developer tools | Swift 6+ and a macOS 15+ SDK from matching Command Line Tools or full Xcode. Full Xcode 16.4 is the native CI baseline; full Xcode is required for XCTest, but not for `make package`. |
| Node.js and npm | [Node.js 22.12+](https://nodejs.org/en/download) with its bundled, working npm. The build packages the VS Code companion even if you only intend to connect Copilot CLI. |
| Python | [Python 3.9+](https://www.python.org/downloads/macos/), available as `python3`; packaging uses only its standard library. |
| Build/installer utilities | Git and Make from the developer tools; macOS `codesign`, `ditto`, `hdiutil`, `pkgbuild`, `productbuild` and `pkgutil`. No third-party DMG builder is needed. |

For the Command Line Tools route, run this once and finish the installation
dialog before continuing:

```sh
xcode-select --install
```

Install Node.js and Python using their macOS installers if they are not already
available. If you have full Xcode and want to use it instead, select it for the
current terminal without changing the system-wide selection:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc --version
```

Adjust that path if your Xcode app has a different name. Do not mix a standalone
Swift download with an unrelated Apple SDK. Clear stale `SDKROOT` or `TOOLCHAINS`
overrides if the selected tools cannot find a compatible macOS SDK.

**Not required for packaging:** XcodeGen (optional Xcode project), lychee
(documentation link checks), and Pillow/`iconutil` (regenerating artwork).
The repository already contains the generated artwork. A local VS Code or
Copilot CLI installation is needed to connect a client, not to build the app.

#### 2. Clone and check prerequisites

Run these commands in Terminal:

```sh
git clone https://github.com/rottathiago/tokenotch.git
cd tokenotch
make preflight
```

Preflight prints the Python, Node/npm, Swift and SDK versions, plus the selected
Apple `lipo` path. It checks build and installer prerequisites without installing
anything or changing settings, and type-checks framework imports to detect an
incompatible Swift/SDK pair before the real build. Resolve any reported error before continuing.
For example, a Node/npm `dyld` error means that installation needs repair;
finding the executable on `PATH` alone is not enough.

#### 3. Build and verify the installers

From the same `tokenotch` directory:

```sh
make package
python3 scripts/verify-bundle.py build/Tokenotch.app --universal
codesign --verify --deep --strict build/Tokenotch.app
(cd build/packages && shasum -a 256 -c Tokenotch.dmg.sha256 Tokenotch.pkg.sha256)
```

The build downloads the companion's locked npm dependencies, runs its tests,
and compiles both `arm64` and `x86_64` slices for the app and helper. It then
builds and checks both installer payloads. Do not use `sudo` for the build.
Architecture creation/verification uses the selected Apple toolchain through
`xcrun`, not an unrelated `lipo` earlier on `PATH`.

| Output | Purpose |
| --- | --- |
| `build/Tokenotch.app` | Universal development app with bundled helper and companion |
| `build/packages/Tokenotch.dmg` | Drag-to-Applications installer |
| `build/packages/Tokenotch.pkg` | System Applications installer |
| `build/packages/Tokenotch.dmg.sha256` and `Tokenotch.pkg.sha256` | SHA-256 files; both checksum checks should print `OK` |

Each `make package` replaces the previous development installers. To build only
one format, use `make package PACKAGE_ARGS="--format dmg"` (or `pkg`). To package
an already-built **universal** app, use
`make package PACKAGE_ARGS="--skip-build"`; that route checks packaging tools
without requiring Node/npm or the Swift compiler. A host-only `make build` app
does not satisfy universal installer verification.

#### 4. Install and launch

Quit any running copy of Tokenotch before replacing it. Choose **one** route:

- **DMG:** run `open build/packages/Tokenotch.dmg`, drag **Tokenotch.app** onto
  **Applications**, eject the disk image, then open Tokenotch from Applications.
- **PKG:** run `open build/packages/Tokenotch.pkg` and complete the installer.
  It requires administrator approval, installs to `/Applications`, and refuses
  to downgrade a newer installed version. Then open Tokenotch from Applications.
- **User-local app:** copy the built bundle to `~/Applications` as shown below.
  This needs no system-wide installer or administrator approval.

For the app-only route, `make build` can replace `make package` above; it builds
only your Mac's architecture. If you already ran `make package`, reuse its
universal `build/Tokenotch.app`. The following commands deliberately refuse to
merge into an existing app; quit it and move the old copy aside in Finder first:

```sh
mkdir -p "$HOME/Applications"
if [ -e "$HOME/Applications/Tokenotch.app" ] || [ -L "$HOME/Applications/Tokenotch.app" ]; then
  echo "Quit Tokenotch and move the existing ~/Applications/Tokenotch.app aside before copying." >&2
else
  ditto build/Tokenotch.app "$HOME/Applications/Tokenotch.app" &&
    open "$HOME/Applications/Tokenotch.app"
fi
```

The app and helper are **ad-hoc signed**, not Developer ID signed; the DMG and
PKG are unsigned and **not notarized**. A successful `codesign --verify` confirms
signature integrity, not Apple trust. Gatekeeper can still block an installer
or app; use the permitted per-app approval described under
[unsigned downloads](#unsigned-downloads), never disable Gatekeeper or remove
quarantine. Launching should display the first-run guide on a fresh profile;
continue with [First signal](#first-signal) to connect a client.

For contributor tests and optional tools, see [contributing](../CONTRIBUTING.md).
`make release` is a separate maintainer path requiring a clean matching version
tag; it is not necessary to build or install locally. See
[releasing](releasing.md#development-installers).

#### Source-build validation

Validated on **2026-10-09** in a fresh local clone with the working-tree changes
applied, without pre-existing build output or companion dependencies:
Apple Silicon, macOS **27.0.1**, Command Line Tools **27.0**, Swift **6.4**,
macOS SDK **27.0**, Node **26.5.0**, npm **11.17.0**, and Python **3.12.8**.
The skip-build route was also validated with system Python **3.9.6**.
These are tested versions, not new minimum requirements.

| Command | Recorded result |
| --- | --- |
| `make preflight` | Passed; selected Apple tools, SDK/framework compatibility, Node/npm and installer prerequisites checked |
| `make package` | Passed; 141 companion tests passed; universal app/helper and both verified installers produced |
| `python3 scripts/verify-bundle.py build/Tokenotch.app --universal` | Passed for both architectures in both binaries |
| `codesign --verify --deep --strict build/Tokenotch.app` | Passed; ad-hoc signature integrity only |
| `(cd build/packages && shasum -a 256 -c Tokenotch.dmg.sha256 Tokenotch.pkg.sha256)` | Both installers printed `OK` |
| `PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/python3 scripts/package.py --skip-build --output build/skip-build-check` | Passed with Python 3.9.6 and no Node/npm on `PATH`; both installer checksums verified |
| `python3 scripts/test-package.py` | 21 tests passed |
| `python3 scripts/test-preflight.py` | 16 tests passed, including incompatible SDK/compiler and missing/broken tools |
| `python3 scripts/test-release.py` | 23 tests passed |
| `python3 scripts/test-project.py` | 7 tests passed |
| `make metadata` | Passed |
| `make docs-check` | Markdown/local links passed; 9 checker tests passed, 1 case-sensitive-filesystem test skipped on this Mac |
| `make test-ci` | Blocked before XCTest by the full-Xcode prerequisite guard; no XCTest result claimed |

Additional native checks rejected all four app/helper missing-architecture
fixtures, verified the mounted DMG and expanded PKG payloads, and verified a
disposable user-local app copy's bytes and signatures. Missing Node/npm failed
before changing existing installers; missing Python produced actionable errors.

**Not verified in this run:** full-Xcode XCTest, native Intel execution, a
pristine Mac, GUI DMG/PKG installation, first-launch onboarding, or a quarantined
browser download's Gatekeeper behavior. Full Xcode was unavailable, and an
existing Tokenotch instance was left running rather than replacing or launching
against its live profile. Payload/copy verification is not a claim of GUI
installation, launch, notarization, or real-client acceptance.

## First signal

1. Start the first-run guide and choose **Copilot CLI** or **Visual Studio Code**.
   Setup stays inside the guide; you can connect either client or both.
2. Configure at least one chosen client. CLI setup installs owned hooks and a
   numeric usage extension. VS Code setup installs a bundled companion, then
   asks for approval in your selected editor/profile. Installing that companion
   alone is not completed configuration.
3. Choose optional account quota, notifications, saved history, timelines, or
   remembered notices. Each is independent and off by default on a fresh install.
   **Finish setup** shows a welcome and a summary of configured and unfinished
   items; activity is not required to complete setup.
4. Reload existing CLI sessions or the VS Code window as instructed. Run your
   normal Copilot work and look for **Data received**. “Installed” and “Waiting
   for data” are not proof that events are arriving.

**Pause setup** or close the guide to resume at the same step later; this does
not mark onboarding complete. Account quota sign-in uses the official CLI browser
flow and does not replace a local client connection. After setup, use
**Settings > Connections** to add or repair clients, **Usage** for account quota,
or **General > Review Setup Guide** to revisit the guide without resetting consent.

## What the numbers mean

A stopped turn does **not** prove task success. A viewed approval notice does
**not** approve a request. Missing data is unavailable, not zero. Local counts
are not account-wide billing, costs, or a productivity score.

Token and model counts only include activity that Tokenotch observed on this Mac
while it was running. Usage from before Tokenotch was started, from other
machines, or from unsupported clients is not included and is not backfilled.
For official usage, limits and billing, check GitHub or your enterprise dashboard.

Remote SSH, containers, WSL, Codespaces, cloud agents and other IDEs/providers
are outside 1.0.0. See the [feature reference](features.md) and
[integration contracts](tokenotch-integrations.md).
VS Code lifecycle coverage targets the Local harness; Agent Host usage is
separate telemetry, not a promise of lifecycle or attention parity.

## Updates and support

**Check for Updates** contacts GitHub only when selected and offers the official
release page when a newer public stable version exists. Nothing is downloaded or
installed automatically. Quit Tokenotch, replace the app in Applications, reopen,
and follow any Connections repair/reload instructions.

For troubleshooting, use **Settings > Privacy > Diagnostics** and review the
report before sharing it. Never post prompts, credentials, transcripts, or
private paths. See [support](support.md), [privacy and retention](tokenotch-privacy.md)
and [security reporting](../SECURITY.md).
Tokenotch uses its own data folder and preferences domain; it does not import
data or settings from other applications.

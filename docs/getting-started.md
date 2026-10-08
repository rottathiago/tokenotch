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

To build **unsigned** development installers from source, run `make package`;
they are written to `build/packages/`. Use `make release` from a clean matching
version tag to build verified unsigned public installers in `build/releases/`.
See [contributing](../CONTRIBUTING.md) for prerequisites.

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

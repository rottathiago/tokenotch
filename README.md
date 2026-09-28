# Tokenotch

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="sources/Resources/Brand/TokenotchMarkDark.png">
  <img src="sources/Resources/Brand/TokenotchMark.png" width="180" alt="Tokenotch">
</picture>

**Visibility into your AI coding usage and patterns.**

Tokenotch gives developers clear visibility into their AI coding usage and
patterns. It tracks token consumption and model usage across GitHub Copilot CLI
and Visual Studio Code sessions. A minimalist notch interface lets you run multiple
coding agents at once and alerts you when a session needs your action or
attention, without saving your prompts or code.

Tokenotch is an independent project and is not affiliated with or endorsed by
GitHub or Microsoft.

**Public source, pre-production app:** source and development CI are available
in this repository, but there is no stable application release yet. Universal
development builds are available from source. Production installers remain blocked until
signing, notarization and real-client/hardware acceptance are approved. An ad-hoc
development build is not a notarized production release.

Contributions are welcome; start with [contributing](CONTRIBUTING.md).
[Release readiness](TASKS.md) records what still blocks public source and
signed-installer publication.

## Install

The intended distribution channel is
[official GitHub Releases](https://github.com/rottathiago/tokenotch/releases).
When a stable signed release is published, download either installer:

- **Tokenotch.dmg**: open it and drag **Tokenotch.app** onto **Applications**.
- **Tokenotch.pkg**: open it and follow the installer; it places
  **Tokenotch.app** in `/Applications` (administrator approval required) and
  refuses to downgrade a newer installed version.

Then open Tokenotch from Applications normally. Verify the download against its
`.sha256` file if you like. Do not disable Gatekeeper or strip quarantine to
work around a failed signature.

To build local, **unsigned** installers from source, run `make package`; they
are written to `build/packages/` and are for testing on your own Mac only.

Requires **macOS 15 or later**, Apple Silicon or Intel, and a supported local
Copilot client. Client availability and acceptance are recorded in the
[compatibility matrix](docs/compatibility.md); optional Preview capabilities
must not be treated as guaranteed.

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

## What Tokenotch can show

- A compact notch with explicit working, stopped, attention, stale, and unavailable states.
- Partial local token/model observations, including distinct input/output/cache categories.
- A context-window bar beneath each session shown in the notch, with reported usage,
  explicit stale/unavailable states, and CLI refreshes after model or conversation changes.
- Optional runtime-reported account quotas, separate from local history or your bill.
- Independently opt-in notifications, local usage history, and session timelines.
- Optional public Copilot service health and a previewable, redacted diagnostic report.

A stopped turn does **not** prove task success. A viewed approval notice does
**not** approve a request. Missing data is unavailable, not zero. Local counts
are not account-wide billing, costs, or a productivity score.

Remote SSH, containers, WSL, Codespaces, cloud agents, other IDEs/providers, and
Windows are outside 1.0.0. See the [feature reference](docs/features.md) and
[integration contracts](docs/tokenotch-integrations.md).
VS Code lifecycle coverage targets the Local harness; Agent Host usage is
separate telemetry, not a promise of lifecycle or attention parity.

## Privacy and local data

Tokenotch has no backend, analytics, or automatic crash reporting. Client content
is discarded before retention. Optional archives stay in private `~/.tokenotch`
storage; retaining one kind of data does not authorize another.

See [privacy and retention](docs/tokenotch-privacy.md) and
[setup, recovery, and uninstall](docs/support.md).
Tokenotch uses its own data folder and preferences domain; it does not import
data or settings from other applications.

## Updates and support

**Check for Updates** contacts GitHub only when selected and offers the official
release page when a newer public stable version exists. Nothing is downloaded or
installed automatically. Quit Tokenotch, replace the app in Applications, reopen,
and follow any Connections repair/reload instructions.

For troubleshooting, use **Settings > Privacy > Diagnostics** and review the
report before sharing it. Never post prompts, credentials, transcripts, or
private paths. See [support](docs/support.md) and [security reporting](SECURITY.md).

## Build and contribute

Use a coherent full Xcode toolchain (CI selects Xcode 16.4), Node 22.12+, and Python 3.
Native builds/smoke executables also support matching Command Line Tools;
XCTest requires full Xcode.

```sh
make metadata        # identities, versions, and updated-logo provenance
make build           # fresh host-architecture development bundle
make universal       # universal app and helper; still ad-hoc signed
make test-ci         # full XCTest and release gate tests
make smoke smoke-telemetry
make smoke-history smoke-timeline smoke-notch  # native UI checks need a GUI session
make smoke-notch NOTCH_SMOKE_ARGS=--onboarding # focused setup and connection UI checks
```

The source logo is `docs/design/tokenotch-notch-logo.png` and the app icon source is
`docs/design/tokenotch-logo-app-icon.png`. After changing either, run
`python3 scripts/make-brand-assets.py` (Pillow and macOS iconutil required).
Builds refuse stale app/menu/Settings/companion artwork.

See [contributing](CONTRIBUTING.md) and the
[signed release runbook](docs/releasing.md). `make release` fails closed without
exact-revision acceptance, owned identities, a clean tagged tree, and Developer
ID/notarization configuration. Nothing is published by local packaging.

Documentation-only changes need no Xcode. Follow the locked tooling setup in
[contributing](CONTRIBUTING.md#prerequisites), then run `make docs-check`.

Tokenotch is Copyright (c) 2026 rottathiago and released under the MIT License.
It includes MIT-licensed code, Copyright (c) 2026 Vinz. The original
copyright and permission notice are preserved in [LICENSE](LICENSE) and
distributed with the app and companion.

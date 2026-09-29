# Contributing to Tokenotch

Contributions to documentation, accessibility, tests and focused improvements
are welcome. Tokenotch gives developers clear visibility into their AI coding
usage and patterns across GitHub Copilot CLI and Visual Studio Code sessions. Start with the [README](README.md), [features](docs/features.md)
and [release readiness](TASKS.md). Discuss substantial behavior, privacy or
integration changes in an issue before implementing them.

## Set up a contribution

Fork `rottathiago/tokenotch` on GitHub, then clone your fork:

```sh
git clone https://github.com/YOUR-USERNAME/tokenotch.git tokenotch
cd tokenotch
git remote add upstream https://github.com/rottathiago/tokenotch.git
git switch -c describe-your-change
```

For a read-only build, clone `https://github.com/rottathiago/tokenotch.git` instead.
Keep changes focused and preserve existing work. Do not commit installers,
generated build output, credentials, machine-local files or personal diagnostics.

## Prerequisites

| Work | Requirements |
| --- | --- |
| Markdown and local links | Node 22.12+ and npm; [lychee 0.24.2](https://github.com/lycheeverse/lychee/releases/tag/lychee-v0.24.2). No Xcode needed. |
| Native builds and executable smoke checks | macOS 15+, a coherent Swift 6+ toolchain from Xcode or matching Command Line Tools, Node 22.12+/npm and Python 3. |
| XCTest | Full Xcode, not Command Line Tools alone. CI selects Xcode 16.4; select it with `DEVELOPER_DIR` when multiple toolchains are installed. |
| VS Code companion | Node 22.12+ and npm; dependencies are pinned in its lockfile. Real-client checks require a supported local VS Code installation/profile. |
| Optional Xcode project | XcodeGen, in addition to native prerequisites. |
| Regenerating artwork | Python 3 with Pillow and macOS `iconutil`; not required just to check existing artwork. |

Install the locked documentation dependencies once:

```sh
npm ci --prefix scripts/docs --ignore-scripts --no-audit --no-fund
make docs-check
```

Install the pinned lychee release appropriate to your host and put `lychee` on
`PATH`. Documentation tooling is development-only; it is not packaged in Tokenotch.
Update tool pins and lockfiles together when intentionally upgrading them.

## Repository map

| Path | Responsibility |
| --- | --- |
| `sources/Core` | Event contracts, accounting, local storage, policy and runtime boundaries |
| `sources/App` | Lifecycle, connections, onboarding and controller coordination |
| `sources/Notch`, `sources/Settings` | Native presentation and accessibility |
| `sources/Hook` | Bounded, content-stripping native helper |
| `integrations/CopilotUsage` | CLI usage/context extension |
| `integrations/VSCode` | Consent-based local setup companion and isolated tests |
| `tests`, `scripts` | XCTest/shared fixtures, smoke checks and packaging |
| `config`, `docs` | Release identity, user guidance and technical contracts |

## Validate the change you made

| Change | Appropriate starting checks |
| --- | --- |
| Documentation | `make docs-check`; inspect rendered headings, tables, links and image descriptions |
| Core or CLI integration | `make test`, `make smoke`; select affected XCTest cases while iterating |
| VS Code companion or telemetry | `make vscode-companion`, `make smoke-telemetry` |
| History or timelines | `make smoke-history` or `make smoke-timeline` |
| Native UI or onboarding | `make smoke-notch`; use `NOTCH_SMOKE_ARGS=--onboarding` for focused setup checks |
| Release metadata or packaging | `make metadata`, `make universal`, `make package`; inspect the resulting development bundle |

`make test` and `make test-ci` run the same XCTest and release-gate suite.
`make build` produces a host-architecture development app; `make universal`
produces both architectures. Both use ad-hoc signing without notarization.
`make release` packages unsigned public installers from a clean matching tag;
`make release RELEASE_ARGS=--signed` opts into Developer ID signing and notarization.
`make gen` packages the companion and generates the optional Xcode project;
`make test-xcode` runs its scheme. Native UI smoke checks require a GUI session.

The required `Documentation checks / docs` job runs offline Markdown/local-link
checks after installing tools. Maintainers can run `make docs-links-external`
on reviewed content for advisory HTTPS checks; do not run network checks on
untrusted contributions. A skipped or unreachable external URL is not verified.
Native CI still runs its complete checks; a documentation-only contributor need
not claim to have run those locally.

For native UI timing regressions, run
`xcrun swift test --filter 'NotchWaitTests|HistoryPresentationTests|testIdleAutoHideAndHoverExpansion'`.
CI repeats these fixtures three times after the full suite. With matching Command
Line Tools and a GUI session, `make smoke-notch NOTCH_SMOKE_ARGS=--ui-timing` runs
the same wait, history-rendering and auto-hide checks without XCTest. Fixture waits
use bounded elapsed-time deadlines and report the expected state on failure;
auto-hide timing uses the fleet's injected clock while still exercising its real
pointer timer. Do not replace state checks with fixed sleeps or retry failed tests
until they pass.

Both workflows use read-only repository permissions and cancel superseded runs
for the same branch or PR. Required checks have no path filters: documentation-only
PRs still receive both check results. Native CI builds development installers
for verification but does not publish them or receive signing secrets.

## Contracts, privacy and accessibility

Read [integration contracts](docs/tokenotch-integrations.md) before changing event
semantics. Add source-specific synthetic fixtures for new behavior, missing
fields, failures and privacy stripping. Missing data is unavailable, not zero;
stopping is not proof of success, and local token counts are not a bill.

Tests must use isolated directories and synthetic events. Never read developer
credentials, install real hooks, enable real client telemetry or publish a VSIX
as validation. Keep XCTest launch guards. Telemetry smoke tests use a temporary
authenticated loopback receiver and stop it afterward.

No private API fallbacks, transcript scraping or silent token discovery.
Preserve owner-only files, bounded helpers, independent consent and exact-owned
cleanup. Real-client acceptance requires consent and recorded client/OS versions;
successful settings writes and synthetic fixtures do not establish delivery.

For UI changes, check keyboard use, VoiceOver, reduced motion/transparency,
display edges, multiple displays and full-screen behavior when available.
Report untested conditions honestly in the PR and compatibility record.

## Submit and review

Open a focused PR explaining the problem, approach, relevant issue, checks run
and anything not verified. Include synthetic/redacted screenshots for visual
changes. Documentation, regression fixtures and small reproducible bug reports
are useful contributions even without access to every supported Mac.

The maintainer decides scope and merges accepted changes. Expect discussion
and revision; there is no guaranteed review or support response time. Update
directly affected documentation and preserve the existing coding/test patterns.
No CLA or DCO is required; contributions are provided under this repository's
[MIT license](LICENSE). Submit only material you have the right to contribute,
and retain upstream copyright and third-party notices.

`@rottathiago` is currently the sole maintainer and code owner, and is the only
person who can merge. Every PR, including the maintainer's own, needs passing
native/documentation checks and resolved review discussions before merging; no
separate approving review is required while there is a single maintainer.
Reviews from other contributors are welcome.
See the [repository protection setup](docs/releasing.md#public-source-gate).

Be respectful, constructive and mindful of privacy. A Code of Conduct and
verified private conduct-reporting route are follow-up work, not blockers for
initial source publication. No conduct-reporting channel is advertised yet.
Do not post conduct allegations or security details in public issues;
[SECURITY.md](SECURITY.md) covers the separate vulnerability-reporting route.

## Maintainer release changes

`config/Release.json` is authoritative. After changing identity/version fields,
run `python3 scripts/release-config.py --write` and `make metadata`.
`make metadata` includes tracked and untracked publication-tree checks; it does
not replace staged-diff review or a history-aware exposure assessment.

Brand sources are `docs/design/tokenotch-notch-logo.png` and
`docs/design/tokenotch-logo-app-icon.png`. Regenerate with
`python3 scripts/make-brand-assets.py` (Pillow and macOS `iconutil` required);
keep app/companion assets consistent. Builds refuse stale app, menu, Settings
and companion artwork.
Hashes establish correspondence, not distribution rights.

See [releasing](docs/releasing.md) for public unsigned releases and optional signed
installers. PRs receive no signing secrets. Keep required CI, owned source,
licensing, version/tag checks, truthful verification status and owner-authorized
publication. Unsigned releases do not require Apple credentials or a signed-release
acceptance record; never fabricate that evidence or claim notarization.

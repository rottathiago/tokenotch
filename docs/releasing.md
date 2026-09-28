# Releasing Tokenotch

## Source and identity

`config/Release.json` is the authoritative release configuration. The current
independent identity is `io.github.rottathiago.tokenotch`, the intended repository
is `rottathiago/tokenotch`, and the locally bundled companion is
`rottathiago.tokenotch-vscode`. These do not imply marketplace registration,
Apple signing approval, or an existing published release.

After changing release metadata, run:

```sh
python3 scripts/release-config.py --write
make metadata
```

Review generated Swift/Xcode/companion metadata and the npm lockfile. Keep the
wire/storage schema versions separate from the app version and increment the
build number monotonically for redistributed builds. Preserve the MIT notice
and verify distribution rights for all code/artwork.

Add `docs/releases/<version>.md` for every version before tagging it. Packaging
refuses missing or empty notes; the workflow uses the notes matching the selected
tag rather than reusing the first release's description.

Prepare candidate notes, compatibility wording and the supported-version policy
in `SECURITY.md` before freezing the source revision. Record actual acceptance
externally afterward. Changing source or documentation changes the revision;
reassess the affected evidence rather than copying an old approval onto a new SHA.

`make metadata` also checks publishable filenames and content, including untracked
files. It rejects retired product names, obsolete distribution trees, local
filesystem metadata, installer artifacts, and signing-key files. It is not a
replacement for reviewing the staged diff and scanning for secrets before pushing.
The app and companion retain the original MIT copyright and permission notice;
renaming the product does not remove those obligations.

The canonical native bundler uses isolated architecture outputs, freshly
packages the companion, verifies resources/logo provenance, and combines both
app and helper slices for `make universal`. XcodeGen is an alternative
development/test project, not a different release product.

## Development installers

`make package` (`python3 scripts/package.py`) builds the universal bundle and
writes `build/packages/Tokenotch.dmg` and `build/packages/Tokenotch.pkg` with SHA-256
files, replacing the previous development installers. Pass
`PACKAGE_ARGS="--skip-build"` to reuse `build/Tokenotch.app` or `--format dmg|pkg`
for one installer. The DMG is a drag-to-Applications image; the PKG is a
non-relocatable, version-checked product archive that installs only to
`/Applications` on the local system, checks the minimum macOS version and
architecture, shows the MIT license, and runs no install scripts.

Development installers stay on the `development` channel, ad-hoc signed and not
notarized. They are for local or hands-on testing; copies downloaded through a
browser are blocked by Gatekeeper and must never be published as releases.

## Required external acceptance

`config/ReleaseAcceptance.json` intentionally contains false/unrecorded gates.
Do not turn them true merely because synthetic tests or cross-builds pass.
Collect real hardware/client, accessibility, upgrade/recovery, privacy/security, and
performance evidence for the exact source revision.

Create an external acceptance JSON file using that schema and set
`sourceRevision` to the exact committed revision being tagged. Keeping the
evidence outside the source tree avoids changing the revision it attests.
`TOKENOTCH_RELEASE_EVIDENCE` selects it locally; the protected release environment's
`TOKENOTCH_RELEASE_ACCEPTANCE` variable supplies it in CI. All gate values must be
JSON booleans, not strings. Owner approval is explicit.

Require native Apple Silicon and Intel acceptance, both local clients, all
advertised OS combinations, and normal browser-download/Gatekeeper behavior.
Record optional Preview limitations and measured performance against explicit
owner-approved acceptance criteria. Archived design proposals are not current
release criteria; do not claim unrecorded results.

## Signing configuration

Use an owned Developer ID Application certificate (app, helper, and DMG), a
Developer ID Installer certificate (PKG), and a notarization account.
Verify actual signing identities when preparing the release; documentation and
configured identifiers do not prove certificate ownership. Never commit credentials.

Local environment:

- `TOKENOTCH_SIGNING_IDENTITY`: Developer ID Application SHA-1 fingerprint, not an ad-hoc identity.
- `TOKENOTCH_INSTALLER_IDENTITY`: Developer ID Installer SHA-1 fingerprint.
- `TOKENOTCH_TEAM_ID`: verified Apple developer team identifier.
- `TOKENOTCH_NOTARY_PROFILE`: a notarytool keychain profile you configured securely.
- `TOKENOTCH_SIGNING_KEYCHAIN`: optional keychain holding that profile.
- `TOKENOTCH_RELEASE_EVIDENCE`: path to the exact-revision acceptance record.

Set the `origin` Git remote to the owned repository, or run from its checkout.
Preserve Git history and required attribution. Push Tokenotch tags and artifacts only
to the repository configured in `config/Release.json`.
Use a clean tree with a protected `v<version>` tag.

```sh
python3 scripts/release.py --check
make release
```

Packaging reruns the native/resource checks in `scripts/release.py`; documentation
checks are a separate gate. Run `make docs-check` before freezing the revision
and verify its required CI result for the exact revision before authorizing the
release workflow. The packager does not fetch or certify GitHub check results.
It builds universal binaries, signs nested
code and app, verifies the Developer ID team, notarizes/staples the app, builds
and signs the DMG, notarizes/staples it, and assesses both with Gatekeeper. It
then builds the same app into a PKG signed with the Developer ID Installer
identity, verifies its team, notarizes/staples it, and assesses it as an
installer. Outputs include SHA-256 checksums for both installers and a
source/dependency/signing/acceptance inventory. Release installers are named
`Tokenotch.dmg` and `Tokenotch.pkg`; the version is recorded in the bundle, installer
metadata, and inventory. Existing release artifacts are not overwritten
silently, so move or remove the previous `build/releases` output first. Local packaging never publishes.

## GitHub workflow

The configured repository must be **public** before customer distribution.
Tokenotch's update checks intentionally use the unauthenticated GitHub Releases API;
a private repository, unpublished draft, or prerelease is not a customer update
channel. Never embed a repository token in the app to work around this.

### Public source gate

The current milestone is public source and development CI, not production
binaries. Source publication does not require Apple Developer enrollment or
pretending that signed installers or real hardware acceptance already exist.
It does require truthful release status, verified distribution rights, required
notices and working support/private security-reporting routes.

Review the prospective tree **and the history that will become public** for
private material and secrets. A clean working-tree scan does not clear old
commits. Triage scanner candidates locally without posting values; if remediation
requires changing history, obtain separate owner approval. Preserve history and
attribution by default. Keep internal evidence and machine-specific reports out
of published docs.

A Code of Conduct and verified private conduct-reporting route are nonblocking
follow-up work. Neither is a GitHub requirement for public repositories. Do not
advertise a placeholder reporting route or direct conduct complaints to security
advisories. Check code and artwork provenance separately from generated-asset
hashes.

After owner approval, commit the reviewed source and bootstrap the intended
default branch while the repository is still private. Push that branch explicitly
to `https://github.com/rottathiago/tokenotch.git`. Do not use
`--mirror`, `--tags` or `--follow-tags`: local inherited versions are not Tokenotch
releases. The initial push into an empty repository is a one-time bootstrap
exception; subsequent changes go through PRs. Inspect the remote tree and require
passing native/documentation Actions results for the exact pushed revision
before the owner authorizes public visibility. No release tag or installer is
published during source-only setup.

Configure Actions and require the `Tokenotch checks / test` and
`Documentation checks / docs` checks. Verify their actual check-context names and
source app in GitHub; workflow display labels are not necessarily API context
names. Keep Actions' default token permissions read-only and disable Actions
approval of PRs.

Use separate rulesets on the actual default branch:

- **Required checks and integrity:** require both CI contexts, a PR, resolved
  review discussions, and block force-pushes/deletion. Give this ruleset no
  maintainer bypass. Require the branch to be up to date before merging.
- **Code-owner review:** require one approval from the code owner and dismiss
  stale approvals. Keep `.github/CODEOWNERS` as `* @rottathiago`. Grant only the
  sole maintainer a PR-only bypass of this review ruleset for owner-authored
  changes. Record the exception in the PR; it is not a self-approval or a CI
  exception.

GitHub does not let authors approve their own PRs. Other contributors may review
but cannot replace the required code-owner approval. Keep the owner as the only
administrator/maintainer with merge authority. If the available bypass actor is
the repository-administrator role, verify its membership: adding another
administrator expands that exception. Inspect extra approval settings for
unattributed Copilot PRs so the solo-maintainer policy does not accidentally
require a second reviewer. Do not claim enforcement from CODEOWNERS alone.

Restrict version-tag creation and verify protections on the actual default
branch. Some repository-plan settings are unavailable while private; make any
plan upgrade or public-cutover setup explicit rather than claiming protection
from workflow YAML. No signing/release secrets go to PR workflows.
At public cutover, promptly apply and inspect the prepared protections before
announcement. Verify that an owner review exception cannot merge a PR with
failing required checks. Do not claim contributor-path testing without a
separate test identity.

GitHub private vulnerability reporting is available for public repositories.
Prepare its setup while private, then enable it and verify the report form and
maintainer notifications at public cutover, **before announcement or installer
publication**. Establish a verified interim private security route if immediate
enablement is not possible. Follow [SECURITY.md](../SECURITY.md); do not advertise
an unavailable channel as working.

Check README, support, policy and source links anonymously after cutover. Public
source can remain explicitly pre-release while binary acceptance is unfinished.

### Future update pipeline

This roadmap is **not implemented** and requires a separate go-ahead. The current
app only performs a manual release lookup and opens the official release page.

Use a pinned Sparkle 2 framework for verified installation, not a custom
app-replacement script. Wire SwiftPM, XcodeGen, the native bundler and smoke
executables consistently. Preserve framework symlinks, embed and sign nested
helpers correctly, and include dependency notices in the bundle and release
inventory. Any development-only signing exception must not weaken production
hardened runtime.

Ask once for consent to daily background checks while Tokenotch is running.
Keep download and installation user-initiated. Settings > About > Updates should
offer **Check for Updates** and **Update**, opening Sparkle's native confirmation
and progress dialog. Show an in-app update indicator plus optional macOS
notifications, respecting permission, managed mute, snooze and quiet hours.
Deduplicate release notifications across restarts and route clicks to Updates,
not session details. Reuse the notification-center delegate and do not run
competing update schedulers. No push server, closed-app polling, silent installs
or system-profile analytics are planned.

After Apple Developer enrollment and production acceptance, extend the release
workflow to accept protected stable version tags. Require exact-revision CI,
matching release metadata and increasing build numbers. Build a draft containing
the signed/notarized DMG and PKG, checksums, inventory and a Sparkle appcast
signed using a separate Ed25519 key. Only the public key belongs in source.
Reuse the final DMG as the update archive and use tag-specific download URLs.
The proposed stable feed is
`https://github.com/rottathiago/tokenotch/releases/latest/download/appcast.xml`;
verify its redirect/cache behavior with Sparkle before adopting it.

The owner must approve the exact signed draft before it becomes public/latest.
Publish the complete feed and artifacts together without rebuilding them.
Keep the signing environment usable by the sole owner, and never assume that a
release created by `GITHUB_TOKEN` will trigger another workflow. Retries must not
silently overwrite published artifacts. Withdraw defective updates and publish
a forward fix instead of forcing a downgrade into newer data.

Validate consent, notification routing, tampered downloads, incompatible systems,
installation failure, relaunch, retained data and client repair/reload behavior.
Exercise an older-to-newer signed update on Apple Silicon and Intel using an
explicitly approved test feed before customer rollout. Existing source-built
versions will need one manual installation of the first signed Sparkle-enabled
version; they cannot acquire an updater they do not contain.

### Signed artifact gate

Configure an approval-protected `release` environment and protected version
tags in the owned repository. The manually dispatched workflow uses immutable
action revisions, full Xcode 16.4, no PR secrets, and an ephemeral signing keychain.
Verify that the environment actually exists and enforces the intended approval;
merely naming it in YAML is not sufficient. Document who approves owner-triggered
releases without creating an impossible self-review requirement.

Environment variables: `TOKENOTCH_RELEASE_ACCEPTANCE`, `TOKENOTCH_SIGNING_IDENTITY`,
`TOKENOTCH_INSTALLER_IDENTITY`, `TOKENOTCH_TEAM_ID`.

Environment secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
`DEVELOPER_ID_INSTALLER_P12_BASE64`, `DEVELOPER_ID_INSTALLER_P12_PASSWORD`,
`NOTARY_API_KEY_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`.
Upload secrets through GitHub settings, never through source files or chat.
Signing material is removed in an always-run cleanup step.

Dispatch for the protected matching tag. The workflow creates only a **draft**
release. Download that exact artifact on clean standard-user Macs, verify
checksum, quarantined launch, installation, onboarding, upgrade/recovery, helper
operation, and both supported architectures. The owner must approve public
publication separately.

After approval, publish the draft as a stable release with both notarized
installers, their checksums, and the inventory. A user's **Check for Updates**
then compares that release's version and offers its official page; it does not
poll, download, or install automatically. Verify this from an older signed build
before announcing the release. For a first release with no older signed Tokenotch
build, record that limitation and the owner's approved update-test approach;
do not claim a production upgrade was tested when it was not.

If a release is defective, withdraw its download and publish clear affected
versions/limitations before preparing a corrected version. Do not force a
downgrade into newer storage or recommend deleting user data to repair an update.

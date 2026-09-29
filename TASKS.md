# Tokenotch release readiness

Tokenotch 1.0.0 is the independent Copilot-only macOS release target.
Public source and development CI are available. Regular unsigned DMG/PKG releases
are allowed; Developer ID signing and notarization are optional. Consult the
[official releases](https://github.com/rottathiago/tokenotch/releases) for download
availability and artifact status. In-app installation remains a separate milestone.
This is a readiness record, not certification of unrecorded acceptance.
The [feature reference](docs/features.md) describes implemented behavior and the
[compatibility matrix](docs/compatibility.md) distinguishes targets from acceptance.

## Current scope

The implementation includes local CLI and VS Code connections, observed activity
and usage, optional account quotas, independent notification/history/timeline/
notice consent, and manual release lookup.
Development packaging produces universal app/helper bundles and DMG/PKG
installers. The companion is sideloaded from the app, not published separately.

See [integration contracts](docs/tokenotch-integrations.md) for limitations. Both
local clients require real acceptance; VS Code Local lifecycle hooks and Agent
Host numeric usage are separate capabilities, not a claim of complete parity.
Synthetic fixtures and successful cross-builds do not establish support.

## Source-publication safeguards

- Review the prospective source tree and the preserved commit history for
  accidental secrets, private material, obsolete artifacts and attribution.
  Publish only selected Tokenotch refs, not inherited release tags.
- Verify rights to code and artwork, preserve the MIT notice, and resolve any
  remaining naming or distribution decisions.
- Prepare an actionable private security route and verify GitHub vulnerability
  reporting at public cutover.
- Verify branch/tag protections and native/documentation checks.
- Keep install/support/release links honest about what is actually available.

The public repository enforces a required-CI and branch-integrity ruleset,
owner-only version-tag creation and immutable version tags. While Tokenotch has a
single maintainer, no approving review is required; the owner merges PRs after
the required CI checks pass. Private
vulnerability reporting is enabled. These safeguards do not certify a stable
binary release.

## Nonblocking follow-up

Publish a Code of Conduct after choosing and verifying a private conduct-reporting
route. This is separate from security reporting and is not required for initial
public-source publication.

Sparkle-based updates and tag-triggered draft releases require a separate
implementation phase. The [future update roadmap](docs/releasing.md#future-update-pipeline)
records the intended behavior; the current app still checks releases manually
and cannot install an update.

## Public unsigned installers

Publish regular unsigned releases from the owned repository and a clean matching
version tag after required CI and installer checks pass. Keep release notes,
source revision, checksums, support routes and signing disclosures accurate.
The release workflow creates a regular draft; the owner reviews and publishes it
with only the DMG and PKG attached. The existing manual updater can offer that
regular release without Apple signing.

Apple credentials and the acceptance record below are not requirements for this
unsigned path. Do not imply that public availability or passing CI certifies
untested client, hardware, accessibility or security behavior.

## Broader acceptance and optional signed installers

`config/ReleaseAcceptance.json` intentionally keeps approvals false until
evidence is collected. It is required by the optional Developer ID release path,
not by unsigned publication. Keep recording real acceptance for the exact source
revision rather than turning flags on to satisfy a build.

- Record actual CLI, VS Code/Copilot extension, macOS and architecture versions.
  Accept required lifecycle delivery for both local clients and report optional
  Preview capabilities as available or explicitly unavailable.
- Accept native Apple Silicon and Intel behavior, minimum macOS and advertised
  newer combinations; a universal binary alone is insufficient.
- Exercise consent withdrawal, concurrent sessions, policy/workspace conflicts,
  app moves, recovery, updates and exact-owned uninstall.
- Accept notifications and their click targets, keyboard/VoiceOver, reduced
  motion/transparency, physical displays/notches and full-screen behavior.
- Measure performance, perform the separate security/privacy review and resolve
  ownership/licensing approval. Automated docs checks do not satisfy these gates.
- Configure owned Developer ID Application/Installer identities, notarization and
  an approval-protected release environment. Verify the exact signed draft
  installers on clean Macs before owner-authorized signed publication.

Use [the release runbook](docs/releasing.md) for ordering, evidence, required
artifacts and failure handling. No current implementation-machine observation
substitutes for the acceptance record.

## Outside 1.0.0

AI-credit billing/targets, full enterprise managed deployment, daily consumption
warnings, cloud-generated recaps, export, watched PRs, remote clients, other IDEs/
providers and Windows are deferred. Do not add them merely to satisfy language
in an old plan, reuse an inherited binary, or infer unavailable billing data.

## Historical proposals

The [original implementation plan](docs/plans/original-implementation.md) and
[AI insights exploration](docs/plans/2026-09-22-ai-insights-exploration.md) preserve
earlier proposals. Their source paths, dependencies, scope and assumptions may
be obsolete; they are not current build instructions or release commitments.

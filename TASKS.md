# Tokenotch release readiness

Tokenotch is preparing its independent Copilot-only macOS 1.0.0 release.
The current milestone is public source and development CI only; production
installers and in-app installation are not part of this milestone.
This is a readiness record, not certification that public-release gates passed.
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

## Required before public source publication

- Review the prospective source tree and the preserved commit history for
  accidental secrets, private material, obsolete artifacts and attribution.
  Publish only selected Tokenotch refs, not inherited release tags.
- Verify rights to code and artwork, preserve the MIT notice, and resolve any
  remaining naming or distribution decisions.
- Prepare an actionable private security route and verify GitHub vulnerability
  reporting at public cutover.
- Verify branch/tag protections, native/documentation checks, contributor review
  and an explicit auditable process for owner-authored changes.
- Keep install/support/release links honest about what is actually available.

## Nonblocking follow-up

Publish a Code of Conduct after choosing and verifying a private conduct-reporting
route. This is separate from security reporting and is not required for initial
public-source publication.

Sparkle-based updates and tag-triggered draft releases require a separate
implementation phase. The [future update roadmap](docs/releasing.md#future-update-pipeline)
records the intended behavior; the current app still checks releases manually
and cannot install an update.

## Required before stable installers

`config/ReleaseAcceptance.json` intentionally keeps approvals false until
evidence is collected. The owner must approve an external acceptance record
for the exact committed revision being tagged.

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
  installers on clean Macs before owner-authorized stable publication.

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

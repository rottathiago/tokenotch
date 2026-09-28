# Tokenotch: Copilot-only enterprise desktop companion

> Historical planning snapshot, recovered for implementation on September 20, 2026.
> Archived without changing its original proposals. Its product scope, source
> paths, dependencies and release requirements are not current instructions.
> See [release readiness](../../TASKS.md), [current features](../features.md)
> and [the release runbook](../releasing.md) instead. This is not a shipping claim.

## Purpose and approval boundary

Build **Tokenotch**, a lightweight, private desktop companion for developers using GitHub Copilot Enterprise. Its promise is: **A quiet signal for your Copilot work.**

Keep the ambient notch/menu-bar experience and useful shared infrastructure. Remove integrations with competing standalone coding products and local model runtimes. Add trustworthy Copilot activity, developer-controlled usage alerts, health information, and enterprise distribution controls.

This is a historical implementation plan. Microsoft/GitHub sponsorship, product acceptance, API access, brand clearance, and distribution approval are not established by this plan.

## Confirmed decisions

| Topic | Decision |
| --- | --- |
| Working name | Tokenotch; subtitle: "A desktop companion for GitHub Copilot"; tagline: "A quiet signal for your Copilot work." |
| Platform | macOS first; Windows as a later, separately validated release. |
| Initial activity coverage | Both Copilot CLI and VS Code on the local Mac are required. |
| Remote coverage | Remote SSH, containers, WSL, Codespaces, cloud execution, other IDEs, and remote forwarding are later work. |
| Product boundary | GitHub Copilot only. Models offered inside Copilot remain valid regardless of model vendor. |
| Phone | Remove pairing, server, permissions, UI, protocol artifacts, and related dependencies where no longer needed. |
| Usage availability | An explicitly limited activity/health pilot may ship without automated usage access, linking to GitHub's usage settings instead. Do not invent usage or use an unapproved private-API workaround. |
| VS Code hooks | Preview hooks may be used in a clearly labeled pilot. Customer distribution requires integration approval. |
| Default notifications | After explicit opt-in, desktop finished/failure notifications enabled where reliably supported; sound and automatic notch expansion disabled. |
| Personal targets | Optional; no invented starting allowance. Once enabled, default warning thresholds are 80%, 95%, and 100%. |

## Current state and evidence

The inspected Git worktree was clean. Existing source uses Swift/SwiftUI/AppKit and XcodeGen; `project.yml` sets macOS 15 as the deployment target. README badges and CI comments contain conflicting platform wording, which must be reconciled against an actual supported-platform build matrix.

| Surface | Current implementation | Consequence |
| --- | --- | --- |
| App composition | `Sources/App/AppDelegate.swift` discovers profiles, constructs many providers and activity monitors, starts local runtime collectors, assembles phone services, and connects notification paths. | Removing provider files alone will not compile or produce a Copilot-only app; startup and publisher bindings must be simplified together. |
| Copilot usage | `Sources/Providers/GitHubCopilotProvider.swift` calls `/copilot_internal/user`, prioritizes `premium_interactions`, borrows environment/`gh` credentials, and groups 401/403 as needs-auth. | Current integration is not a proven approved enterprise usage contract. Billing units, account identity, authorization errors, and client compatibility need revalidation. |
| Copilot tests | `Tests/GitHubCopilotTests.swift` exercises legacy quota fixtures and credential discovery. | Add approved-contract fixtures, fractional credit handling, explicit identity checks, missing-field cases, and status mapping tests. |
| Usage storage | `Sources/Model/UsageStore.swift`, `UsageArchive.swift`, and `UsageModel.swift` provide scheduling, stale readings, cancellation/generation guards, and persistent last-good readings. They also contain non-Copilot fields and assumptions. | Preserve useful lifecycle behavior while removing foreign-provider state and separating freshness from authentication/access health. |
| Activity | `Sources/Sessions/ActivityCoordinator.swift`, `AgentActivityMonitor.swift`, and `AgentSession.swift` provide reusable coordination; no Copilot activity monitor is registered. | Add real CLI/VS Code adapters, not a renamed Claude/Codex monitor. |
| Completion semantics | `SessionCompletionWatcher.swift` currently treats busy-to-idle as finished; `AgentSession.State` has busy/waiting/success/idle but no failed/cancelled/unknown. | Explicit Copilot events and missing-observation handling must replace this assumption. |
| Alerts | `ThresholdNotifier.swift` hard-codes 80/100 thresholds and keeps crossing state only in memory. Reset and limit watchers have separate delivery paths in `AppDelegate`. | Build one persistent decision/delivery path; snooze and mute must cover every channel. Do not assume restart deduplication already exists. |
| Preferences | `Sources/Settings/Preferences.swift` already has notification sounds, peek controls, provider mutes, and appearance settings; fresh installs default to Claude/Codex. | Preserve ergonomic controls, replace multi-provider settings, and implement explicit Tokenotch defaults. |
| Presentation | `Sources/Notch/`, `Features/TooltipCard.swift`, `ProviderRing.swift`, and `App/StatusItemSummary.swift` contain provider-specific branches and five-hour-window assumptions. | Copilot monthly usage and account status must work in the notch and menu bar, not just Settings. |
| Focus | `SessionFocus.swift` and `TerminalTabFocus.swift` support app activation and some terminal tab selection. | Reuse safe generic behavior; exact session navigation is conditional, not guaranteed. |
| Dependencies | `project.yml` includes Sparkle and SwiftNIO; the bridging header exposes vendored zstd for Claude Desktop cache decoding. | Remove zstd and the bridge with Claude cache support. Remove SwiftNIO if its phone/Ollama consumers are gone and the native hook bridge needs no package. |
| Distribution | The original bundle IDs, signing settings, update feed/key, scripts, workflow repository guards, README links, and download artifacts belonged to the upstream product. | Never ship Tokenotch with upstream signing/update identities or the old binary. Establish an independent release channel. |
| Windows | `windows/` contains an independent Rust/Tauri app, a Claude hook helper, and provider tests; its README does not list Copilot support. | This is not a ready Copilot Windows port. Suspend inherited release publishing in the fork and plan a later conversion. |
| License | `LICENSE` is MIT with an upstream copyright notice. | Preserve required attribution; renaming does not transfer trademark rights or remove notice obligations. |

## Product and naming

### Brand direction

Use **Tokenotch** as the working name, not yet a legally cleared release name. It is short, suggests a small useful signal, and works beyond a screen-edge notch.

- Product: Tokenotch.
- Descriptive subtitle: A desktop companion for GitHub Copilot.
- Tagline: A quiet signal for your Copilot work.
- Positioning: For enterprise developers who want to know when Copilot needs attention and how their usage is progressing, Tokenotch provides private, ambient status without becoming a management dashboard.
- Voice: calm, concrete, actionable. Prefer "Agent execution stopped" over "Task succeeded" unless success is explicitly established.
- Visual direction: retain the compact native surface, with a distinct app icon and accessible non-color state cues. Do not clone Microsoft/GitHub identity or imply official endorsement.

Shortlist retained for clearance fallback: **Sideglow** (ambient and distinctive), **Beacon** (clear attention metaphor, broad existing usage). The user selected Tokenotch. No name, domain, package, marketplace, or trademark availability claim has been made.

Before publishing, check name collisions and trademark eligibility, extension/publisher identifiers, bundle-ID ownership, domains, and logo/subtitle use with the appropriate brand/legal owners. Reserve final identifiers only after clearance.

### Release tiers

### Limited macOS pilot

- Copilot-only app, local CLI and local VS Code activity integration, honest capability indicators.
- Notification opt-in, per-event/channel controls, snooze, quiet hours, click-to-open where supported.
- Copilot service health and redacted diagnostics.
- Explicit "Usage integration unavailable" state with a link to GitHub usage settings if approved automatic access is unavailable.
- No functioning-looking budget alert controls when consumption is unavailable.
- Preview integration label, supported client-version matrix, no claim of Microsoft distribution readiness.

### Customer-ready macOS release

- All pilot requirements plus approved integration/authentication paths, automated personal usage and target alerts, verified identity handling, managed configuration, signed/notarized packaging, owned update channel, privacy and support documentation, and distribution sign-off.
- Both CLI and VS Code must pass the tested support matrix. If VS Code cannot meet its minimum observation contract, that release is blocked rather than silently reduced to CLI-only.
- Unsupported events, account configurations, or IDE environments remain explicit. Parity does not mean fabricating missing capabilities.

### Later extensions

- Local usage history, daily observed-usage warnings, opt-in recap and snapshot export.
- Explicitly watched GitHub PR/review/check notifications.
- Remote environments, other IDEs, and Windows.
- These are included in the roadmap, not silently bundled into the first release.

## Integration feasibility gates

### Copilot usage and authentication

Establish with GitHub which interface and authentication flow are approved for this third-party/customer-distributed product. Record endpoint ownership, scopes, supported account/host types, fields, units, reporting latency, rate limits, versioning, and revocation behavior. Visibility of data on a GitHub page does not prove there is an approved API.

Current documentation describes enterprise AI credits, pooled included amounts, and optional user-level budgets. Do not derive a personal cap from per-seat included credits, treat a pooled enterprise balance as personal remaining allowance, or convert legacy premium requests into AI credits.

Implementation rules:

- Require explicitly selected, verified identity. A username in `gh` configuration must not label a different environment token's readings.
- Avoid silent environment-token precedence and reading client credential databases. The supported sign-in flow is a gate, not an assumed OAuth scope grant.
- Preserve `gh` only as an explicitly selected optional connection method if its token type/scopes are approved; the product must not require `gh` installation.
- Keep Copilot CLI, VS Code, and monitor account identities separate until a supported signal links them. Unknown client identity is not a match.
- Validate GitHub Enterprise Cloud, enterprise-managed users, and SSO/policy restrictions before claiming support. Enterprise Server and alternate hosts are not automatically supported.
- Separate expired/revoked authentication, access forbidden/policy restriction, rate limiting, service failure, offline, and unknown-cause errors.
- Retain read-only last-good data with observation age; clear/isolate it on account change.
- Do not request enterprise metrics/billing administration permissions for core developer features. Daily enterprise reports are not live personal telemetry.
- Disable/remove the old private endpoint in the customer product unless GitHub explicitly approves it and the actual payload matches the supported contract.

### CLI and VS Code event contracts

Use documented hooks for the installed, tested client versions. CLI and VS Code event names/configuration differ; implement separate adapters into one small internal event schema.

- CLI candidates include `sessionStart`, `userPromptSubmitted`, `agentStop`, `sessionEnd`, `errorOccurred`, and subagent events where supported. Verify payloads and event meaning rather than assuming availability from documentation alone.
- VS Code exposes Preview hooks including `SessionStart`, `UserPromptSubmit`, `SubagentStart`, `SubagentStop`, and `Stop`. `Stop` means execution stopped, not that the task succeeded or the whole session ended.
- Do not derive "waiting for approval" from `PreToolUse`, an elapsed timer, or lack of events. Offer it only when an approved explicit signal exists.
- Do not report every tool error as final task failure. Distinguish recoverable tool errors, terminal failures, cancellation, and unknown/disconnected state.
- Hooks may be blocked by enterprise policy; VS Code workspace hooks may override user hooks. Detect/explain missing coverage through an explicit integration test/status, not by changing policy.
- Remote hooks execute in a remote extension host; those events are out of scope for the local pilot. Do not forward over a new network service as a workaround.
- Minimum pilot contract per client: validate running/start and execution-stop events, client/source identity, a missing-integration state, and safe focus behavior. Failure/waiting notifications remain capability-gated where unobservable.
- Establish whether a thin VS Code extension is needed for onboarding, integration diagnostics, and workspace focus using public APIs. An extension is not presumed to have access to built-in Copilot chat internals.
- No DOM scraping, private extension storage/log scraping, monkey-patching, prompt wrapping, or synthetic inference to discover status.

Record the resulting capability matrix before presenting notifications as supported.

## Architecture and implementation approach

Keep the native macOS app and existing test runner. Avoid a new backend, a provider/plugin marketplace, a database server, or a broad rewrite. Preserve small generic interfaces that already support testing; simplify unused multi-provider abstractions rather than growing them.

### Shared state

Adapt `UsageModel`, `UsageStore`, `UsageArchive`, and session models to represent:

- A verified account key containing host and stable account identifier.
- Usage amount and unit, cycle identity/boundaries, optional authoritative user budget, optional personal target, source provenance, observation time, and freshness.
- AI-credit values without integer truncation; use decimal-safe quantities for budgets and comparisons.
- An explicit unavailable value, distinct from zero, unmetered, or no personal cap.
- Activity source (CLI or VS Code), opaque instance/session/turn identifiers, normalized event, timestamp, sequence/deduplication identity, and capability set.
- Session states that distinguish working, execution stopped, confirmed failure, explicit waiting, cancellation, and observation unavailable. Labels must reflect evidence.

Do not couple local session counts to account-wide billed usage. Activity on another device can consume credits while this Mac is idle; idle polling remains a lower-frequency refresh, not a claim that usage cannot change.

### Local event bridge

Proposed macOS design: a small signed native helper receives hook JSON through stdin, strips content, and sends an allowlisted event to the app over a per-user Unix-domain socket. Prefer native facilities over retaining SwiftNIO solely for this bridge.

- Keep the socket in an owner-only application directory; validate peer ownership, schema, event size/rate, and source registration. Treat same-user inputs as untrusted, not as proof of billing identity.
- Never persist or forward prompts, tool arguments, responses, transcript paths, command text, or arbitrary environment data.
- Use opaque workspace IDs. Store display aliases only locally and optionally; keep full paths out of logs and notification previews by default.
- The helper must be bounded, fast, and non-interfering: no approval decisions, no context injection, no changing commands, no remote requests, and no retries that hold up the agent.
- If the app is unavailable, do not launch inference or block the client. Record only a sanitized bridge-health failure where safe and surface disconnected status when the app next runs.
- Install a uniquely owned hook file only after consent, honor `COPILOT_HOME` and supported VS Code locations, and leave other user/workspace/admin hooks untouched.
- Test coexistence where both clients load the same user hook directory; do not double-register or double-notify. Use versioned per-client config only where supported.
- Helper paths must survive app moves/updates through a documented install mechanism. Uninstall removes only Tokenotch-owned artifacts.
- Add a minimal companion VS Code extension only if the feasibility gate establishes it is needed. Use public APIs, Workspace Trust, scoped consent, and no hidden network listener.

### Central notification pipeline

Introduce a small `Notifications` component with a pure policy/threshold evaluator, persistent deduplication state, and macOS delivery adapter. Migrate existing threshold, reset, limit, chime, and automatic-peek paths behind it.

Evaluation order:

1. Normalize and validate the source event or fresh usage observation.
2. Establish account/cycle/session identity and whether this is a new event.
3. Apply managed restrictions, user category/target settings, and channel preferences.
4. Apply snooze and quiet hours.
5. Deliver selected channels without double-playing sounds.
6. Record delivery/suppression state and sanitized errors.

Suppressions advance observation state so unsnoozing does not replay a backlog. Source-side deduplication remains separate from OS delivery outcomes. Permission denial or a delivery error must be visible in Settings without retry storms or success-shaped status.

### Usage targets and notification semantics

- Targets are advisory preferences; never enforce or promise billing caps.
- Offer target basis: personal monthly AI-credit target or a verified enterprise user budget. Show those as distinct amounts; do not choose a denominator silently.
- Personal target is disabled until set. Show "Enterprise user budget unavailable" when unknown, not "Unlimited."
- Default enabled-target thresholds: 80%, 95%, 100%; allow a short validated list of distinct percentages in (0, 100].
- Validate positive finite targets, decimal precision, sorted unique thresholds, and meaningful error messages.
- Persist threshold state by account, unit, authoritative cycle, target basis, and rule identity. A correction downward within a cycle does not rearm a consumed threshold.
- Seed the first observation without notifications. App startup, reconnect, new target creation, or editing a target must not manufacture historical crossings.
- Coalesce a jump across several thresholds into one highest-severity alert.
- Reset tracking only with verified new-cycle evidence. Do not infer a reset solely from a countdown reaching zero or a correction in usage.
- Stale/restored readings remain visible but cannot generate a new budget crossing.
- A 100% personal-target crossing says "Personal target reached," not "Copilot blocked."
- Paid overage, enterprise budget exhaustion, and entitlement state are shown only if explicitly supplied by the approved interface.

### Settings and UX

Replace provider-heavy Settings with:

| Section | Controls |
| --- | --- |
| Account & Connections | Explicit account selection, verified identity, connection health, CLI/VS Code install/test/remove, supported capabilities, source freshness. |
| Usage & Targets | Personal target, verified enterprise budget if available, threshold editor, usage source/time, link to GitHub usage/budget-request UI. |
| Notifications | Master switch; finished/stopped, failure, waiting where supported, usage, reset, service incident and recovery toggles; independent desktop/sound/notch controls; test notification. |
| Quiet Time | Snooze presets, resume action, quiet-hour start/end, time-zone semantics, optional explicit waiting-event exception; no exception to a master mute. |
| Appearance | Preserve edge/size/display/menu-bar/accessibility controls; optional global reveal shortcut and keyboard navigation. |
| Privacy & Diagnostics | Collected-fields explanation, retention controls, clear local history, preview/copy redacted diagnostics, integration limitations. |
| General | Launch at login, app version, managed-setting indicators, approved update controls, uninstall integration instructions. |

Quiet hours follow the current system time zone and must handle overnight ranges and daylight-saving transitions. Snooze persists as an absolute expiry across restarts. Neither pauses usage/activity monitoring.

Visual behavior:

- One Copilot identity/status surface, with a list of monitored CLI/VS Code sessions rather than provider rings.
- Usage view shows credit totals or a trustworthy target fraction; absent denominators never produce 0% rings.
- Separate service incidents, account errors, and local integration disconnects.
- Clicking an event opens the verified client/workspace where supported. Otherwise label the action "Open VS Code" or "Open terminal"; do not claim an exact session jump.
- Preserve multi-display layout, full-screen behavior, VoiceOver, reduced motion/transparency, keyboard access, and localization.
- Default notification text omits repository names and paths; an optional local alias can improve usefulness without leaking project details in lock-screen previews.

## Removal, migration, and rebranding

Remove from the active macOS product:

- All non-Copilot provider implementations, discovery, credential access, OAuth refreshers, web sessions, and provider-only supporting types.
- Claude/Codex/Cursor/other activity monitors, transcript parsers, local-model collectors, Ollama relay, LM Studio sockets/log readers, and foreign-provider performance/history UI.
- `Sources/PhoneLink`, phone Settings/menu entries, startup/shutdown bindings, pairing secret handling, local-network usage description, `PHONE-LINK-V3.md`, `phone-link-v3-vectors.json`, phone protocol docs, and phone-only tests.
- Claude Desktop zstd decoder and its bridging header, with corresponding XcodeGen build settings.
- Unreferenced provider-specific assets, catalog keys, fixtures, tests, scripts, dependencies and transitive lockfile entries. Do not delete generic geometry/focus/notification tests merely because they use old provider fixtures; convert them.
- Upstream download artifacts and release feed/configuration from Tokenotch publication.

Simplify all connected surfaces together: `AppDelegate`, `UsageStore`/archive/model, `Preferences`, Settings window/view, tooltip/layout/ring code, menu-bar summary and menus, demo fixtures, release notes, localization, and tests. Remove five-hour/Claude-default assumptions.

Identity and migration:

- Use a separately owned bundle ID, preferences domain, application-support directory, keychain service, log subsystem, extension ID, and release channel after naming approval.
- Do not inherit another product's signing team, update key, feed, notary profile, or publish destination.
- Do not automatically replace another product or import its tokens/provider archives. Prefer a clean first launch; optional import is limited to explicitly chosen appearance preferences.
- Preserve upstream license/copyright notices and required third-party acknowledgments; do not erase repository history.
- Do not modify or delete another app's credentials, user hooks, or installed app. Legacy Tokenotch migration cleanup must target only proven app-owned records.
- Historical upstream docs can remain clearly labeled history, excluded from customer documentation. Current README, contribution guide, screenshots, support links, issue templates, and release notes must describe Tokenotch.

For Windows, keep the existing source explicitly marked legacy/reference-only until the later port, excluded from Tokenotch artifacts and automatic publishing. Remove/disable inherited Windows release triggers immediately in the fork. Before the Windows release, remove all non-Copilot integrations from that platform too; do not distribute the legacy binary under the new name.

## Enterprise distribution and operations

- macOS signed, hardened, notarized app; owned Sparkle feed/signing keys and trusted release artifacts. Verify Intel/Apple Silicon and actual minimum OS support.
- Signed managed-deployment package where required; installation must not need an admin token for ordinary app use.
- Managed configuration for allowed connections/features, update channel/mode, notification restrictions, diagnostic/export availability, retention, and optional managed defaults.
- Precedence: managed restrictions override user settings; never alter the customer's GitHub enterprise policy or install mandatory hooks into administrator policy directories.
- Support managed/manual updates without starting Sparkle polling before policy is loaded. Show managed choices as locked with explanation.
- Signed update verification, controlled channel rollout, documented rollback/downgrade handling, and coexistence/uninstall tests.
- Rework CI repository guards and inherited release scripts; test jobs use read-only permissions, publish jobs use scoped rights and protected approvals. Customer release artifacts require passing checks.
- No telemetry/backend in the initial product. Never label a local-only app "no network": approved GitHub usage, public status, authentication, and update requests still need a documented host allowlist.
- Corporate proxy/TLS behavior, SSO expiration, network denial, and restricted hooks must have documented user-facing states.
- Produce privacy/data-flow documentation, support runbook, license/dependency inventory and SBOM, and required security/accessibility/brand reviews before customer distribution.
- Microsoft distribution and GitHub integration approval are external gates with named owning teams to be established; passing local tests is not a substitute.

## Deferred features from the discussion

These features remain explicitly planned, but do not expand the initial implementation:

| Feature | Later bounded implementation |
| --- | --- |
| Short usage history | Opt-in local, capped retention of successful aggregate readings; start with a 24-hour sparkline. Mark gaps/corrections/resets; no prompt or response capture. |
| Daily observed-usage alerts | Enable only with a reliable source/aggregation contract. Account for delayed reporting, midnight boundaries and device changes; label observed deltas rather than exact real-time spend. |
| Private recap | Counts of observed sessions/events only, opt-in and local; no productivity score, team leaderboard, or "hours saved." |
| Snapshot export | Opt-in versioned local JSON with source/freshness and approved aggregate fields; owner-only permissions, atomic writes, no tokens/paths, no new HTTP service. |
| PR/review/check notifications | Explicit user watchlist, minimal GitHub permissions, bounded polling and deduplication. GitHub events are not proof of a particular agent's authorship. |
| Models/policies | Show only officially exposed availability/restrictions. No model recommendation based on invented prices, no automatic switching, no policy-management dashboard. |
| Multiple accounts | Explicit account switching and isolation first; concurrent multi-account views only after authentication and attribution support are validated. |
| Remote environments | Separate approved transport/identity design. No reuse of removed phone/LAN service as an implicit workaround. |
| Windows | Reuse compatible event schemas and pure-policy fixtures, adapt Rust/Tauri shell, add Copilot/auth/notification integrations, managed settings, signed installer and updater. |

## Ordered implementation todos

Statuses/dependencies are tracked in session SQL; the descriptions below are the human-readable source of truth. No schedule estimates are implied.

| ID | Todo and principal files/components | Completion condition |
| --- | --- | --- |
| integration-contracts | Validate approved usage/authentication and per-version CLI/VS Code hooks; record capability and support matrix. | Client fixtures and pilot/customer gates are explicit; missing interfaces are documented blockers, not guessed implementations. |
| tokenotch-identity | Clear working name; select owned bundle/publisher/release identifiers; plan independent signing and update migration. Touch `project.yml`, `Makefile`, app entry/logging, scripts, assets, docs, workflows when approved. | No customer artifact points at upstream release/signing identities; required attribution preserved. |
| copilot-only-core | Remove non-Copilot/phone startup, models, UI, tests/assets/dependencies; simplify `AppDelegate`, `Preferences`, store/archive and presentation; isolate legacy Windows. | A buildable Copilot-only shell with synthetic fixtures, zero non-Copilot credential reads or phone listener, existing native UX preserved. |
| copilot-usage-auth | Implement approved sign-in/identity, credit model, error mapping, freshness/cache/backoff, and pilot unavailable state in `Sources/Providers`, `Model`, Settings. | Verified account isolation; no private endpoint fallback; usable limited pilot or approved automatic usage with contract tests. |
| notification-policy | Replace parallel alert paths with pure target/event rules and persistent deduplication/delivery policy. | Threshold and session semantics pass edge-case tests; every channel obeys master mute/snooze/quiet hours. |
| local-event-bridge | Implement bounded native helper/IPC, install/uninstall ownership and normalized event protocol; update XcodeGen targets. | Sanitized events flow locally with no retained content and no changes to Copilot approval behavior. |
| cli-activity | Implement `CopilotCLIActivityMonitor` and versioned hook config/diagnostics using the bridge. | Local CLI running/stopped contract demonstrated; supported errors/wait states accurate; disconnects never reported as success. |
| vscode-activity | Implement `VSCodeActivityMonitor`, Preview hook setup and, only if needed, a thin public-API extension under a dedicated extension directory. | Local VS Code minimum contract passes, policy/version gaps explained, no private Copilot extension API dependency. |
| tokenotch-settings-ux | Build Account/Usage/Notifications/Quiet Time/Privacy settings and Tokenotch notch/menu surfaces; keyboard navigation, test alerts, focus actions, localization. | Confirmed defaults persist; absent capabilities are explained; VoiceOver/non-color states work. |
| health-diagnostics | Implement public Copilot incident monitoring, source freshness, integration diagnostics and allowlisted report preview/copy. | Incident/recovery deduplication, offline versus outage distinction, zero sensitive fields in diagnostics. |
| pilot-validation | Run shared/unit and CLI/VS Code integration checks; validate consent, uninstall and clean-profile behavior; prepare limited-pilot docs. | Both clients meet the matrix; usage limitations/Preview label visible; no unsupported feature advertised as working. |
| enterprise-release | Implement managed configuration, owned signed/notarized release, update policy, CI gates and customer support/privacy/compliance artifacts. | Approved interfaces, automatic usage targets, distribution approvals and platform acceptance tests all pass. |
| developer-extras | Add bounded history/daily observed warnings, recap, export and watched-PR events independently after their capability checks. | Each is opt-in, private by default, tested, and disableable without affecting core monitoring. |
| windows-port | Convert the existing Windows shell to Copilot-only Tokenotch after the macOS contracts settle; remove legacy integrations and rebrand/release independently. | Windows parity and enterprise deployment validated; no inherited non-Copilot helper or unsigned customer installer. |

Dependency outline:

- Identity and integration discovery can proceed independently.
- Core cleanup follows discovery and identity decisions.
- Usage/auth and local bridge follow core cleanup and their discovery contracts.
- Notification policy follows the normalized core model; it can be built against synthetic fixtures without waiting for a live usage interface.
- CLI and VS Code adapters depend on the bridge; each is separately testable.
- Final settings integration depends on usage state, policy engine, and both activity adapters.
- Health/diagnostics follow the core; pilot validation depends on all pilot components.
- Customer release depends on pilot validation plus approval gates; extras and Windows follow stable macOS contracts.

## Validation and acceptance

Use existing `make test`/`make test-ci` and `Scripts/test-signing.sh`, updating scheme names with the approved rename. Run targeted XCTest classes during implementation and the full suite for the broad removal/release changes. Preserve `Runtime.isUnderTest` so tests never read live credentials or start services. Add extension tests/tooling only if an extension is actually introduced.

| Area | Required cases |
| --- | --- |
| Removal | Fresh launch cannot read non-Copilot credential directories or start phone/local-model services. No non-Copilot product options/assets in shipped UI. No inherited Windows or upstream binary published. |
| Account identity | Environment/CLI/IDE mismatch, unknown client identity, account switch, sign-out, stale response arriving after switch, policy denial and revoked auth. No cross-account readings or alerts. |
| Usage contract | Fractional credits; unknown consumption; no user budget; actual zero cap; delayed observation; pooled versus personal quantities; legacy units; malformed/non-finite data; source/version mismatch. |
| Target rules | Exact boundary, leap over several thresholds, lowering/editing target, correction downward, stale restore, restart, cycle change, absent reset metadata, per-account isolation. |
| Notifications | Master/category/channel off; permission denial; delivery error; snooze persistence/expiry; quiet hours across midnight/DST; no backlog; one sound; target crossing never claims access blocked. |
| CLI/VS Code | Concurrent sessions, nested agents, duplicate/out-of-order events, CLI inside VS Code, stopped versus success, recoverable versus terminal failure, cancellation, client/app crash, missing hooks, policy-disabled hooks and unsupported version. |
| Hook installation | Existing user/workspace/admin hooks remain intact; workspace precedence explained; config directory override; app relocation; update; consent withdrawal and exact-owned-file uninstall. |
| Bridge | App absent, malformed/oversized messages, unknown version, untrusted peer, event flood, path/symlink hazards, no transcript/prompt/response persistence, no approval output. |
| Health | Relevant Copilot component incidents only, repeated updates, incident resolution, unavailable feed, network/proxy failure, local auth failure without blaming a global incident. |
| UI | Single-Copilot monthly readout, unavailable states, keyboard navigation, accessibility/reduced motion/transparency, localization formatting, edge/multi-display/full-screen behavior and accurate focus labels. |
| Operations | Managed preferences applied before startup; no forbidden polling; owned feed/signature; invalid update rejected; install/uninstall/upgrade; clean-machine use without `gh`; documented macOS/architecture coverage. |
| Resource use | Idle app remains event-driven for activity, no continuous process-tree scans, bounded queues/history and retries, backoff respected by manual refresh. Measure helper overhead and idle CPU/memory before pilot acceptance. |

Release gates cannot be bypassed by substituting demo data, reporting unknown as zero, displaying a manual target as actual consumption, or scraping private client storage. If a capability cannot be validated, expose a clear unavailable state for the pilot and keep the corresponding customer-release requirement open.

## Sources and unresolved external decisions

Public documentation consulted during planning:

- GitHub Copilot hooks: <https://docs.github.com/en/copilot/reference/hooks-reference>
- VS Code hooks and Preview/policy/remote limitations: <https://code.visualstudio.com/docs/agent-customization/hooks>
- VS Code hook event semantics, including `Stop`: <https://code.visualstudio.com/docs/agents/reference/hooks-reference>
- VS Code public extension capabilities: <https://code.visualstudio.com/api/extension-capabilities/common-capabilities>
- Enterprise AI-credit model: <https://docs.github.com/en/copilot/concepts/billing-and-usage/organizations-and-enterprises/billing>
- Personal usage visibility: <https://docs.github.com/en/copilot/how-tos/manage-and-track-spending/monitor-ai-usage>
- Enterprise metrics permissions/report cadence: <https://docs.github.com/en/enterprise-cloud@latest/rest/copilot/copilot-usage-metrics>
- GitHub public status API: <https://www.githubstatus.com/api>

Documentation is not a substitute for versioned integration tests or permission to redistribute an integration. Remaining external gates: Tokenotch name/brand clearance; owning publisher/signing identities and update infrastructure; approved usage/auth contract; VS Code Preview suitability for the distribution channel; actual customer identity/network configurations; Microsoft/GitHub distribution and support ownership.

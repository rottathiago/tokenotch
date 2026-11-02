# Claude Code for Tokenotch on macOS

Prepared: 2026-10-30.
Scope update, November 2: this plan's Desktop proposals were withdrawn. Current
support is Claude Code CLI only, plus official CLI account login/status and
separately enabled status-line quota reporting. Desktop references below are
historical design context, not active features or release requirements.

Status: foundation, owned CLI collection, optional local Desktop Code-tab
collection, provider UI and recording isolation are implemented with synthetic
checks. Desktop requires a matching installation resource marker and separate
setup opt-in. Lifecycle and real-client release acceptance remain gated. See the
[foundation contract](../claude-code-contract.md) for evidence and downgrade limits.
An approved CLI-only retest accepted numeric API calls on 2.1.212, including
reported request/session identity, cache counts and estimated cost. Replay,
resume, handoff and Desktop remain unchecked.

For current worktree state, validation limits, and the next implementation slice,
start with the [implementation handoff](2026-10-30-claude-code-handoff.md).

## Goal and scope

Add Claude Code to the macOS application without changing existing Copilot
accounting, connections, consent, or saved observations. Use separate provider
logos in the notch and shared Settings pages with provider-scoped data.

The first release targets Copilot CLI, Copilot in local VS Code, Claude Code
CLI, and local sessions in Claude Desktop's **Code** tab. Claude support must be
verified independently for the CLI and Desktop; documentation alone is not
release acceptance.

Windows implementation, ordinary Claude chat, Cowork, Claude's VS Code extension,
SDK applications, cloud/SSH sessions, account-profile discovery, transcript
imports, and Claude subscription-quota collection are outside this first release.
Do not borrow credentials or private Desktop caches to fill capability gaps.

## Agreed user experience

| Area | Behavior |
| --- | --- |
| Notch | Separate Copilot and Claude Code logo cells. Each opens its own summary and provider-scoped links. |
| Usage | One page, with All providers / GitHub Copilot / Claude Code selection and a dependent client filter. |
| History | One page using the same provider/client selection. All providers shows separately labeled provider series, not an unexplained combined chart. |
| Sessions | One page with provider/client filters and explicit distinctions between observed calls and reported lifecycle state. |
| Connections | Provider sections containing client-specific setup, removal, capability, and delivery status. |
| App preferences | Shared Appearance, Notifications, Privacy, and About pages; provider-specific controls only where behavior differs. |

Keep the current black notch surface, type scale, token-category colors, and
status colors. Use recognizable monochrome provider marks rather than making
warning colors double as provider identities. Verify the Claude asset's source,
distribution rights, attribution, and small-size rendering before bundling it.
The upstream MIT-licensed app credited in [LICENSE](../../LICENSE) is a visual reference, not a
requirement to copy its collection methods or account-limit semantics.

Show only providers selected for notch visibility and preserve a stable order.
Initially use Copilot then Claude Code; no automatic reordering or drag editor
is required. Hiding a cell does not disconnect collection.

Hide redundant provider controls when only one provider is relevant. Retained
history still makes a disconnected provider relevant to History. Opening a
provider's card or History link carries that provider into Settings. Preserve
the selected period; reset an incompatible client or model filter explicitly.

Provider selection scopes analytics, not application-wide preferences or which
connections are visible. Default the two-provider overview to All providers.
Single-provider users retain the familiar Copilot experience.

## Capability and collection contract

The following official documentation was reviewed on 2026-10-30:

- [Claude monitoring](https://code.claude.com/docs/en/monitoring-usage),
  particularly API request events, service information, and token accounting.
- [Claude Desktop](https://code.claude.com/docs/en/desktop), particularly local
  environment variables, shared settings, and CLI-to-Desktop session handoff.
- [Claude hooks](https://code.claude.com/docs/en/hooks), particularly lifecycle
  events, common input fields, and non-interfering command hooks.

| Capability | First-release treatment |
| --- | --- |
| Model, input/output tokens, cache reads/writes, call duration | Collect from documented `claude_code.api_request` OTel log events. |
| Estimated cost | Optional reported field, labeled estimated cost, not subscription spend or remaining allowance. |
| CLI versus Desktop | Validate producer metadata: `claude-code` with CLI entrypoint versus local `claude-code-desktop`. |
| Session identity | Use reported `session.id`; missing identity means unlinked calls, not an invented shared session. |
| Working, turn stopped, session ended | Independent hook capability, enabled only after its mapping and delivery pass acceptance. |
| Attention and error notices | Enable only documented, verified hook events; do not infer them from token usage. |
| Context occupancy and compaction | Deferred unless a separately reviewed numeric-only source establishes support for each client. |
| Claude quota ring | Neutral outline with no percentage; no quota API is included. |

Do not classify every `claude-code` producer as the terminal CLI: SDK and editor
entrypoints must remain excluded or explicitly unsupported. A terminal running
inside VS Code is still CLI usage, not Copilot or Claude's editor integration.
Absent or ambiguous attribution must produce a visible coverage limitation.

Claude reports noncached input separately from cache reads and writes:

```text
input      = input_tokens
output     = output_tokens
cacheRead  = cache_read_tokens, when reported
cacheWrite = cache_creation_tokens, when reported
total      = input + output + cacheRead + cacheWrite
```

Copilot continues to subtract reported cache counts from its inclusive input.
Missing cache fields remain Not reported, not known zero. Count API request
events once; never add their metric counters, trace spans, or response mirrors
to the same totals. Retain valid subagent calls without counting parent totals
again.

Prefer reported integer `cost_usd_micros` for estimated cost. Any supported
decimal `cost_usd` conversion must be checked and tested; never use unchecked
floating-point accumulation. Track reporting coverage so missing costs do not
look free. Do not sum Copilot request quotas with Claude costs or tokens.

## Existing code that constrains the change

This table records the pre-implementation baseline, not the current completion
state. See the handoff above for the provider-aware foundations already added.

| Code | Constraint |
| --- | --- |
| [UsageSource](../../sources/Core/UsageSource.swift) | Existing persisted sources are `cli`, `vscodeLocal`, and `vscodeCopilot`, all Copilot. |
| [Activity](../../sources/Core/Activity.swift) | `Client` names, envelope versions, validation, and metric defaults are Copilot-specific. |
| [CopilotUsage](../../sources/Core/CopilotUsage.swift) | Shared token ledger exists; filtering, capacity reporting, and session grouping need provider awareness. |
| [OTLPReceiver](../../sources/Core/OTLPReceiver.swift) | Authenticated loopback JSON transport exists; logs and metrics are currently acknowledged without collection. |
| [CopilotOTelNormalizer](../../sources/Core/CopilotOTelNormalizer.swift) | Admits Copilot per-call traces only and assumes inclusive input. |
| [VSCodeIntegrationController](../../sources/App/VSCodeIntegrationController.swift) | Owns the current receiver and VS Code setup/removal lifecycle. |
| [TokenotchModel](../../sources/App/TokenotchModel.swift) | Coordinates delivery, account state, metrics, session activity, and navigation with Copilot-specific assumptions. |
| [HistoryController](../../sources/App/HistoryController.swift) and [UsageHistoryStore](../../sources/Core/UsageHistoryStore.swift) | Recording consent is global; persisted source constraints, coverage, and queries require migration. |
| [SessionTimeline](../../sources/Core/SessionTimeline.swift) and [SessionTimelineStore](../../sources/Core/SessionTimelineStore.swift) | Session ownership and persisted event validation must not mislabel Claude as Copilot. |
| [CopilotRing](../../sources/Notch/CopilotRing.swift) and [CopilotSummaryView](../../sources/Notch/CopilotSummaryView.swift) | Single-provider logo, quota, accessibility, and card assumptions need a provider-scoped presentation. |
| [SettingsView](../../sources/Settings/SettingsView.swift) and [UsageHistoryView](../../sources/Settings/UsageHistoryView.swift) | Shared navigation already exists; expand filtering rather than duplicating the sidebar. |

## Implementation sequence

### 1. Establish fixtures and acceptance gates

- [ ] Define the minimum Claude CLI and Desktop versions from documentation and
  consented real-client checks, not a guessed version floor.
- [x] Create synthetic OTLP log fixtures for CLI and local Desktop, missing
  fields, multiple calls, subagents, unsupported entrypoints, and malformed data.
- [ ] Verify which identity fields accompany actual delivery, including session
  resume, CLI-to-Desktop handoff, and requests without a server request ID.
- [x] Define separate metrics and lifecycle capability states. A configured
  connection is not proof of either signal's delivery.
- [x] Record the release acceptance checklist without saving prompts, raw
  telemetry, paths, account identifiers, or credentials.

Exit gate: an explicit supported-field contract and a bounded deduplication
strategy exist. No private-storage fallback is necessary.

### 2. Introduce provider-aware identity and migrate storage

Depends on step 1.

- [x] Add explicit provider identity and client surface, retaining source/harness
  distinctions. Derive valid combinations from admitted sources rather than
  accepting arbitrary provider/client pairs. No plugin registry is needed.
- [x] Preserve existing Copilot source raw values and legacy envelope semantics.
  Use a versioned Claude observation contract instead of treating legacy `cli`
  events as provider-neutral.
- [x] Namespace session identity by provider and reported session ID, not model
  name or current client. Preserve per-call client origin across session handoff.
- [x] Namespace call identity by provider and stable request identity. Prefer
  documented request IDs; never deduplicate by tokens, model, or timestamp alone.
  Missing stable IDs require a reviewed fallback or explicit partial coverage.
- [x] Apply consistent deduplication to live metrics, saved history, and timelines.
  Replayed calls must not move from CLI to Desktop or count twice after restart.
- [x] Migrate daily/hourly source constraints, timeline metadata, cost coverage,
  and per-source recording coverage transactionally. Preserve legacy counts,
  receipt identities, reporting time zone, and unknown accounting fields.
- [x] Migrate existing history consent to Copilot only. Claude history and saved
  timelines remain off until explicitly approved.
- [x] Track consent start, recording coverage, and comparison baselines per
  provider/source. Connecting or pausing Claude must not reset Copilot's recording
  window or make earlier Claude dates appear fully observed.
- [x] Test unsupported future schemas and migration failures: pause and report
  errors without resetting data. Document downgrade limits before release.

Exit gate: synthetic Copilot data is unchanged after migration; mixed-provider
queries and shared-session handoff remain correctly attributed.

### 3. Add Claude metrics collection and owned setup

Depends on step 2.

- [x] Add a Claude-specific OTel log normalizer that builds a new allowlisted
  numeric payload; do not reuse Copilot's trace admission or cache subtraction.
- [x] Reuse `OTLPReceiver` framing and authentication. Route Claude logs only to
  the Claude adapter; retain existing VS Code routes and discard-only behavior
  for signals not supported by their adapter.
- [x] Add a Claude integration controller. Prefer independent integration-owned
  receiver instances using the shared transport implementation; disconnecting
  VS Code must not stop Claude, or vice versa.
- [x] Provide explicit setup for the selected local Claude configuration root.
  The default is `~/.claude`; do not enumerate alternate accounts or read
  `~/.claude.json`, keychains, or Desktop conversation stores.
- [x] Merge approved user settings to enable telemetry and the logs exporter
  with a signal-specific HTTP/JSON localhost endpoint. Collect request events
  without enabling beta traces, metrics aggregation, or content capture.
- [x] Preserve unrelated settings and existing hooks. Respect telemetry opt-outs,
  managed settings, and external collectors; conflicts are visible blockers,
  not values to silently overwrite.
- [x] Use owner-only bounded files, no symlink traversal, atomic writes, and an
  exact-owned settings receipt. Recheck before writing and before removal.
  Interrupted setup must recover or report cleanup pending.
- [x] Removal restores only unchanged Tokenotch-owned entries. User edits made
  afterward survive. Never stop another app's collector or change shell profiles.
- [x] Show Configured, Waiting for data, Data received, No recent data,
  Unsupported observations, and setup failures independently for each client.
- [x] Keep prompts, responses, tool arguments, repository paths, user/account
  attributes, and raw errors out of logs and storage even if the producer emits
  them. Missing required fields and rejected batches remain visible.

Exit gate: synthetic CLI and Desktop logs reach live metrics and consented
history; setup, retry, restart, and removal do not disturb Copilot.

### 4. Expose the two-provider macOS interface

Depends on steps 2 and 3.

- [x] Introduce the Claude glyph and a provider-scoped ring/card presentation.
  Keep Copilot's quota model intact rather than inventing a common quota API.
- [x] Adapt notch geometry, hit testing, hover/click selection, fold/unfold,
  auto-hide, and accessibility for one or two provider cells on all four edges.
  Preserve multi-display and full-screen behavior.
- [x] Keep both provider cells independently readable. Claude uses a neutral
  outline, provider name, and available metrics; unsupported quota or lifecycle
  fields do not look like zero usage or idle work.
- [x] Apply provider/client filtering consistently to Usage, History, Sessions,
  model lists, comparisons, insights, live details, and navigation targets.
  Clear stale snapshots during filter changes; do not briefly show another
  provider's totals under the selected logo.
- [x] Keep provider identity in All providers model rows, even when both products
  report the same model string. Only comparable token/call measures can share
  an aggregate; preserve coverage warnings and separate cost/quota sections.
- [x] Group Connections by provider. Expose separate metrics/lifecycle readiness,
  notch visibility, and provider-scoped recording controls in the appropriate
  shared Settings pages.
- [x] Add provider-scoped history deletion with explicit confirmation, preserving
  the other provider's rows and receipts. Disconnect retains saved history;
  deletion does not silently change recording consent.
- [x] Explain whether deleting history also removes estimated cost aggregates.
  Saved timelines remain a separate, explicitly named deletion operation.
- [x] Keep Apple notification permission, quiet hours, and app appearance shared.
  Any provider-specific event toggle is gated by its actual capability.

Exit gate: users can identify whose data they are viewing, move from either
notch cell to its History, and remove Claude without losing Copilot behavior.

These are implementation checkmarks, not real-client or accessibility acceptance.
Synthetic checks cover the isolated app path, four-edge geometry/rendering/clicks
and injected full-screen folding. Native keyboard focus is blocked on the current
host; physical multi-display, VoiceOver, real full-screen and installed-client
checks remain in step 6.

### 5. Add verified Claude lifecycle reporting

Depends on steps 1, 2, and 3. Required for lifecycle claims, not basic metrics.

- [ ] Extend the bounded native helper with a Claude-only hook adapter; command
  hooks must return no decision, no stdout, and remain fail-open with sanitized
  delivery diagnostics. Do not read `transcript_path` or retain hook content.
- [ ] Validate `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd`.
  Add documented attention/error events only where verified on each client.
- [ ] Join reported hook `session_id` to telemetry `session.id` using the same
  provider session namespace. Hook payloads alone may not identify the client;
  keep client attribution unreported until corroborated, not guessed from paths
  or whichever app is foreground.
- [ ] Treat Stop as a turn ending, not task success. Handle resume, handoff,
  subagent events, missing end events, and delayed delivery without fabricated
  working or completion states.
- [ ] Gate Claude activity indicators, notifications, and saved lifecycle
  timelines behind verified delivery and their own applicable consent.

Exit gate: each advertised lifecycle capability has client-specific acceptance.
If unavailable, retain metrics-only support and disclose that limitation.

### 6. Complete regression and real-client acceptance

Depends on steps 2 through 4, plus step 5 for any lifecycle claims.

Add a few focused cases to the existing fixture/test structure, covering new
behavior rather than duplicating all existing Copilot tests.

| Area | Required evidence |
| --- | --- |
| Accounting | Claude cache counts are not subtracted twice; missing fields/costs remain unavailable; overflow and invalid numbers are rejected. |
| Attribution | Copilot using a Claude model stays Copilot; unsupported SDK/editor producers are excluded; CLI/Desktop handoff preserves call ownership. |
| Deduplication | Repeated batches, mirrored signals, restart, and duplicate handoff delivery cannot inflate retained totals. |
| Privacy/setup | Synthetic secret/content fields never reach persisted data or diagnostics; conflicts and exact-owned cleanup behave correctly. |
| Migration/consent | Copilot-only archives survive; Claude stays off without approval; changing Claude recording does not interrupt Copilot. |
| UI | Single-provider, two-provider, disconnected-history, no-data, stale, partial, and storage-error states; keyboard and VoiceOver; reduced motion/transparency. |
| Runtime | Both integrations work simultaneously; receiver failure/removal affects only its owner; app closure produces truthful gaps. |

Use the repository's existing commands during implementation:

```sh
xcrun swift test --filter 'TelemetryTests|TelemetryImportTests|SourceHistoryTests|UsageHistoryTests|HistoryLifecycleTests|SessionTimelineTests'
make smoke-telemetry
make smoke-contracts
xcrun swift test --filter 'ConnectionsTests|UsageReportingTests|NotchRenderTests|OnboardingTests'
make smoke-notch
make smoke-hook
make docs-check
```

Add Claude cases/classes to the relevant test selection when they exist. The
current smoke runners must be updated to execute new shared checks, not merely
compile a normalizer without exercising it. Run `make test`, `make smoke`, and
`make universal` for final native acceptance; build prerequisites and GUI
limitations remain those documented in [Contributing](../../CONTRIBUTING.md).

Real-client checks require separate approval and recorded OS/client versions.
Use a consented ordinary session, not automated inference or developer credential
inspection. Verify CLI and local Desktop separately, then simultaneous Copilot
and Claude delivery, handoff, restart, disconnect, and owned removal.

Update [architecture](../architecture.md),
[integration contracts](../tokenotch-integrations.md),
[privacy](../tokenotch-privacy.md), [features](../features.md),
[compatibility](../compatibility.md), and onboarding/support guidance to describe
only tested capabilities. Include the Claude logo's notices in packaged builds.

Windows source, installer behavior, and supported providers remain unchanged.
Preserve existing shared wire fixtures and run their macOS contract smoke check;
new Claude envelopes must not masquerade as a legacy supported Windows source.

## Delivery boundaries

Implement in reviewable slices: fixtures, contracts/migrations, collection/setup,
provider UI, verified lifecycle, then release acceptance. Each slice preserves
existing behavior and carries its relevant tests.

The first engineering step is step 1 followed by provider identity and migration
fixtures, not placing a Claude logo over Copilot-only data. Context, subscription
quotas, additional Claude clients, and Windows are separate follow-up plans.

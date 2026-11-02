# Claude Code implementation handoff

Updated: October 30, 2026, after the metrics integration and provider UI implementation.

Current scope, November 2: Desktop collection and setup controls have been
removed in favor of CLI-only support. Legacy archive/receipt compatibility is
retained, including exact-owned marker retirement. Account sign-in now uses
official CLI login/status commands; quota windows remain a separate CLI
status-line opt-in. The Desktop notes below are historical, not active product
requirements. See the [current contract](../claude-code-contract.md).

November 2 Desktop follow-up: local Code-tab metrics now have a separate setup
opt-in, defaulting off. New owned setup adds a collector-derived
`tokenotch.local_installation` resource marker. Old CLI receipts remain usable
without startup rewrites; explicit review upgrades attribution ownership.
The receiver admits Desktop only with that matching resource marker and no
cloud-session attribute, preserves CLI/Desktop origin on the shared endpoint,
and routes both clients to independently consented archives. Onboarding,
Connections, filters and session details include Desktop. Synthetic checks cover
missing/wrong local markers, cloud exclusion, mixed-client delivery, handoff and
durable replay, restart, opt-out and removal. Real Desktop delivery, SSH exclusion
and installed-client acceptance have not been performed; lifecycle remains off.
The older Desktop gating statements below describe the pre-follow-up state.

November 2 follow-up: Claude CLI setup now requests explicit approval to make an
owned `settings.json` private (`0644` to `0600`) instead of requiring a manual
permission command. The metadata-only check, cancellation, exact-file/directory
replacement guards and policy/environment rechecks have synthetic coverage.
Folders, ownership and unrelated files are not changed. Real permissions change
only when the user chooses **Make private and continue** in the setup popup.
The popup's approval/cancellation actions and readable rendering pass the
synthetic app checks. The host now selects an installed Xcode whose license is
pending; this follow-up used `DEVELOPER_DIR=/Library/Developer/CommandLineTools`
for native builds/checks without changing the selected toolchain or accepting
license agreements.

**Start here after clearing conversation context.** Claude Code CLI metrics now
have an opt-in application receiver, exact-owned settings setup/removal,
provider-scoped analytics and notch cells. Synthetic application checks pass.
No real saved settings were changed or installed-client checks performed in
this implementation pass. **Desktop, lifecycle and release acceptance remain gated.**

Read this alongside the [implementation plan](2026-10-30-claude-code-macos.md)
and [foundation contract and acceptance evidence](../claude-code-contract.md).
The plan remains the full requirements checklist; this file is the current-state
handoff and next-work guide.

## Worktree and operating boundaries

- The implementation is currently in modified and untracked repository files.
  No commits were created during this work. Run `git status --short` before
  continuing, preserve existing changes, and do not reset or discard the worktree.
- Windows source and supported providers are unchanged. Keep shared legacy
  Copilot wire fixtures compatible.
- Real-client approval covered **Claude Code CLI only**, not Desktop. Prior
  checks used user-operated ordinary prompts, not automated inference.
  Obtain approval for further live checks or saved-settings changes; do not
  interpret the completed temporary check as permission to install an integration.
- No saved Claude settings were changed. Temporary acceptance receivers were
  stopped and their launchers/endpoint credentials removed. There is no live
  collector or test endpoint to reuse.
- Never inspect credentials, `~/.claude.json`, transcripts, private Desktop
  caches, alternate account profiles, or raw telemetry to fill missing capabilities.

## What is implemented

| Area | Current implementation |
| --- | --- |
| Provider/source identity | `UsageProvider`, client surfaces, `claudeCLI` and `claudeDesktop`; legacy Copilot source raw values unchanged |
| Observation contract | Claude usage-only envelope version 5; invalid client/source pairs and legacy masquerading rejected |
| Accounting | Disjoint Claude input/output/cache buckets; optional checked integer estimated cost with reporting coverage; Copilot subtraction unchanged |
| API admission | Documented `event.name=api_request`; exact namespaced body fallback only when the attribute is absent; contradictory names rejected |
| Transport | Explicit provider-owned `OTLPReceiver` instances; Claude logs adapter isolated from default Copilot traces adapter |
| Replay and handoff foundations | Provider-namespaced request/session identity, original per-call client ownership, bounded live deduplication and durable archive receipts |
| Storage | Transactional history schema 7 and timeline schema 4 migrations; preserve legacy counts, unknown fields, receipt keys and reporting zone |
| Consent and coverage | Legacy consent migrates to Copilot only; separate provider preferences, source/client admission windows and conservative comparison baselines |
| Readiness foundations | Separate metrics/lifecycle capability and delivery states; configured does not mean data received |
| Tests/diagnostics | Synthetic Claude checks, independent-receiver smoke coverage, provider recording-isolation checks, and an opt-in temporary CLI diagnostic |
| Owned setup | `ClaudeCodeInstallation` inserts only approved missing exporter entries; bounded private files, directory identity, atomic replacement, receipt-first recovery and edited-entry preservation |
| Application collection | `ClaudeCodeIntegrationController` owns Claude's receiver independently of VS Code; CLI metrics reach the shared ledger and independently consented archives |
| Provider UI | One/two cells, Claude CC0 mark and neutral outline, provider/source filters, separately labeled history charts, cost coverage, Connections and metrics-only onboarding |
| Data management | Confirmed provider-scoped usage/cost and timeline deletion preserves the other provider's observations and receipts; disconnect retains archives |

These include synthetic app behavior, not installed real-client or release
acceptance. Older binaries cannot open the new archive schemas;
there is no reverse migration. See the foundation contract before downgrade work.

### Important implementation locations

| Files | What to preserve or extend |
| --- | --- |
| [`UsageSource.swift`](../../sources/Core/UsageSource.swift), [`Activity.swift`](../../sources/Core/Activity.swift) | Provider identity, source-derived combinations and version-5 validation |
| [`ClaudeCodeOTelNormalizer.swift`](../../sources/Core/ClaudeCodeOTelNormalizer.swift) | Allowlisted numeric normalization, producer admission, event markers and fixed rejection-stage diagnostics |
| [`OTLPReceiver.swift`](../../sources/Core/OTLPReceiver.swift) | `OTLPReceiver(provider: .claudeCode)` is opt-in; default receiver remains Copilot-only |
| [`CopilotUsage.swift`](../../sources/Core/CopilotUsage.swift), [`UsageHistory.swift`](../../sources/Core/UsageHistory.swift) | Shared ledger, provider-aware model identities and cost/coverage types |
| [`UsageHistoryStore.swift`](../../sources/Core/UsageHistoryStore.swift), [`SessionTimelineStore.swift`](../../sources/Core/SessionTimelineStore.swift) | Migrations, receipt identity, provider queries and coverage |
| [`ProviderRecordingConsent.swift`](../../sources/Core/ProviderRecordingConsent.swift), [`RecordingWindows.swift`](../../sources/Core/RecordingWindows.swift) | Independent consent and retained admission windows |
| [`HistoryController.swift`](../../sources/App/HistoryController.swift), [`SessionTimelineController.swift`](../../sources/App/SessionTimelineController.swift) | Provider filters, captured query scopes, source admission windows and provider-scoped deletion |
| [`SignalReadiness.swift`](../../sources/Core/SignalReadiness.swift), [`TokenotchModel.swift`](../../sources/App/TokenotchModel.swift) | CLI metrics-only collection; Desktop/lifecycle remain unverified |
| [`ClaudeCodeInstallation.swift`](../../sources/Core/ClaudeCodeInstallation.swift), [`ClaudeCodeIntegrationController.swift`](../../sources/App/ClaudeCodeIntegrationController.swift) | Selected-root ownership receipt, isolated receiver, restart/retry/removal and periodic ownership/policy checks |
| [`ClaudeCodeIntegrationChecks.swift`](../../tests/ClaudeCodeIntegrationChecks.swift) | Synthetic delivery, replay, archives, retry/restart/removal, four-edge clicks/folding; separate native focus gate |
| [`VSCodeIntegrationController.swift`](../../sources/App/VSCodeIntegrationController.swift) | Existing owned receiver/setup lifecycle; reuse patterns without coupling Claude's lifetime to VS Code |
| [`claude-acceptance.swift`](../../scripts/claude-acceptance.swift) | Temporary, consent-gated CLI launcher/receiver; not a production integration controller or installer |
| [`ClaudeCodeChecks.swift`](../../tests/ClaudeCodeChecks.swift), [`ClaudeCodeTests.swift`](../../tests/ClaudeCodeTests.swift) | Shared smoke/XCTest fixtures for accounting, attribution, privacy, migrations and diagnostic stages |
| [`HistoryLifecycleChecks.swift`](../../tests/HistoryLifecycleChecks.swift), [`TimelineLifecycleChecks.swift`](../../tests/TimelineLifecycleChecks.swift) | Connecting/pausing/removing Claude must not interrupt Copilot |

## Real CLI evidence: passed, with limits

The approved retest used **Claude Code 2.1.212 on macOS 27.2, arm64**:

- Two API-request logs were accepted, with zero rejected or unattributed calls.
- Server request identity and session identity were reported; no unlinked calls.
- Both calls reported valid input/output, cache-read/cache-write counts and
  estimated cost. Do not infer which cost representation was supplied.
- Admission used the documented `event.name` attribute. Earlier body-dependent
  attempts did not admit API calls; do not restore the body-only assumption.
- Non-API event kinds were excluded. The launcher's empty connectivity probe
  was not counted as usage.
- Only sanitized capability counts were retained as evidence, not prompts,
  model names, raw IDs, paths, credentials, raw errors or telemetry bodies.

This verifies basic CLI delivery on that combination, **not a minimum supported
version, installed app integration, or release certification**. Optional
model/duration field presence, real replay/restart/resume, handoff, simultaneous
Copilot delivery, owned setup/removal and lifecycle are not verified.
Desktop has not been tested or approved.

## Remaining implementation, in order

### 1. Production metrics collection and safe setup

This engineering slice is implemented for CLI metrics. Live installed-client
setup/removal still requires separate acceptance. The setup explicitly asks the
user to check Claude `/status`; Tokenotch cannot inspect the client's effective
shell environment or server-managed policy and never reads private policy caches.

- [x] Add a Claude integration controller owning its own receiver, endpoint
  configuration, startup/retry/shutdown and sanitized per-client delivery state.
  Removing or failing either provider must not stop the other.
- [x] Implement explicit setup for the selected local configuration root
  (default `~/.claude`), without account/profile discovery.
- [x] Merge only approved logs-exporter settings. Respect opt-outs, managed
  policy, existing external collectors and unrelated hooks/settings.
- [x] Use bounded owner-only files, reject unsafe paths/symlinks, write atomically,
  and maintain an exact-owned receipt with interrupted-setup recovery.
- [x] Restore only unchanged Tokenotch-owned settings on removal. Preserve
  subsequent user edits and report incomplete cleanup.
- [x] Wire admitted Claude calls through the app to the shared live ledger and
  independently consented history/timeline paths. Do not route them through
  legacy Copilot hook envelopes or relabel them as Copilot.
- [x] Publish Configured, Waiting for data, Data received, No recent data,
  Unsupported observations and setup failures separately for each client.
- [x] Test restart, retry, conflicts, partial writes, ownership changes and
  disconnect/removal with isolated synthetic configuration directories first.

Keep UI labels truthful while wiring collection: merely removing Copilot-only
guards would expose mixed totals under the Copilot logo. Core support already
exists; extend the application presentation and routing deliberately.

The [`Makefile`](../../Makefile) now includes Claude's controller and shared app
checks in `smoke-notch`. `NOTCH_SMOKE_ARGS=--claude` runs the isolated integration,
rendering and interaction slice without the full attention suite.

### 2. Provider UI and data management

- [x] Add a licensed/attributed Claude mark and independently readable notch
  cell/card. Preserve the existing black surface, typography and token colors.
  Claude gets a neutral quota outline, not an invented percentage.
- [ ] Support one/two cells on all four edges, including hover/click, hit testing,
  fold/unfold, auto-hide, keyboard/VoiceOver, multiple displays and full screen.
  Implemented with synthetic rendering, clicks and injected full-screen checks.
  Native keyboard-focus acceptance is blocked on this host; VoiceOver, physical
  multi-display and real full-screen acceptance remain open.
- [x] Add provider/client filters throughout Usage, History, Sessions, models,
  comparisons, insights and navigation. Clear stale snapshots when switching.
- [x] Keep provider identity in All providers model rows and separate provider
  chart series. Model identities are already namespaced: distinguish raw model
  names used in queries from provider-qualified presentation identities.
- [x] Group Connections by provider; expose independent recording consent,
  readiness and notch visibility. Hiding a cell must not disconnect collection.
- [x] Add confirmed provider-scoped history deletion that preserves the other
  provider's data and receipts. Explain cost aggregate deletion; saved timelines
  remain a separately named deletion operation.
- [x] Preserve shared appearance, privacy, notification permissions and quiet
  hours. Preserve retained history after disconnect.

### 3. Lifecycle, only when independently verified

- [ ] Implement a bounded Claude hook adapter for the documented lifecycle
  events, with no stdout/decision, no transcript reads and fail-open delivery.
- [ ] Correlate reported hook sessions with telemetry sessions without guessing
  client origin from paths or foreground apps.
- [ ] Verify start/prompt/stop/end, resume, delayed/missing events and handoff.
  Stop is a turn ending, not proof of task success.
- [ ] Gate activity indicators, attention, notifications and saved lifecycle
  timelines on their own capability/delivery evidence and consent.

Lifecycle is **not a prerequisite for metrics-only support**. Keep it explicitly
unavailable if it cannot pass client-specific acceptance.

### 4. Remaining acceptance and release gates

- [ ] Establish supported client-version policy from evidence; a single tested
  version is not a guessed compatibility floor.
- [ ] Verify optional model/duration fields and requests without server IDs.
  Missing stable identity currently means rejected/partial coverage, not an
  invented timestamp/token-based identity.
- [ ] Verify real restart/replay/resume and simultaneous Copilot/Claude delivery,
  then owned disconnect/removal without disturbing Copilot.
- [ ] With separate approval, verify local Desktop Code-tab metrics and
  CLI-to-Desktop handoff. Service name alone does not establish local execution;
  Desktop SSH exclusion is unresolved and remains a release blocker.
- [ ] Finish native tests and UI/accessibility/runtime acceptance, including
  the unresolved request-card timeout below.
- [ ] Update features, onboarding/support and packaged asset notices only for
  capabilities actually delivered and verified.

## Validation evidence and known blockers

| Command/check | Last recorded result |
| --- | --- |
| `make smoke-telemetry` | Passed owned settings, interrupted recovery, conflicts, deletion/receipt isolation, normalization and independent receivers |
| `make docs-check` | Passed Markdown/local links and documentation tests; case-sensitive-filesystem test skipped on this host |
| `git diff --check` | Passed |
| `make smoke` | Passed the full non-GUI native/helper/extension/telemetry/shared-contract suite |
| `make universal` | Passed; arm64/x86_64 app and helper verified, including packaged CC0 attribution |
| `make -o build smoke-history smoke-timeline` | Passed with the current rebuilt host library |
| `make -o build smoke-notch NOTCH_SMOKE_ARGS=--claude` | Passed selected-root setup, app routing, replay, independent consent, port conflict/retry, restart/removal and four-edge rendering/clicks/folding |
| `build/tokenotch-notch-smoke --onboarding` | Passed current usage isolation, Connections, metrics-only onboarding and existing consent/recovery checks |
| `build/tokenotch-notch-smoke --ui-timing` | Passed bounded fixture waits, history rendering and clock-controlled auto-hide |
| `build/tokenotch-notch-smoke --claude-focus` | Native focus gate: visible focus-capable card but no key window on this host; not certified |
| `build/tokenotch-notch-smoke --request-card` | Passed once earlier; subsequent isolated run failed at keyboard focus. Historical dwell timeout remains unresolved, not fixed by retrying |
| `make -o build smoke-notch` | Full attention/UI acceptance not rerun; historical request-card timeout and native focus remain open |
| `make test` | Blocked by the active Command Line Tools setup without full Xcode; no XCTest cases ran |
| Acceptance diagnostic guards | Missing explicit consent arguments and conflicting launcher telemetry environment were refused as expected |

The companion freshness fixture now uses one injected clock for expiry and file
timestamps. A 601-second future test had crossed a wall-clock second during I/O
and become a valid 600-second request. Runtime freshness rules are unchanged;
the targeted fixture and complete companion suite passed after the correction.

Further focus diagnosis reproduced the failure outside Tokenotch: a minimal
standard titled `NSWindow` with an `NSTextField` also remained visible and
focus-capable but never became key, including after a real AppKit launch/event
loop and explicit activation. Public panel flag/hosting-view variants behaved
the same way. No speculative product focus changes were retained.
The active toolchain is still Command Line Tools, and no Xcode application was
found in `/Applications`. The user was unavailable to authorize further live
acceptance; no real client setup or inference was performed.

Use the prerequisites in [Contributing](../../CONTRIBUTING.md). Select a coherent
full Xcode toolchain for XCTest; do not change `Package.swift` to hide the local
toolchain limitation. Do not retry the full UI suite until it happens to pass
or claim the unresolved timeout is fixed.

`-o build` skips rebuilding: use it only after rebuilding the current host
library. Start with targeted checks while iterating; rerun the full native
acceptance commands after the remaining implementation changes.

```sh
make smoke-telemetry
make smoke-contracts
make build
make -o build smoke-history smoke-timeline
make -o build smoke-notch NOTCH_SMOKE_ARGS=--claude
make -o build smoke-notch NOTCH_SMOKE_ARGS=--onboarding
make docs-check
```

Remaining native acceptance requires full-Xcode `make test`, native keyboard and
full UI/accessibility checks, plus the real-client checks specified by the plan.
Do not treat the passing metrics/clicks smoke slice as native-focus certification.

## Scope that must not creep into this work

Claude subscription quotas, context occupancy/compaction, Windows implementation,
ordinary Claude chat, Cowork, Claude's editor extension, SDK clients, remote/cloud
sessions, transcript imports and account-profile discovery remain excluded or
deferred. Do not treat them as unfinished requirements of this metrics slice.

## Suggested next-session instruction

> Preserve the uncommitted implementation. Complete the remaining client-version,
> installed CLI, optional-field/replay/resume, UI/accessibility and toolchain
> acceptance gates. The isolated request-card check passed once without a timing
> fix; do not call the historical timeout resolved. Obtain separate approval for
> live sessions or saved-settings changes. Keep Desktop and lifecycle unavailable
> until their independent attribution and delivery evidence passes. Never inspect
> private client storage or substitute a guessed compatibility floor.

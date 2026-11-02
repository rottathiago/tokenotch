# Claude Code foundation contract

This is an **experimental, opt-in macOS Claude Code CLI metrics integration**, not release
certification. The application now offers exact-owned user-settings setup,
independent collection, provider-scoped analytics and notch cells. Metrics setup
does not enable lifecycle hooks or configuration discovery. A separate
status-line opt-in reports CLI quota/reset windows and live session context.
Desktop collection and its setup controls have been removed. Optional account
sign-in uses the official CLI, independently of collection and history.
Separately approved start/end hooks manage session visibility; working activity
and attention remain unavailable. The temporary CLI check below is not installed-app acceptance.
Windows contracts and implementation are unchanged.

The [implementation plan](plans/2026-10-30-claude-code-macos.md) separates this
foundation from owned setup, provider UI, lifecycle reporting, and release
acceptance.

The [implementation handoff](plans/2026-10-30-claude-code-handoff.md) records
what is still missing, current validation limits, and where to resume after
clearing conversation context.

## Evidence and acceptance gates

The official [monitoring reference](https://code.claude.com/docs/en/monitoring-usage)
and [Desktop reference](https://code.claude.com/docs/en/desktop) were reviewed
on October 30 and November 2, 2026. Documentation establishes candidate fields,
not delivery. The experimental receiver admits the bounded contract below;
real-client acceptance is still required before release certification.

| Gate | CLI |
| --- | --- |
| Minimum accepted client version | Not established |
| Actual numeric log delivery | Passed temporary check on 2.1.212; input/output, cache and cost reported |
| Producer/entrypoint attribution | `claude-code` with `cli` admitted in the temporary check |
| Local versus remote attribution | Local CLI launch checked; remote exclusion synthetic only |
| Resume and replay | Synthetic checks only |
| Lifecycle hooks and attention | Not enabled or verified |
| Owned setup, opt-outs, removal | Synthetic application checks passed; installed-client acceptance pending |
| Account sign-in and status | Official CLI commands; mock runtime/application checks, live login acceptance pending |

Only the local terminal CLI is collected. Known Desktop telemetry is discarded,
and its transport route is not admitted. No installation marker is required.
Legacy source identifiers remain decodable only to preserve saved observations;
they are not offered as active connections or filters. Startup removes unchanged
Tokenotch-owned legacy marker settings with the existing ownership journal.
User-edited or unowned values and historical data are preserved.

Real checks require separate approval for ordinary sessions and settings changes.
Record only the OS/client versions, tested capability, and pass/fail outcome.
Do not save raw telemetry, prompts, paths, account identifiers, or credentials.
No guessed version floor, private-storage fallback, or lifecycle claim is allowed.

### Consented CLI check on October 30, 2026

The user operated ordinary CLI sessions with Claude Code **2.1.212** on
**macOS 27.2, arm64**. Desktop was not approved or accessed. The checks used
temporary, owner-only launchers and a separate authenticated localhost receiver.
Only that CLI process's exporter environment changed; saved client settings and
Tokenotch archives were untouched. Launchers and receiver were removed afterward.

The first launch received no logs. An explicitly approved diagnostic retry,
adding the documented generic HTTP/JSON protocol alongside the logs-specific
protocol, delivered log batches. Its empty launcher connectivity probe was not
counted as usage. The original body-dependent normalizer admitted no API calls.

A subsequent approved retest with documented `event.name=api_request` admission
**passed numeric API-request delivery**: two API requests were accepted, with no
rejected or unattributed requests, missing server request IDs, or unlinked calls.
Both supplied valid required input/output counts, a reported session, cache-read
and cache-write counts, and estimated cost. Other event kinds were excluded.
This confirms the candidate CLI producer/entrypoint combination and reported
request/session identity for this session; it does not verify stable identity
across replay, resume, or handoff.

Optional model/duration field presence, simultaneous real Copilot delivery,
restart/replay, owned setup/removal, Desktop, and lifecycle remain separate
acceptance gates. No minimum supported version or blanket release certification
is inferred from one tested client/OS combination.

No raw log bodies, prompts, model IDs, session/request identifiers, credentials,
paths, or account attributes were retained as acceptance evidence. The reusable
opt-in diagnostic is [`scripts/claude-acceptance.swift`](../scripts/claude-acceptance.swift);
it does not run inference automatically, install hooks, edit client settings, or
certify a client merely because its launcher can reach localhost.

After explicit approval and conflict review, build and run it with
`make claude-acceptance CLAUDE_ACCEPTANCE_ARGS='--consented-cli /absolute/path/to/claude'`.
Running without that explicit argument refuses live acceptance. The receiver
expires after ten minutes; interrupting it also stops collection and removes its
temporary launcher. Exit the test CLI to discard that process's exporter
environment. Never use the launcher to bypass managed telemetry or an opt-out.

## Candidate numeric payload

Only OTLP HTTP/JSON `resourceLogs` / `scopeLogs` / `logRecords` envelopes are
normalized. The documented `event.name=api_request` identifies a request
independently of body formatting. If that attribute is absent, only the exact
body name `claude_code.api_request` is admitted. Contradictory request/response
names are rejected. Metric counters, traces, assistant/response
mirrors, parent/subagent completion totals, and other logs are never added.
Valid API calls from subagents remain ordinary independently identified calls.

| Field | Treatment |
| --- | --- |
| Resource `service.name` | `claude-code`; other active producers are not admitted |
| `app.entrypoint` | `cli` required; duplicate resource/event values must agree |
| `ccr.session.id` | Presence excludes cloud delivery; never retained |
| `event.timestamp` | Required ISO 8601 event time; receipt time and process sequence are not call identity |
| `request_id` | Required stable server request identity; hashed within the Claude provider |
| `session.id` | Optional reported session identity; hashed within the Claude provider |
| `model` | Optional bounded ASCII identifier |
| `input_tokens`, `output_tokens` | Required integer counts, each from 0 through 1,000,000,000 |
| `cache_read_tokens`, `cache_creation_tokens` | Optional integer counts with explicit reporting coverage |
| `duration_ms` | Optional finite duration from 0 through 86,400,000 ms |
| `cost_usd_micros` | Preferred optional integer estimated cost |
| `cost_usd` | Checked decimal fallback only when integer micros are absent |

Numeric attributes accept OTLP integer/double values and validated numeric
strings. Counts reject fractions, booleans, negative values, and overflow.
Present entrypoint attributes must be strings. SDK and editor producers remain
excluded. Retired installation markers are discarded like other unknown fields.
Cloud-session markers remain an unconditional exclusion and have a distinct
diagnostic reason rather than being combined with unrecognized producers.
Duplicate allowlisted attributes are rejected rather than arbitrarily resolved.
Unknown attributes are discarded before constructing the observation; the raw
payload and errors are not stored or exposed in diagnostics.
The acceptance diagnostic emits only fixed event-marker/rejection-stage enums
and counts, never arbitrary event names, field values, or raw parse errors.

Each request's disjoint token total is:

```text
input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens
```

Missing cache counts are **Not reported**, not known zero. Copilot's existing
inclusive-input subtraction remains unchanged. Cost is optional **estimated
cost**, not subscription spend or remaining allowance. Decimal costs are checked
before conversion and rounded to the nearest integer millionth of a dollar, with
half-millionths rounded up. Fractional-micro costs and floating-point tails do
not discard otherwise valid calls or their model metrics. Per-call cost is bounded at
1,000,000,000,000 micros. Aggregation uses checked integer arithmetic; a failed
write rolls back counts, costs, and receipts together. Missing cost coverage does
not make a call free.
Rejected Claude observations are also surfaced in the notch and Usage tab, so
the last valid cost does not appear to be a complete, current reading.

Bodies are bounded at 4 MiB, batches at 2,048 records, and attribute arrays at
512 entries. Invalid neighbors do not suppress valid records; rejected,
unattributed, unlinked, and missing-request-identity counts remain distinct.

## Identity, replay, and compatibility

`cli`, `vscodeLocal`, and `vscodeCopilot` remain Copilot sources with unchanged
raw values and legacy envelopes. New `claudeCLI` and `claudeDesktop` sources
derive their provider and client surface from the source, not the model name.
Claude numeric observations use envelope version 5. Legacy versions cannot
masquerade as Claude, and arbitrary provider/client pairs are rejected.
Version 5 does not admit lifecycle, context, compaction, or attention events.

Claude session hashes do not include the current client. Call hashes use the
Claude provider and `request_id`, not session, model, tokens, or timestamp.
This keeps the original per-call client through resume and handoff. Calls without
a reported session remain separately unlinked and do not create saved sessions.
Calls without a server request ID are rejected with explicit partial coverage;
`client_request_id` and the per-process `event.sequence` are not enabled fallbacks.
Real acceptance must revisit first-party, third-party, and fallback request cases.

Live deduplication retains the existing 4,096-call, 24-hour bound; eviction stays
explicitly partial. Without session tracking, the notch lists and counts only
sessions with a usage or status-line report in the last five minutes. With
separately approved start/end hooks, observed open sessions stay visible while
idle, and an end event removes the matching session immediately. Usage totals
are retained; usage or context arriving after an end cannot reopen a session.
An explicit subsequent start/resume can reopen it.
Saved Claude usage and timelines use archive-keyed durable
receipts, independently of the current client, so replay after restart cannot
move or duplicate a call. Each archive admits at most 1,000,000 Claude receipts.
At capacity, recording fails explicitly without evicting identities or resetting
history. Receipts remain until the corresponding archive is explicitly deleted.
Copilot's existing short CLI and durable VS Code receipts are unchanged.

Shared model rows carry provider identity, even when model strings match.
Provider/source queries preserve separate cost reporting and recording coverage.
New source recording baselines start only at explicit collection checkpoints,
not the first call or the existing Copilot history start. The archive's creation
date is distinct from its source recording baselines. Comparisons use the latest
start among relevant sources; any unknown start blocks a percentage instead of
borrowing another source's consent. Hourly and weekly coverage remain partial
before that baseline.

Existing source interval checkpoints supply conservative migrated starts. Older
CLI-only schemas preserve their original recording start. A source without
usable checkpoint evidence has an explicitly unavailable baseline; importing
usage never fabricates one.

Recording workers keep independent admission windows per source/client.
Connecting, pausing, or removing Claude does not reset a retained Copilot window,
clear its receipts, or mark its recording interrupted. Resume admits only
post-resume events for that source. Queued acknowledgments use observation-local
IDs so a settings transition cannot reset queue accounting or resurrect a
deleted observation.

Metrics and lifecycle have independent capability/delivery states. Configuration
alone means **Waiting for data**, never **Data received**. Receiving metrics does
not verify hooks, and unsupported or unverified capabilities remain so even if
an observation is supplied. CLI metrics start **Off**, then **Waiting for data**
after explicit setup; only an admitted CLI call establishes delivery.
Claude working activity and attention remain **Not verified** and cannot be enabled.
Optional start/end tracking manages visibility only, not task state or success.
Agent Host lifecycle remains **Not supported**.

## Owned local setup and application routing

Setup selects one local configuration root, defaulting to `~/.claude`. It requires
explicit confirmation that Claude `/status` has no managed telemetry or external
collector. Tokenotch checks visible system policy and its own environment but
cannot inspect the client's effective shell environment or server-managed policy.
It never reads private policy caches, credentials, profiles or transcripts.

Only approved logs-only exporter entries are inserted into `settings.json`.
Existing conflicting telemetry, opt-outs and managed policy block setup. Matching
preexisting entries are not adopted; unrelated settings and hooks are preserved.
Files are bounded and owner-only, symlinks/hardlinks and unsafe directories are
rejected, directory identity is retained, and writes are atomically rechecked.
An owned bounded regular settings file with non-private permissions triggers an
explicit permission-approval sheet in setup. Discovery reads metadata only.
Approving rechecks the exact directory/file identity, permissions, size and
modification time before changing only that file to `0600`; cancellation changes
nothing. Policy and environment conflicts are rechecked before approval is
applied. Replacement or edited files require fresh setup instead of reusing
stale approval. Folder permissions and file ownership are never changed, and
removal does not widen the approved private permissions.
An owner-only receipt stores only the selected root, directory identity,
installation endpoint and inserted values, never a backup of unrelated settings.
Receipt-first interrupted setup requires explicit retry or removal.
Old receipts remain readable. CLI-only migration removes only unchanged owned
legacy marker entries, preserving receipt-first recovery and unrelated settings.
No new setup adds an installation marker.

Removal stops only Claude's receiver and removes unchanged owned entries.
Edited entries survive with an explicit cleanup-pending status. Restart reuses
the receipt's endpoint without rewriting client settings; ownership or policy
failure stops collection. Numeric CLI calls reach the shared ledger and
separately consented usage/timeline archives. Removing active Desktop support
does not relabel or erase retained observations.
Provider-scoped deletion includes that archive's cost aggregates and replay
receipts, preserves the other provider, and does not change recording consent.
Saved timelines have a separate confirmed deletion operation.

The native Claude outline is adapted from Simple Icons under CC0 1.0, with
source attribution and trademark limitations in the packaged `LICENSE`.
Claude's notch has a neutral outline until the optional status line reports a
subscription percentage.

## Optional Claude account sign-in

**Connections → Claude Code CLI → Claude account sign-in** opens the official
[`claude auth login`](https://code.claude.com/docs/en/cli-reference#cli-commands)
in Terminal for browser authentication. **Check sign-in** runs `claude auth status`,
whose default output is JSON. No login or account check runs until explicitly
enabled. Polling is limited to once per minute; checks use the selected CLI
configuration root and do not inherit ambient credentials or exporter endpoints.
Only the authenticated flag and allowlisted authentication method enter UI state.
Emails, account identifiers, raw output/errors, credentials and browser callback
URLs are not retained or displayed. The temporary owner-only Terminal launcher
contains paths and command arguments, not credentials, and is removed after
successful status verification or stopping checks. The account policy applies
independently of metrics consent.

Stopping account checks does not run logout or alter the shared CLI login.
Sign-in does not enable telemetry, archives, or quota collection. Subscription
usage and quota windows still come from the separately enabled CLI status line;
there is no Copilot-style account quota RPC or private API fallback.

## Optional quota and live session context

After CLI metrics setup, choose **Connections → Claude Code CLI → Enable quota
& context**. This separately approved operation inserts a `statusLine` command
in the selected user settings, registers the private local bridge and installs
the packaged helper. It refuses to replace or adopt an existing status line.
Turning this feature off removes only unchanged owned status-line settings and
its registration; numeric API-call collection remains enabled.

The [documented status-line input](https://code.claude.com/docs/en/statusline)
was reviewed November 2, 2026. `rate_limits.five_hour` and
`rate_limits.seven_day` supply `used_percentage` and Unix-second `resets_at`.
Each window is independently optional; Claude supplies subscription limits only
when available after an API response. Limits are not calculated from local
token counts, combined across sessions, or inferred to be zero at reset.
Expired reset times and reports older than five minutes are explicitly stale.
These are CLI-reported readings, not separately polled account API responses.

Session context uses the reported `context_window_size` and the sum of
`current_usage.input_tokens`, `cache_read_input_tokens` and
`cache_creation_input_tokens`, matching Claude's input-only occupancy formula.
Output and cumulative token totals are not added. Null/missing current usage,
including immediately after compaction, withdraws the previous reading instead
of reporting zero. Session hashes match the numeric telemetry namespace, so the
context meter joins the existing session without adding usage calls.

The helper strips all other input, including transcript paths, working
directories and session names, before forwarding. It prints only numeric
context/quota text in Claude's terminal and never reads credentials, account
profiles or transcripts. The optional bridge envelope is distinct from numeric
OTel observations; event versions and archive schemas are unchanged.
Readings remain in memory for at most 100 sessions / 24 hours, with stale
disclosure after five minutes, and are cleared by live-data deletion,
feature withdrawal or disconnect. No quota/context history is saved.

Existing sessions report on the next status-line update; resume or restart
sessions if needed. Project settings can override the user status line. The
custom status line can hide some built-in Claude keyboard hints. Missing data
remains **Not reported**, and neither a context reading nor a quota percentage
establishes working activity, completion, attention or Desktop support.
Synthetic parser, setup, native-helper, bridge and rendered-UI checks do not
certify real-client delivery; no live settings are modified as validation.

## Optional session start/end tracking

After metrics setup, choose **Connections → Claude Code CLI → Enable session
tracking**, then restart or resume CLI sessions. This separate confirmation adds
exact-owned `SessionStart` and `SessionEnd` command-hook groups to the selected
user settings. Existing hook groups are preserved. `Stop` is not subscribed:
finishing a response is not closing a session.

The [documented hooks](https://code.claude.com/docs/en/hooks#sessionend) were
reviewed November 2, 2026. The bounded, fail-open helper forwards only a
provider-hashed session ID, start/end kind and observation time through a
separately authenticated local bridge envelope. It drops raw input, paths,
reasons, prompts and subagent events. Numeric event version 5 and archive schemas
are unchanged. Only sessions already observed through CLI usage/context are
shown; start hooks alone do not enable other clients or create usage.

Start/end state is memory-only, bounded to 4,096 sessions / 24 hours.
End markers keep delayed numeric or context delivery from reopening a session
during that window. Disabling tracking revokes its separate bridge
registration and removes only unchanged owned hook groups, without affecting
quota/context consent or usage totals. Edited groups are preserved with a
cleanup warning. Disconnect removes both independently approved integrations.

Force-killing Claude, disabling hooks, closing Tokenotch or overriding settings
can prevent delivery; a missing end event is not evidence of closure.
Real-client start/end delivery remains unverified. Synthetic checks cover
privacy stripping, helper forwarding, independent consent, owned cleanup,
immediate removal, idle sessions, delayed observations and explicit resume.

## Storage and consent migration

Usage history migrates transactionally from schema 6 to 7; older supported
schemas pass through the existing migrations in the same transaction. Daily,
hourly, and interval coverage gain Claude source constraints and provider unions.
Legacy totals, reporting time zone, unknown accounting fields, and receipt keys
are preserved. Existing costs remain unreported.

Session timelines migrate transactionally from schema 3 to 4, adding explicit
session provider and per-event client metadata. Legacy JSON and receipt IDs are
not rewritten. Claude handoff sessions share a provider namespace while their
calls retain individual clients. Interruption and pruning flags are scoped to
their provider.

Legacy history and saved-timeline consent migrate to Copilot-only preference
keys. Claude defaults off independently for both operations. Application routing
and controls now support independent provider consent. Claude timelines contain
reported numeric model calls only; saving them does not enable lifecycle reporting.
Disconnect preserves retained usage and timelines.

**Downgrade limit:** older binaries cannot open history schema 7 or timeline
schema 4. They must report unsupported schemas, not reset the archives. Keep
backups before testing upgrades; there is no reverse migration. Unknown future
schemas and failed migrations leave existing data unchanged.

## Synthetic validation

`ClaudeCodeTests` and the shared `ClaudeCodeChecks` exercise accounting, missing
fields, malformed numbers, privacy stripping, excluded producers, batch limits,
handoff replay, provider queries, cost-overflow rollback, legacy migrations,
future schemas, owned settings, provider deletion and independent consent. `make smoke-telemetry` executes these
checks; `make smoke` includes telemetry and shared contract checks.

```sh
xcrun swift test --filter 'ClaudeCodeTests|TelemetryTests|SourceHistoryTests|UsageHistoryTests|HistoryLifecycleTests|SessionTimelineTests'
make smoke-telemetry
make smoke-contracts
make -o build smoke-notch NOTCH_SMOKE_ARGS=--claude
```

Rebuild the current host library before using `-o build`. Shared application
checks cover delivery/replay, independent receivers, port conflict/retry, restart,
removal, four-edge cells/clicks and synthetic full-screen folding. Native keyboard
focus is a separate `NOTCH_SMOKE_ARGS=--claude-focus` gate and is not verified
on the current host (visible focus-capable card, no key window). VoiceOver and
physical multi-display acceptance remain open.
Synthetic checks and compilation do not establish real-client acceptance.

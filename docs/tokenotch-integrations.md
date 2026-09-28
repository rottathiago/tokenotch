# Tokenotch integration contracts

The current release acceptance status is in [compatibility](compatibility.md).
The companion's engine version is a minimum contract target, not certification
of all newer clients. Both local clients must pass real delivery acceptance.
Account reads support stdio protocols 2 and 3 and reject an unknown protocol
before auth/quota RPCs. Background polling uses the headless runtime to load
saved credentials; only a deliberate sign-in starts the browser flow.

Documentation checked September 22, 2026:

- [CLI hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)
- [VS Code hooks (Preview)](https://code.visualstudio.com/docs/agent-customization/hooks)
- [VS Code event schemas](https://code.visualstudio.com/docs/agents/reference/hooks-reference)
- [GitHub Status API](https://www.githubstatus.com/api)
- [Copilot SDK usage and billing](https://github.com/github/copilot-sdk/blob/main/docs/features/usage-and-billing.md)
- [Copilot SDK authentication](https://github.com/github/copilot-sdk/blob/main/docs/auth/authenticate.md)

## Account quota and live token extension

VS Code per-call usage now has a separate supported OpenTelemetry ingestion path;
it is not obtained from hooks or the account quota API. See **VS Code telemetry**
below for its independent consent, compatibility and import contract.

Settings → Usage invokes the installed official CLI's `login --web-flow` after
user consent, with a separate private `COPILOT_HOME` and no ambient auth tokens.
It uses the documented Content-Length-framed stdio runtime (`--headless --stdio`)
for `status.get`, `auth.getStatus`, and `account.getQuota`. Do not pass
`--no-auto-login` to account refreshes: that flag disables saved-credential loading,
including the account just authorized through Tokenotch. Headless mode does not
initiate interactive browser sign-in when credentials are missing; the refresh
reports that sign-in is required. A new process per
refresh avoids displaying a process-lifetime cache as newly fetched data.
Requests are bounded, no session is created, and raw RPC errors are not exposed.

The account quota ring is runtime-reported **requests**, not raw tokens or AI
credits. Unknown quota fields fail explicitly. Unlimited, absent, zero and
stale values remain distinct. Future runtime-reported reset dates are shown
without treating an elapsed countdown as evidence of a reset.

An optional CLI extension uses the published `joinSession`, `assistant.usage`,
`session.usage_info`, `session.compaction_start` and `session.compaction_complete`
event surfaces. It forwards only session/call/event IDs, the event timestamp,
bounded integer input/output token counts, optional bounded ASCII model
identifiers, numeric context-window counts and optional latency/compaction fields through the helper.
The helper hashes IDs, strips everything else and sends the existing private
IPC envelope. Unknown models remain explicitly unavailable, not an inferred
default. Context counts require a positive limit; over-limit readings remain
visible numerically while the progress bar is capped at 100%.

The app deduplicates token calls in a bounded in-memory 24-hour window (4,096
calls) and retains the latest context reading for at most 100 sessions. Older
or duplicate context timestamps cannot overwrite newer readings. Context is
marked stale after five minutes. Neither token nor context events alter task
state or trigger task-completion notifications. Settings shows today's retained tokens
using the local calendar/time zone, plus model/session breakdowns over all
retained samples. Call-limit eviction is explicitly flagged as partial totals.
The latest 100 sessions and the 100 models with the most observed tokens are
listed, while totals include all retained calls.
Restart, clear live observations and CLI removal reset these memory-only observations.
Neither the extension nor the app creates prompts, tools or inference requests.
Node dependencies come from the installed CLI, not a downloaded package.

### Live per-session context

The notch places a context meter beneath each displayed session's status, with
the same reading in Settings. Context is independent of the usage-history source
and period filters. Missing readings have an explicitly **Not reported** dashed
track; old readings show **stale**, not a silently disappearing or current-looking
bar. Hover and accessibility descriptions include exact counts and observation time.
VS Code OTel input/output totals are never used to estimate context.

`session.usage_info` is authoritative. Once a root session reports usage, its
counts, limit and observation time remain unchanged on stop/idle and periodic
polls until another usage event or an explicit context invalidation arrives.
An attribution estimate must not replace the reported percentage after work
finishes or keep an old reading looking fresh.

Before reported usage is available, the CLI extension reads the experimental
`session.rpc.metadata.getContextAttribution()` on attachment, every 30 seconds,
and on root turn/idle signals. The local SDK contract was checked September 28,
2026. Snapshot fallback requires a resolved model (`modelSource` must not be
`default`) and nonempty conversation tokens (`categories.messages`). Empty
conversations, fallback-model estimates and null/uninitialized snapshots remain
**Not reported**, not a guessed startup percentage or zero. Likewise, a usage
event with zero `messagesLength` withdraws the previous reading.

Only the snapshot's `totalTokens` and `promptTokenLimit` are forwarded: the
runtime resolves the selected model/context tier (including Auto), so Tokenotch
does not maintain a model-capacity table. Once initialized, context still includes
system instructions and tool definitions, not just conversation growth.
Attribution entries, source names, message counts and model metadata are
discarded. The snapshot denominator is the runtime's prompt budget, excluding
the output reserve; usage events retain their reported `tokenLimit`.

Root `session.model_change`, `session.model_deselected`, `session.truncation`,
`session.snapshot_rewind`, `session.context_cleared`, and compaction signals
invalidate the previous reading; completed changes allow snapshot fallback again.
Extension attachment also invalidates any old reading for that session. The CLI
reloads extensions on `/clear` and foreground-session replacement, so the joined
session ID remains authoritative. Context-clear events also handle resets that
do not reload the extension.
Subagent context/compaction signals cannot replace the root session's context.
Clearing or changing context does not reset cumulative token usage.

Only one context RPC can be outstanding. Five-second timeouts, unsupported RPCs
and malformed responses produce sanitized warnings, not fabricated counts.
An in-flight reply predating a model change or usage event is discarded;
after a model change during a read, one follow-up read obtains the new window.
An authoritative event takes precedence over an estimate even if its source
timestamp equals or precedes the snapshot's local read time, provided it does
not predate an invalidation or a previously accepted usage event. Forwarded
timestamps remain increasing so the native ledger can accept that replacement.
The numeric event path remains available on older runtimes without snapshot RPCs.
Polling failures eventually leave the last reading explicitly stale.

The helper's schema-2 CLI-only `contextInvalidated` metric contains hashed
session/event IDs and a timestamp, with no token count. The app keeps a bounded
24-hour invalidation timestamp so delayed observations cannot resurrect a
previous window. It clears obsolete high-context notices without inferring task
completion, and is not written to usage history or saved timelines. Successful
snapshot readings use the existing context envelope, retention and consent.
Reinstall/repair in Connections, then reload extensions or restart **each** CLI
session; an app update cannot reload another process's extension.

## VS Code telemetry

The installed VS Code lifecycle hooks target the **Local** harness. They do not
establish lifecycle or attention coverage for Copilot sessions on Agent Host,
whose SDK hook implementation is distinct. Agent Host usage below is a separate
numeric telemetry source, not proof of lifecycle-hook parity.

The setup companion uses public VS Code configuration APIs. Local Chat uses
`github.copilot.chat.otel.*`; the separate Agent Host uses
`chat.agentHost.otel.*`. These are not interchangeable. The initial contract
target is VS Code 1.138.0. Configuration and actual delivered observations have
separate status; neither fixtures nor settings alone certify a running client.
Native setup requests encode expiry as whole Unix seconds, matching the
companion's integer-only validation for lifecycle, usage and removal requests.
Onboarding and Settings share these setup controls and approval handling.
First-run completion requires one successfully configured local client, not
observed delivery; a companion installation or unapproved hook alone is insufficient.
Settings shows an independent **Configured** or **Not configured** badge beside
each client, using the same setup checks. CLI setup requires its installed helper,
hooks and usage extension; VS Code requires its installed helper/hooks and approved
activity settings. Optional VS Code model and token usage has a separate status.
The badges are rechecked when Connections opens and when Tokenotch becomes active.
Waiting for data or having no recent data does not undo a configured connection;
missing setup files, disconnection or managed policy do. The activity and usage
rows continue to report delivery separately, rather than treating setup as proof
that a running client is sending data.
Pending approval is checked independently of the visible Settings tab. Relaunch
restores the workflow but requires a fresh request for an interrupted operation;
old nonces are not replayed.

Consent configures HTTP/JSON to an installation-specific endpoint on
`127.0.0.1`, with a credential-bearing path and producer-specific suffix.
No global environment variables, existing external collectors, telemetry-off
settings or managed policy are overridden. The helper/CLI Unix socket does not
admit VS Code metric envelopes; only the separate authenticated OTel adapter
creates those observations.

Only completed `chat` model-call spans from the allowlisted Copilot producer
are counted. `invoke_agent` totals, metric histograms, log-event mirrors and
tool/hook spans are excluded. The Local endpoint rejects `github-copilot`
terminal/SDK-native spans rather than counting terminal CLI usage twice.
Separate Agent Host collection uses its dedicated configured endpoint.
Legacy background wrappers without unambiguous source attribution remain
unsupported rather than being relabeled as Local Chat. Conversation identity
comes from `gen_ai.conversation.id`, never the window resource `session.id`.
Calls without that identity retain numeric usage but have no invented shared
session or lifecycle link.

The verified token mappings use inclusive input: subtract known cache-read and
cache-creation counts once, preserve reporting availability, and keep output
inclusive of reasoning. Model comes from response model, falling back to the
reported requested model; it is never a guessed default. Optional call duration
and first-token latency are numeric only. Context-window occupancy, compaction
and lifecycle state are not inferred from token spans.

The receiver bounds requests to 4 MiB, headers to 16 KiB, a batch to 2,048 spans,
and concurrent connections to eight with a five-second deadline. Unsupported
encodings (including compression), malformed/oversized messages and admission
failures remain visible. HTTP JSON supports bounded fixed-length and uncompressed
chunked framing. Unused
metrics/log routes are deliberately discarded and do not refresh usage status.
Raw telemetry is never logged or persisted; unrelated metadata is stripped.

Usage schema 4 carries explicit metric origin independently of lifecycle client.
Legacy CLI envelopes and their freshness rules remain unchanged. Delayed live
OTel usage can enter the retained 24-hour metric window; an explicit import uses
separate historical admission and never enters live session or notice state.
Source-aware history migration preserves all legacy counts as CLI. Its durable
keyed VS Code call receipts prevent replay after the older CLI deduplication
window, including overlapping live observations and imports.

Historical import reads only an explicitly selected supported export, not private
VS Code conversation storage. It verifies the format and previews the result
before consent. A selected SQLite export is read-only, including its applicable
WAL companions; unsupported schemas fail explicitly. Previously unrecorded usage
cannot be reconstructed. Imports preserve original times and reporting zone,
mark coverage partial, and add no recording-opportunity seconds. Historical
usage never generates timelines, notifications or working-session state.

Recognized inputs are OTLP JSON, the verified Node ReadableSpan and Agent Host
completed-span JSONL layouts, and schema-1 exported trace databases with sufficient
source provenance. Resource-less Local SQLite exports cannot establish the producer
and are explicitly unavailable, not relabeled based on a filename or picker.
WAL-mode exports require both accompanying WAL and SHM files; inconsistent snapshots
are rejected. Input limits are 64 MiB combined, 4 MiB per record, and 100,000 spans.
No persistent raw copy is made. The preview is fingerprinted and checked again
before the first committed batch; retrying uses durable call identity.

The companion's owned-settings receipts support idempotent setup and selective
removal. Values edited after setup are left intact, as are unrelated hook entries.
Stopping metrics invalidates Tokenotch's receiver credential independently of editor
reload. Removing a source does not erase saved history or stop other sources.
The account quota RPC, account selection, ring thresholds and billing semantics
are not changed.

### Cache reporting availability

The usage extension forwards optional `assistant.usage.cacheReadTokens` and
`cacheWriteTokens`, with explicit Boolean `cacheReadTokensReported` and
`cacheWriteTokensReported` markers. A valid numeric value, including
zero, is forwarded with `true`; an absent runtime field is omitted with `false`.
Invalid supplied counts or contradictory/non-Boolean markers remain delivery
errors. Current CLI usage requires `usageContract: 1` in the schema-1 envelope;
older incompatible accounting must be repaired before collecting new usage.

The helper carries the markers as `cacheInputReported` and `cacheWriteReported`. Missing
metadata denotes a legacy observation, not a confirmed zero. Numeric sums
continue to retain known amounts; live and saved aggregates additionally count
reported and unreported calls, with legacy coverage derived from the remaining
calls. Mixed groups are partial even when their known cache sum is zero.

The historical usage-history schema-3 migration added cache-read coverage to schemas 1/2.
Existing sums and calls are preserved; old coverage is unknown, never
backfilled. Timeline schema 1 stores the additive per-event marker in JSON and
continues to read older records conservatively. Consent and retention do not
change. Current history uses schema 6, including source attribution and durable
VS Code replay receipts; cache-write accounting remains distinct from legacy
unknown coverage.

The notch keeps cache-read and cache-write detail inline: a complete numeric reading, `Not
reported`, `Unknown`, or a known amount followed by `*` for partial reporting.
One shared note explains the asterisk. Exact values and coverage are available
in help, accessible descriptions, Settings, and timeline details. Daily charts
omit unavailable cache components and explain partial known amounts. Raw totals
equal runtime inclusive input plus output. Known cache-read/cache-write counts
are subtracted once from inclusive input to show disjoint categories, not added
to that total a second time. With incomplete cache reporting the remaining input
is labeled as a breakdown-incomplete remainder.
This reporting coverage is distinct from partial local observation coverage.

Reinstall through Connections and reload/restart each CLI session to update
both helper and extension. A stale helper/extension that drops the marker is
treated as legacy/unknown. Neither synthetic cache fixtures nor these UI states
prove the installed runtime emits positive cache hits. Cache writes are recorded
when reported, with their own availability marker. No cache-hit rate, billing
estimate, or cache-control behavior is introduced. Current usage contract 1 is
required for live metrics; older incompatible helpers require repair rather
than entering new totals. Legacy saved accounting remains distinguishable.

### Live CLI activity

The same opt-in extension calls the SDK's experimental
`session.rpc.metadata.activity()` on attachment, every 30 seconds, and on root
`assistant.turn_start` / `session.idle` signals. It forwards only the joined
session ID, the read's start timestamp, and the strictly Boolean `hasActiveWork`
value. This is an actual runtime snapshot, not an inference from token usage,
process existence, subagent events, or elapsed time. It can detect ongoing work
when loaded mid-turn and recover after Tokenotch restarts without another prompt.

There is at most one outstanding activity read. Reads taking five seconds or
more, unsupported methods, malformed responses and RPC failures do not refresh
the state; a sanitized warning is emitted. A stuck RPC cannot accumulate further
requests. A later successful read recovers normally.

The helper maps these reports to schema-2 CLI-only `active` / `idle` snapshots.
They share the lifecycle session hash and timestamp ordering, but never produce
completion notifications, daily usage or saved timeline rows. Explicit
end/cancellation/failure outcomes are not replaced by an idle snapshot.
Snapshots expire after 90 seconds without an update; lifecycle-only work keeps
its five-minute freshness window. Idle does not imply task success. The notch
and menu use the same working predicate and disclose missing activity coverage.
An open CLI window is not necessarily working.

Update through **Connections → Copilot CLI → Options → Review or repair setup**, then reload extensions or
restart every existing CLI session. Updating one session cannot reload another
process's extension. Unsupported CLI versions retain hook-only coverage with an
explicit extension warning. VS Code live activity remains hook-only; telemetry
usage does not establish activity. No transcripts, session
enumeration, credentials, new prompts or inference calls are needed.

### Minimalist notch presentation

The notch orders observed activity, account allowance, and usage by model.
The quota ring and card both label the reported percentage used.
A collapsed dot indicates fresh observed work and an attention mark
indicates a supported current exception. These indicators do not change
notification consent or automatically expand the panel.

Today uses the archive's fixed reporting zone when a saved archive exists.
Last 7 days includes today and the preceding six reporting days. Both totals
and model rows come from the same selected-period query, not the wider query
used for completed-week comparisons. Paused saved data remains labeled.
Without an archive, Today can show labeled retained live samples from the selected source, filtered
by the Mac's current day; Last 7 days requires history consent. Loading and
storage failures never silently substitute a different source.

The compact view shows the top three named models ranked by observed tokens,
with stable ID tie-breaking. When more named models exist, **Show all models**
expands them inside the card; **Show fewer models** restores the compact view.
Both Today and Last 7 days use this behavior. Expansion survives usage refreshes,
but closing the card or changing the period resets it; no preference is saved.
Long lists scroll while View history and Settings remain reachable.

One residual row includes all undisplayed, unknown and overflow model groups;
expanded named models leave that row, keeping token and call totals unchanged.
Unknown IDs and archived detail-limit overflow remain explicitly aggregated:
expansion cannot reconstruct unavailable model identities. The residual still
opens the full breakdown, not a fictional model, separately from the disclosure
control. No model cost, account attribution or pricing multiplier is inferred.
Exact counts, source zone and limitations remain accessible.

History links preserve the selected period and model. Live links open a
captured Today breakdown in Usage. The full live session list, account quotas,
context/latency details, saved timelines and comparison evidence remain in
Settings. No consent, storage schema, retention or event contract changes are
required by this presentation.

### CLI developer-attention reports

The separately installed camelCase CLI `notification` hook uses the exact matcher
`permission_prompt|elicitation_dialog`. Its documented payload combines
`sessionId` and epoch-millisecond `timestamp` with `hook_event_name: "Notification"`
and `notification_type`. The helper maps those types to schema-3 `approvalRequested`
and `inputRequested`. Other well-formed notification types are ignored.

The CLI `errorOccurred` hook maps a strictly Boolean `recoverable: false` to
schema-3 `unrecoverableError`; `true` is a valid ignored observation. Missing or
malformed fields remain delivery errors, not successful ignores. An unrecoverable
error is not mapped to `failed`: only `sessionEnd(reason: "error")` reports session
termination. Both error reports share the existing CLI error category and an
observed error-episode receipt, avoiding duplicate alerts until explicit new work
supersedes the episode. Each normalized event also has its own persistent receipt.

Attention events are separate from lifecycle and metric events. They cannot
change the live working count and do not enter daily history or saved timelines,
including direct timeline-store admission. No SDK extension change, polling,
permission handler or transcript access is needed. The helper returns no stdout
or `additionalContext`. In particular, `permissionRequest` is not installed:
it runs before permission rules and automatic approvals, so it is not proof
that a user prompt is shown.

Only enumerated kind, hashed session identity and timestamp cross IPC. Notification
messages/titles, prompts, commands, paths and raw errors are discarded. The
documented hook has no request ID; source/session/kind/timestamp define duplicate
identity, including indistinguishable same-kind reports in the same millisecond.

The input/approval desktop category starts off for both new and existing users.
It reuses master mute, managed policy, channels, snooze and quiet hours without a
suppressed-event backlog. Passive in-app indicators do not require desktop
consent. Error notices take priority over request notices, which precede metric
warnings and stopped/working rows.

There is no documented answer/approval-completed counterpart. Request notices
remain explicitly last-reported with response status unknown. New prompts and
terminal outcomes supersede older requests without claiming successful resolution;
active/idle/stop reports, metrics, viewing and elapsed time do not. Dismissal hides
the current report; a distinct later request can notify again. Old observations
cannot reopen notices across newer work/terminal boundaries. Same-time prompt or
terminal evidence takes precedence over a request, not a guessed chronology.

Session notifications carry only allowlisted source and notice-local pseudonymous
session/notice IDs. Clicks open matching Tokenotch details through the app's window
owner, not a terminal command or event-provided URL. Old targets show the same
session's current notices with a disclosure, or an unavailable-details message
after clear, eviction or an unsaved restart. Routing does not mark newer notices
viewed. Open Terminal remains an app-level action, not exact-session focus.

Reinstall through Connections and start/restart each CLI session to load the
updated hooks. Actual dialog/error hook delivery and native notification clicking
must still be accepted on recorded client/OS versions. The hook reference and
synthetic/native fixtures alone do not certify the installed CLI. VS Code has no
documented counterpart; CLI PascalCase compatibility does not change that.

### History and session insight contracts

Existing lifecycle/usage/context messages remain schema 1, with additive optional
`durationMs` and `timeToFirstTokenMs` on token readings. Compaction uses schema 2,
as do the memory-only active/idle snapshots. Compaction has
a hashed metric ID and only start/completion status, success and optional
before/after counts. Update both the helper and extension through
**Connections > Copilot CLI > Options > Review or repair setup**,
then reload each CLI session. Unsupported events/versions are rejected,
not interpreted as task completion. Older token events without latency still work.

Context envelopes also support an additive optional hashed `metricID` derived
from the extension's existing `eventId`. Legacy context envelopes without an ID
remain supported, using a normalized timestamp/count fallback for timeline
deduplication. Lifecycle hooks have no event ID or sequence: identical normalized
observations are deduplicated and same-time ordering remains explicitly unknown.

Latency comes from `assistant.usage.duration` and `timeToFirstTokenMs`, in
milliseconds. Values must be finite, nonnegative and no greater than 24 hours.
The extension drops invalid optional fields with a sanitized warning without
discarding valid token counts; the helper rejects malformed supplied fields.
The optional compaction counts use the existing billion-token bound.
Compaction summaries, paths, raw errors and tracing IDs never cross the helper.
Numeric missing data stays unavailable, not zero. Live insights are bounded to
100 sessions, with 24-hour expiry and five-minute freshness.

Context warnings use a new notification category that starts off. A fresh
below-to-above 80% crossing can warn, rearming below 70% with a ten-minute
per-session cooldown. Initial samples and stale-to-fresh transitions establish
a baseline. Quiet/snoozed/disabled notifications are consumed without replay.
Compaction state is visual and separate from lifecycle/failure notifications.

History requires separate opt-in. Tokenotch writes daily aggregates to private system
SQLite storage off the main thread, with atomic updates and hashed deduplication
receipts. Committed history is independent of memory-ledger eviction. Batches are
at most 50 events or one second; the admission queue is capped at 256. A crash can
lose the pending batch and marks the prior recording interval interrupted on reopen.
CLI receipts expire on a ten-minute maintenance window or clean recording stop; daily
aggregates have no automatic age limit. The archive records no permanent session
IDs and does not equate local observations with the quota account.

The reporting zone is fixed at first opt-in; day/month comparisons use calendar
boundaries, weighted latency sums/counts, and explicit partial/missing-data copy.
The UI queries at most a selected month/rolling period rather than loading every
historic day. Per-day model detail is bounded to 100 model keys plus a labeled
overflow group; totals remain intact. Context/compaction aggregates are not
model-attributed. Pause or integration removal preserves history; confirmed
deletion is serialized with ingestion to prevent queued resurrection.

Published schemas and the installed CLI version were checked; live signed-in
delivery of latency/compaction events remains unaccepted. Missing optional
signals must not prevent supported token history from working.

### History insights and saved timelines

Settings History compares the last seven completed days against the preceding seven
in the aggregate archive's fixed zone. Each metric links to its exact evidence
snapshot in Settings, including days, samples, missing fields and known gaps.
Mix uses model-call shares (including unknown/overflow buckets); latency uses
independent weighted means; compaction frequency uses successful plus failed
completions per 100 observed calls, excluding starts and model attribution.

Directional claims require fourteen sampled days, collection beginning before
the window and no known gaps. Mix needs 20 calls in each period. Each latency
field needs 20 samples and 80% coverage of calls in each period. Compaction
rates require observed completions and calls in both periods; no completions is
not proof of zero. Changes are descriptive, not causal or statistically
significant claims. Recording pauses/resumption and shutdown gaps are tracked;
undetected upstream loss is still possible.

Session timelines use separate consent, SQLite storage and deletion, with
seven-day default retention (one/seven/thirty selectable), 1,000 sessions,
2,000 events/session and 100,000 events globally. Archive-local pseudonymous
keys permit grouping across restarts without retaining raw IDs or stable bridge
session hashes. Only allowlisted fields are persisted. See
[privacy and operations](tokenotch-privacy.md) for retention, bounded receipts,
interruption markers, sidecar protection and deletion semantics.

Validated events reach the timeline independently of latest-state filtering,
daily-history opt-in and notifications. Legitimate late arrivals within the
existing ingress window can appear chronologically without rolling back the
live state or replaying notifications. Differences between observed model
identifiers/context readings are annotations, not new source events. Ambiguous
same-time transitions are not inferred. Context drops do not establish
compaction, and execution stops do not establish success.

No new runtime subscription is required. Reinstalling updates the helper's
context-ID preservation; older schemas continue to work with limited identity.
VS Code supports its documented lifecycle rows and separately collected,
source-attributed live usage rows. Historical usage imports do not create timeline
rows. Optional CLI event
delivery remains a live-client acceptance gate.

The installed 1.0.87-0 runtime was checked for unauthenticated `status.get` and
`auth.getStatus` transport behavior using `--no-auto-login` in an empty profile.
A local 1.0.89-4 (protocol 3) check also verified saved-login authentication and
quota reads through Tokenotch's headless runtime without that flag. These local
checks do not replace browser-login, quota and event-delivery acceptance of the
signed release artifact. Synthetic tests cover saved-login refresh on protocols
2 and 3, signed-out polling, unknown-protocol rejection, fractional quota values,
identity changes, cancellation, rate limiting, split RPC frames, token
deduplication, extension content stripping and exact-owned removal.

| Capability | CLI adapter | VS Code adapter | Evidence / release status |
| --- | --- | --- | --- |
| Session observed | `sessionStart` | `SessionStart` | Published schema; synthetic fixture |
| Working | Live `metadata.activity` snapshot; `userPromptSubmitted` fallback | `UserPromptSubmit` | Runtime snapshot or explicitly last reported state; no process-count inference |
| Idle | Live `metadata.activity` snapshot | Unavailable | Not task success; memory-only, no completion notice |
| Execution stopped | `agentStop`, `stopReason=end_turn` | `Stop` | Does not mean success/session ended |
| Session failed | `sessionEnd`, `reason=error` | Unavailable | Terminal lifecycle, distinct from an unrecoverable-error report |
| Unrecoverable error reported | `errorOccurred`, `recoverable=false` | Unavailable | Error category; recoverable failures ignored; no invented termination |
| Session notice acknowledgment | Displayed stop/error/metric notices | Displayed stop notices | Viewed is distinct from resolved or dismissed; no new client event schema |
| Session cancelled | `sessionEnd`, `reason=abort` | Unavailable | No completion notification |
| Session ended | complete/user_exit/timeout | Unavailable | Timeout is not task failure |
| Input/approval requested | `notification`: `elicitation_dialog` / `permission_prompt` | Unavailable | Published contract and fixtures; real client delivery not yet accepted |
| Answer/approval completed | Unavailable | Unavailable | Last-reported requests, never inferred from time/activity/tool events |
| Nested agents | Not individually monitored | Not individually monitored | No subagent completion notifications |
| Account identity | Unknown | Unknown | Not a billing identity assertion |
| Exact-session focus | Unavailable; Open Terminal | Unavailable; Open VS Code | Only allowlisted app activation |
| Account quota/login | Official CLI browser flow and experimental quota RPC | Same selected monitor account; no IDE identity inference | User sign-in required; not enterprise billing |
| Live tokens / model breakdown | Opt-in `assistant.usage` extension | Separate opt-in OTel receiver | Per-call counts, not hook fields or account-wide totals; real delivery acceptance required |
| Session context meter | Opt-in `session.usage_info` and optional context snapshots | Unavailable | Last reported counts; stale after five minutes, no compaction prediction |
| Persistent session notices | Separate local opt-in | Same opt-in for supported stops | Bounded operational metadata, not transcripts/history; restart never restores a working count |
| Persistent usage history | Separately opt-in daily aggregates | Source-attributed OTel usage and confirmed supported imports | Partial local coverage; durable VS Code replay receipts |
| History trend insights | Daily model/latency/compaction aggregates | Observed model/optional latency counts | Imported/partial coverage cannot imply continuous collection |
| Saved session timeline | Supported lifecycle and optional metric events | Lifecycle and independently collected live usage | Separate consent/retention; imports excluded |
| Model latency | Optional `assistant.usage` fields | Optional numeric OTel span timing | Numeric fixtures, not a claim of accepted real-client delivery |
| Compaction state | Optional start/complete events | Unavailable | No summary/path retention; real client delivery not accepted |
| High-context warnings | Separate opt-in category | Unavailable | Baseline/cooldown/notification policy fixtures; no compaction prediction |
| AI-credit enterprise billing | Unavailable | Unavailable | Outside 1.0.0; not a gate to add this feature |
| Real client versions | Not yet accepted | Not yet accepted | Both required before public distribution |
| Remote hosts | Unsupported | Unsupported | No network forwarding service |

Only camelCase CLI events are installed, with `exec`/`args`, in the CLI hook
directory. The VS Code file is installed in a **separate** location selected
through the documented `chat.hookFilesLocations` user setting. PascalCase CLI
compatibility is intentionally not used: its payload would be indistinguishable
from VS Code's. Do not copy the VS Code file into the CLI hook directory.

The helper requires a session ID; missing identity is rejected instead of merging
unrelated sessions. IDs are SHA-256 hashed, not interpreted as paths. CLI time is
epoch milliseconds; VS Code time is ISO 8601. The hook socket accepts only schema versions 1, 2 and 3, enumerated
sources/kinds, bounded hashes/timestamps/model identifiers and validated numeric
token/context/latency/compaction counts reach the app. Future events over
30 seconds ahead and events older than 120 seconds are rejected. Ties use
monotonic lifecycle precedence because these hooks provide no sequence number.

Tokenotch never reads transcript paths, prompts or tool arguments. Input is at most
64 KiB with a 500 ms read deadline; oversized input is dropped, not truncated
into a success-shaped event. IPC envelopes are at most 4 KiB; socket reads have
a 100 ms deadline and a 30-connections/second budget. No output or permission
decision is returned to the agent. Sanitized local failure markers/logs expose
delivery failure without echoing payloads.

The bridge uses a single-instance lock, private socket, peer UID and per-client
registration. This excludes other OS users, not malicious programs already
running as the same user. Events are **untrusted activity hints**, never billing
identity or authority to execute commands. No event-supplied path/URL is opened.

## Live-client acceptance procedure (not yet completed)

On an isolated macOS user profile, record app commit, OS, architecture, CLI
version, VS Code version and Copilot extension version. For **each** client:

1. Confirm no hook exists before consent. Install; retain an unrelated user hook.
2. Start a local interactive session, submit a harmless prompt, observe working
   then stopped. Confirm no prompt/path appears in diagnostics or notifications.
3. Run concurrent sessions and a subagent; verify no duplicate parent completion.
4. End/cancel/error a CLI session; verify the documented, distinct labels.
5. Disable hooks through supported user/workspace configuration; show missing
   coverage rather than inventing completion. Do not override enterprise policy.
6. Stop Tokenotch, trigger hooks and check that agent work is unaffected; restart and
   inspect the sanitized delivery-health marker. Do not replay historical alerts.
7. Exercise master mute, category/channel toggles, permission denial, snooze and
   quiet hours. Confirm only one sound and no backlog after resuming.
8. Move the app, reinstall after an update, uninstall both clients; confirm
   unrelated hooks/configuration and other installed products remain unchanged.
9. With history off, verify no database is created. Enable it, observe new calls,
   restart Tokenotch, and compare committed totals across days/months. Pause recording,
   remove/reinstall the CLI integration and confirm saved history remains.
10. Confirm real optional first-token latency, call duration and compaction
    delivery. Missing fields stay unavailable; compaction does not produce
    task-completion/failure notices. Exercise opt-in high-context warnings.
11. Delete usage history during activity and verify no old queued samples
    reappear. Exercise local storage failure/retry and interrupted recording
    without exporting private state. Confirm charts/tables and timezone labels
    are understandable and keyboard/VoiceOver accessible.
12. Open each Settings History insight and confirm its evidence matches the displayed
    periods and metric. Check missing latency/model fields and sparse histories
    suppress unsupported headlines, and no comparison includes today's partial day.
13. Separately enable timelines. Observe CLI and VS Code sessions, restart Tokenotch,
    pause/remove one integration, and verify the other still records supported
    events. Confirm stop is not success and no VS Code metrics are invented.
14. Exercise retention reduction, cap truncation, deletion during activity and
    archive identity rotation with synthetic local fixtures. Clearing live
    observations/daily history must not erase saved timelines. Check session
    navigation and progressive loading with keyboard and VoiceOver.
15. For CLI, explicitly enable the input/approval category and trigger a harmless
    question and an actual permission prompt in concurrent sessions. Verify one
    generic banner per report and that each click opens matching Tokenotch details.
    Confirm auto-approved tools, prose-only questions and background completion
    do not become request alerts. Capture no prompt/command content.
16. Answer/deny/cancel requests and confirm Tokenotch keeps honest last-reported
    wording, with no fabricated response event. Verify new prompts/terminal
    outcomes supersede earlier requests, and quiet/muted reports do not replay.
    Check unrecoverable-error delivery separately from terminal failure and
    recoverable tool errors. Test notification targets after restart and clear.

Synthetic fixtures prove adapter/policy behavior, not a client support matrix.
The customer release remains blocked until both integrations and the approved
usage/authentication path pass their separate acceptance gates.

# Privacy and operations

For a diagram-based walkthrough of how usage is captured, see the
[architecture overview](architecture.md).

Tokenotch has no backend or app telemetry. It does not discover tokens or read
client credential databases. After explicit sign-in consent it invokes the
official Copilot CLI for browser authentication and read-only account quota RPCs,
never to create a session or perform inference. The CLI manages its own credentials
and GitHub services; Tokenotch does not receive the access token. The optional metrics
extension observes numeric usage/context/latency/compaction events and model identifiers in sessions
the user is already running. It also reads the joined session's Boolean
active-work status through `session.rpc.metadata.activity()` every 30 seconds.
Only the session ID, timestamp and active/idle value reach the helper; it hashes
the ID as for lifecycle hooks. These snapshots stay in memory, expire after
90 seconds without updates, and never generate completion notifications or
saved timeline rows. It does not read session logs or transcripts.

VS Code usage has separate opt-in configuration through a local setup companion.
The companion uses public settings APIs and preserves unrelated settings; it
does not access Copilot internals. Tokenotch's credential-protected receiver binds
only to loopback and forwards nothing. Supported per-call telemetry is reduced
to source, model IDs, numeric counts/timing and hashed identifiers before entering
Tokenotch storage. Prompts, responses, tool/hook payloads, repository metadata and raw
spans are discarded, even if present in incoming telemetry. Tokenotch-managed content
capture is off. An existing external collector or policy is not silently changed.

| Data | Location / retention |
| --- | --- |
| Notification/appearance choices | `io.github.rottathiago.tokenotch` UserDefaults domain |
| Source registrations and installation receipts | Owner-only `~/.tokenotch`; removed with each integration |
| Stable helper executable | Owner-only `~/.tokenotch`; remains for explicit manual cleanup |
| Normalized session hints | Memory only; up to 100; expired after 24 hours |
| Consumed notification hashes | Private `notifications.json`; up to 4,096 / seven days |
| Delivered desktop notifications | macOS Notification Center; generic copy, pseudonymous session label and notice-local routing IDs; retained under OS/user controls, separately from Tokenotch notice storage |
| Session notice state | Memory by default; separately opt-in private `session-notices.json`; up to 100 session records and 4,096 deduplication receipts |
| Hook failure health | Fixed allowlisted marker; cleared explicitly in Settings |
| Public service health | Memory; refreshed no more than every five minutes when enabled |
| Observed input/output token calls and model identifiers | Memory only; up to 4,096 calls / 24 hours; no historical replay |
| Context-window counts and limits | Memory only; latest reading for up to 100 sessions / 24 hours; stale after five minutes |
| Live latency and compaction state | Memory only; latest readings for up to 100 sessions / 24 hours; stale after five minutes |
| Opt-in usage history | Private `~/.tokenotch/history/usage.sqlite`; daily token/model/latency/context/compaction aggregates until manually deleted |
| Hourly usage detail (same history opt-in) | Total tokens, call counts and recording opportunity/gaps in the same private archive; latest seven reporting days; no hourly model or session identifiers |
| Separately opt-in session timelines | Private `~/.tokenotch/timeline/sessions.sqlite`; allowlisted event metadata and archive-local pseudonymous IDs; seven days by default, selectable one/seven/thirty days |
| Timeline bounds and interruptions | Up to 1,000 sessions, 2,000 events/session and 100,000 total events; bounded truncation/interruption markers and up to 18,000 short-lived keyed receipts |
| History recording opportunity/gaps | Daily and hourly recording seconds and interruption markers in the same local database; not proof of complete CLI coverage |
| CLI history ingestion receipts | Hashed metric IDs only, bounded by the admitted event rate and ten-minute window; pruned on writes/checkpoints/open and cleared on a clean recording stop |
| VS Code usage receipts | Keyed, nonreversible call hashes retained with daily history until deletion; prevent duplicate live delivery and repeated/overlapping imports |
| VS Code local receiver configuration | Private `vscode-telemetry.json`; local installation credential and port, removed on metrics withdrawal |
| VS Code setup exchange | Private expiring request/result and owned-settings receipt; no prompts, raw telemetry or unrelated settings |
| Connected account identity/quota | Memory only; fetched every 60 seconds; cleared on disconnect |
| Separate official CLI profile | Private `~/.tokenotch/copilot-account`; contains CLI-managed configuration/credential state |

The app never retains raw hook input, prompts, responses, commands, environment,
repository names or transcript paths. The signed-in account name appears in the
usage UI, but is excluded from diagnostic text. Diagnostic text is
built from allowlisted statuses, not a log dump. Notification previews exclude
workspace names. **Settings → Privacy → Live data → Clear…** clears
live observations, session notices (including their saved ledger and local identity)
and the notification ledger/health marker, not collection
consent, saved usage history, saved session timelines or unrelated application data.
Developer-metric session labels are shortened hashes, never repository names or
raw session IDs. Model identifiers are bounded ASCII strings; unknown models and
missing context/token counts are shown as unavailable. Today's totals use the
Mac's local calendar/time zone; model/session breakdowns use retained samples.
Live metrics are partial local observations, reset on app restart, clear-live
or CLI integration removal. Call-cap eviction visibly marks live totals partial.

## Updates

Check for Updates contacts the configured public GitHub releases API only when
you select it. GitHub receives ordinary network request metadata, but Tokenotch adds
no device/account identifier and sends no analytics. Responses are bounded and
redirects are refused. A newer stable version opens a constructed official
release URL; Tokenotch does not download or install updates.

The preferences domain remains `io.github.rottathiago.tokenotch` and the private
data root is `~/.tokenotch`. Replacing the app does not delete saved preferences,
history, timelines or notices, and does not authorize new collection.
See [recovery and uninstall](support.md) for the independent retention boundaries.

## Session notice memory

The notch distinguishes live activity, unseen stopped-turn updates and unresolved
warnings/errors. Viewing a stop removes its future highlight; viewing a warning
only marks it seen. Resolution needs supported later evidence, while a newer
prompt may supersede an earlier error or compaction failure. Dismissal is an
explicit user action or, for input/approval requests in the notch, a
visibility-triggered acknowledgment; neither is proof of recovery. Missing
updates and time passing never establish recovery; stale warnings retain
last-reported wording.

Input and approval notices come only from explicit CLI dialog notifications.
The helper discards message/title content and records only enumerated kinds,
times and pseudonymous identity. Unrecoverable-error observations use the same
content stripping. Request notices say response status is unknown: viewing,
activity snapshots and stopped turns are not evidence of an answer. A newer
prompt or terminal outcome can supersede them, or they can be dismissed.
The expanded notch has a checkmark labeled **Dismiss** for each displayed pending
input/approval request. These requests also dismiss after three continuous
seconds with at least half their row visible in a deliberately opened card,
including keyboard opening, or during continued hover engagement. Closing or
hiding the card, scrolling below half visibility, or ending required hover
engagement resets the timer. Automatic notification expansion alone does not
count. Each newly displayed request receives its own full timer; dismissal
neither closes the card nor dismisses other hidden requests. It never sends an
answer or grants approval. Retained notices remain in Details as **Dismissed,
not confirmed resolved**. Other notice kinds and desktop-notification routing
and retention are unchanged.
These reports do not enter daily history or saved timelines.

`Remember session notices` is separate consent and starts off. Enabling clears
the current in-memory notice state and starts collecting new operational metadata;
it does not import timelines or pre-consent live observations. The owner-only
JSON ledger stores a version, local random HMAC key, client type, keyed
pseudonymous session/event/episode IDs, enumerated notice and disposition states,
ordering/rearming classifications and timestamps. It stores no raw bridge IDs,
active/idle snapshots, token counts, context limits, prompts, paths or raw errors.
The key enables local linkage across restarts, not anonymity or protection from
someone who can read the private ledger. It is independent of timeline identity.

There are at most 100 session-state records, each with at most one current notice
per supported category, and 4,096 receipts. Closed records and receipts expire
after seven days. Unresolved notices do not age out; at capacity, closed state
is removed first, then the oldest remaining session state. Capacity removal is
disclosed as lost older notice state, not resolution. Repeated-event suppression
is bounded by retained receipts/episode state. Cleanup runs during observation,
periodic maintenance and loading, never while Tokenotch is closed.

Atomic writes and deletion are serialized. Read/schema/ownership and write errors
remain visible; unsupported or corrupt ledgers are not silently overwritten.
Live notices continue with an explicit saving-unavailable message. Retry or a
confirmed clear is available in Settings → Sessions. Restart restores only last-reported
notices, not currently working sessions. Details can show retained notices even
when live session linkage is unavailable; exact timeline links require a matching
live session and the independent timeline archive.

Turning remembering off requires confirmation and deletes the saved file/key
while leaving current in-memory notices usable. A failed deletion does not turn
the preference off. `Clear session notices` and clear-live remove saved and live
notice state and rotate its identity; enabled saving resumes empty. Removing a
client clears that client's operational notices. Account disconnect, notification
snooze, and deleting saved timelines or daily history do not erase notices.
Logical deletion does not guarantee forensic erasure or deletion from backups.

Desktop consent is separate from remembering notices. Session notification
metadata contains only client type and notice-local pseudonymous session/notice
IDs, never raw session IDs, questions, commands or paths. macOS may retain
delivered notifications even when Tokenotch's saved notices are off or cleared;
manage that history in Notification Center. After an unsaved restart or identity
rotation, old notification targets show an explicit unavailable-details message,
not another session. Schema-1 notice ledgers migrate to schema 2 while preserving
their key and viewed/dismissed state; unsupported ledgers remain untouched.

Actual viewing is tracked transiently, not as an analytics log: deliberate
opening acknowledges rendered initial rows, and hover requires one continuous
second with at least half the row visible. Hidden rows and automatic notification
reveals are not acknowledged. Only the resulting per-notice viewed state is
eligible for opt-in persistence. Request-dismissal dwell is also transient:
only the resulting existing viewed/dismissed state can be saved, without new
analytics or saved timing fields. Informational rows remain displayed until the
card closes. On close, rows that were visible for at least half a second of
pointer engagement (or rendered in a deliberately opened card) are acknowledged:
stops become viewed and all other notices become dismissed. This engagement time
is transient and discarded when the card closes.

## Persistent usage history

History collection is off until separately enabled with the explanation in
Settings. Live collection records only new observations from connected sources
after consent/resume, not transcripts or pre-existing memory samples. Daily aggregates are independent
of the live sample limit and are not tied to the separately signed-in account.
No user/account identifier, repository name, permanent session identifier, raw
event, compaction summary or checkpoint path is archived.

An independently confirmed import can add previously recorded supported telemetry
exports to usage history even when ongoing recording is off. Selected files are
read locally; no private conversation directories are scanned. Preview shows
recognized usage and unsupported records. Imports do not create live activity,
notifications, notices or timelines. Imported dates remain partial rather than
claiming continuous recording; the original reporting zone and recording-start
metadata are preserved. Original exports remain under the user's control.

Source-aware history migrates pre-existing records to CLI without changing their
counts or accounting provenance. Source filters cannot infer an account identity.
Durable keyed VS Code call receipts add per-call local metadata/storage growth;
they expire only with the associated daily archive so importing the same usage
later remains idempotent. Delete all usage history removes these receipts too.

Daily summaries use a fixed Gregorian reporting time zone selected from the
Mac's zone at first opt-in. Traveling does not move historical activity between
days. Missing observations and latency fields remain unavailable; a blank day
does not prove zero usage. Current-month/rolling comparisons use matched
completed days, not fabricated same-clock-time totals.

The notch's Today timeline uses hourly token totals and call counts, attributed
to reported event times, not inferred compute duration or billing. Hourly detail
uses the archive's fixed zone and keeps the current and previous six reporting
days. It is recorded only under the existing history consent, with no additional
identifiers or raw events. Schema 5 adds empty hourly storage and a detail-start
timestamp without backfilling daily aggregates. A partial first day is labeled;
saved and live data are never combined to fill gaps. Without an archive, hourly
bars use only the existing bounded in-memory samples and clear with live data.

Cache reads and writes retain only their numeric amounts and reporting availability.
Daily/model aggregates count calls that reported cache usage and calls that
omitted it; older calls have unknown coverage. The schema-3 migration preserves
all existing values without reconstructing old zeros or estimating coverage.
Positive historical cache amounts remain visible as partial. Timelines retain
the same optional availability marker with each new token observation.
This adds no prompts, transcripts, identifiers, remote telemetry, or new consent.

System SQLite stores the archive in an owner-only directory with a private
database and rollback journal. Short-lived CLI receipts prevent duplicate
aggregation. An abnormal shutdown can leave those receipts on disk until the next
open/maintenance pass; normal pause or shutdown clears them. Source-aware
schema 6 additionally retains durable VS Code receipts until history deletion.
No cleanup runs while Tokenotch is closed. Daily aggregates have no automatic age-based deletion.
Hourly detail is pruned on open, writes, checkpoints and hourly reads, including
paused archives; cleanup does not run while Tokenotch is closed.
Writes are serialized off the UI thread, batched for at most one second or 50
events, with a 256-event admission queue. Uncommitted data may be lost if the
process is killed; committed totals survive. Storage/backlog failures pause
recording visibly and leave existing data intact. Tokenotch does not silently
replace corrupt/newer-schema databases or prune old data when disk space runs out.

Pausing history stops recording; removing a usage source stops only that source's
collection. Both preserve saved data subject to hourly retention. Account sign-out does not erase or
relabel the local archive.
"Delete all usage history" requires confirmation, deletes only owned history
database files/sidecars, and prevents queued observations from restoring erased
data. If enabled, recording resumes with an empty archive. This is logical
deletion, not a guarantee of forensic erasure or removal from external backups.
No database contents or private paths appear in diagnostic previews.

## Persistent session timelines

Timeline consent is separate and off by default, even if daily usage history is
enabled. Only newly admitted supported events after enable/resume are recorded.
The archive stores client type, reported time, enumerated event kind, bounded
model identifiers, numeric token/context/latency/compaction fields and local
pseudonymous keys. It never stores raw event JSON, raw session/call IDs, stable
bridge session hashes, prompts, responses, commands, source, workspace names,
free-form errors, compaction summaries, or checkpoint paths.

The archive uses a private random HMAC key to pseudonymize normalized session
and event IDs, namespaced by client. This is **pseudonymization, not anonymity**:
retained events can be linked within this archive across Tokenotch restarts. The key
is stored in the same protected local database; it does not protect against
someone who can read the archive. Deleting all timelines removes the archive
and its key; resumed recording gets a new key.

The default event age limit is seven elapsed days, selectable one/seven/thirty
days. A maximum of 1,000 sessions, 2,000 events per session, and 100,000 events
overall applies independently. Oldest events are removed first. Empty session
records are removed, and a saved timeline affected by pruning, truncation or a
recording interruption is labeled as possibly incomplete when opened. Short-lived keyed receipts prevent immediate
replay of pruned events and expire after ten minutes (at most 18,000 receipts).
Cleanup occurs on open, writes, periodic maintenance and retention changes,
even when collection is paused. Nothing runs while Tokenotch is closed; cleanup
precedes display on the next open. Reducing retention requires confirmation.

Writes use a separate serial worker and owner-only SQLite database/sidecars,
batched for at most one second or 50 events with a 256-event admission limit.
Uncommitted data can be lost on a crash. Recording/storage failures are visible,
pause timeline capture, and preserve existing data. They do not opt out of daily
history or disable otherwise supported live observations. Known interruption
markers are not proof that every missing upstream event was detected.

Pause/removal preserves data until expiry; removing one client does not disable
the other's supported collection. Account sign-out has no timeline identity
meaning. Clearing live observations or deleting daily usage history does not
delete timelines. Confirmed timeline deletion cancels queued admissions and
invalidates displayed selections so old writes cannot repopulate the archive.
Deletion touches only owned timeline files, not hooks, credentials, daily
history, notifications, or other application data. Deletion and retention are
logical removal, not guarantees of forensic erasure or external-backup cleanup.

Timeline model/context differences are derived from unambiguously ordered
retained observations, not invented source events. Equal timestamps have no
guaranteed ordering. Context drops are not compactions, stops are not success,
and daily history cannot be linked back to individual calls: the aggregate
archive does not contain session identities and has independent consent/retention.

## Network

After opt-in sign-in, the official CLI contacts GitHub for OAuth/account usage.
Only `status.get`, `auth.getStatus` and `account.getQuota` are requested. No
session creation, tool invocation, token acquisition callback or credential read
RPC is used. Each refresh starts a bounded child runtime to avoid trusting a
process-lifetime cached snapshot. Account identity is checked before and after
the quota read. Errors keep the last reading visibly stale; account disconnect
cancels work and ignores late results. Rate-limit responses pause refresh for
five minutes. Polling is not a guarantee of real-time enterprise billing.

Only a small environment allowlist is passed to the runtime. Ambient tokens,
BYOK endpoints and OpenTelemetry exporters are not inherited. The separate
`COPILOT_HOME` and empty `GH_CONFIG_DIR` isolate configuration from your ordinary
CLI/GitHub CLI profile. They do not guarantee a separate system-keychain namespace:
the official CLI controls credential lookup and may reuse CLI-managed credentials
even with an empty configuration directory. Tokenotch starts account refreshes only
after explicit sign-in consent and displays the identity reported by the runtime.
The CLI's documented fallback may store credentials in its private profile.
Do not publish that profile. Disconnect is not credential revocation.

On Windows, when Tokenotch's private profile is signed out, the same three
read-only RPCs also run against your normal Copilot CLI profile (`COPILOT_HOME`,
default `%USERPROFILE%\.copilot`) so an existing CLI sign-in can be reused without
a second browser login. Tokenotch still never receives a token; **Disconnect**
stops quota refreshes and leaves that CLI sign-in untouched.

Optional public service health requests use
`https://www.githubstatus.com/api/v2/summary.json`. It uses an ephemeral session,
15-second request timeout, a 256 KiB response bound and a five-minute retry floor.
Manual toggling cannot bypass that floor. A failed request says source unavailable,
not “GitHub is down.” Native URLSession follows system proxy/TLS settings;
corporate proxy/TLS behavior still needs acceptance testing. Separately,
**Check for Updates** requests
`https://api.github.com/repos/rottathiago/tokenotch/releases/latest` only when selected.
That unauthenticated request sends the app version as its User-Agent, has a
128 KiB response bound and refuses redirects. See [updates](#updates).

User-initiated browser actions open GitHub usage settings or GitHub Status.
There is no phone/LAN listener or update polling.

## Managed restrictions

In the `io.github.rottathiago.tokenotch` preferences domain, **forced** `DisableHooks`,
`DisableNotifications`, `DisableHealth` and `DisableAccountConnection` booleans override user choices.
Restrictions are loaded before the bridge/network starts. This is a minimal
restriction surface, not a certified MDM package or full managed-settings
contract. Manual updates are the only update mode.

## Troubleshooting

- **Installed, no events:** check the documented client version/schema, local
  versus remote host, workspace precedence, hook locations and enterprise policy.
  Reinstall from Settings after an update; perform a start/stop test in each client.
- **Too few working sessions:** update the CLI integration in Connections and
  reload extensions or restart each existing CLI session. Activity is read on
  attachment and every 30 seconds, including work already in progress.
  Idle windows do not count. Unsupported activity RPCs produce an extension
  warning and leave hook-only coverage; stale reports remain explicitly unknown.
- **No quota:** select the official CLI in Usage, sign in in the browser and
  check access policy/runtime compatibility. Missing quotas are not zero usage.
- **No tokens:** reload each CLI session after installing the extension and run a
  model call. For VS Code, separately enable model and token usage, approve it
  in the chosen profile and reload the editor. Hooks alone do not provide usage.
  Inspect only sanitized delivery errors; installation is not proof of delivery.
- **No model/context breakdown:** use the CLI connection's Options > Review or repair setup after updating Tokenotch,
  then restart the CLI session. Context comes from `session.usage_info` or the
  optional runtime context-attribution snapshot; a token event alone cannot
  establish the context size. Unsupported snapshots retain event-only coverage.
  Older extension versions can still send token counts without a model name.
- **Cached input is zero or unavailable:** `0` is shown only for a group whose
  calls all explicitly reported zero. `Not reported` means the runtime omitted
  the field; `Unknown` means reporting availability was lost in older data.
  Counts marked `*` contain known amounts with incomplete reporting coverage.
  Review or repair the CLI setup and reload/restart every CLI session after updating
  Tokenotch. Historical uncertainty cannot be repaired by reinstalling, and Tokenotch
  does not force cache hits. Cache writes have their own reporting availability
  and are retained when supplied by a supported source.
- **Bridge unavailable:** another Tokenotch instance may own the lock, permissions
  may be unsafe, or the app is not running. Tokenotch does not terminate other copies.
- **Hook edited:** registration is withdrawn, but the edited file is not deleted.
  Review/remove that exact Tokenotch-owned file yourself; never delete a hooks directory.
- **Notifications denied:** enable Tokenotch in macOS notification settings; check
  master/category/channel controls and quiet time. No retry storm is scheduled.
- **Storage failure:** notification delivery pauses rather than losing deduplication.
  Correct the private-directory permissions, then clear local history or restart.
- **Status unavailable:** could be network, proxy, TLS, schema or service failure.
  It does not prove a global outage or local authentication problem.

Use the Settings diagnostic preview for support. Do not attach raw client
transcripts, tokens, prompt payloads, private paths or full environment dumps.

## Distribution boundaries

Development builds and unsigned public releases are ad-hoc signed, not notarized.
Apple Developer ID signing and notarization are optional, not requirements for
regular GitHub releases. Release notes disclose actual signing status, source
revision and checksums; the release channel is not a trust assessment.
The configured independent
identity is `io.github.rottathiago.tokenotch`, with repository `rottathiago/tokenotch`
and companion `rottathiago.tokenotch-vscode`. Configuration does not establish
signing, publisher registration, trademark clearance or distribution approval.
There is no automatic updater or inherited updater key/feed. No download should
be presented as an approved enterprise/Microsoft release. Upstream MIT attribution
is retained; archived proposals are not current product claims.

Public unsigned releases still require owned source, licensing, required CI,
matching version tags, installer verification and honest compatibility/support
claims. Continue collecting live-client, resource/privacy/security/accessibility
and OS/architecture evidence; unsigned publication does not attest to unrecorded
results. The optional signed path retains its exact-revision acceptance gates.
Full enterprise deployment and AI-credit billing are outside 1.0.0. See
[the release runbook](releasing.md) for unsigned publication and optional signing.

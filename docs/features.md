# Tokenotch feature reference

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../sources/Resources/Brand/TokenotchMarkDark.png">
  <img src="../sources/Resources/Brand/TokenotchMark.png" alt="Tokenotch logo" width="128" height="128">
</picture>

**Visibility into your AI coding usage and patterns.**

Tokenotch gives developers clear visibility into their AI coding usage and
patterns. It tracks token consumption and model usage across GitHub Copilot CLI
and Visual Studio Code sessions. A minimalist notch interface lets you run multiple
coding agents at once and alerts you when a session needs your action or
attention. Tokenotch is an independent project and is not affiliated with or
endorsed by GitHub or Microsoft. This detailed implementation
reference does not certify release acceptance; see [compatibility](compatibility.md).

## What works in this implementation

- Copilot-only native quota ring, usage/session hover card, menu bar and Settings.
  Idle auto-hide, hover-to-reveal, four edges, display selection, scaling, Option-drag positioning
  and full-screen hiding. Transparent corners pass clicks through.
  **Hide notch for full-screen apps** also dismisses the detail card and rechecks
  visibility every half-second to catch completed full-screen transitions.
  Detection is per display and does not depend on which app has focus, so
  focusing another monitor does not reveal a notch over a still-visible
  full-screen app, and apps that split windows across helper processes
  (VS Code, Chrome) are recognized. A window merely zoomed to fill the desktop
  is not full screen, including on a second display that carries no Dock and so
  lets a zoomed window reach the bottom edge. The notch returns when that
  display leaves full screen.
- Solid-black notch and custom pointed detail card: a larger
  Copilot ring and a compact hierarchy with **Usage**, **Sessions**,
  **Models' Usage Chart**, and **Models Breakdown** headings, separated by subtle dividers.
  See reported allowance and its reset, prioritized local session information,
  followed by the top three named models by observed tokens, with input, output,
  cache-read, cache-write and call counts. **Show all models** expands the list in place; **Show fewer models**
  restores the compact view. A residual row accounts for undisplayed,
  unavailable and overflow model detail; after expansion it contains only
  unavailable and overflow detail.
  **Today / Last 7 days** in Models' Usage Chart changes both the local token
  timeline and Models Breakdown period.
  A compact solid-white bar chart, centered with equal side padding, shows hourly
  observed tokens from midnight through the current hour for Today and seven daily
  bars for Last 7 days. Today's elapsed hours fill the centered plot without
  reserving blank space for future hours; its last label marks the current hour. Hover or VoiceOver
  reads exact values and recording coverage. Partial coverage is explained in those details; a dot marks unavailable
  observations, an outlined dash partial coverage with no observed tokens, and a
  solid dash zero tokens during recorded coverage. Future hours are not displayed.
  A small marker identifies the current, unfinished hour/day. Heights use a
  zero-based linear scale relative to the selected period's maximum, not cost
  or allowance. The collapsed notch is unchanged.
  **Settings → General → Charts → Time format** selects **12-hour**
  (with AM/PM) or **24-hour** labels, hover/VoiceOver times and hourly coverage
  notes. The choice is saved and applies without restarting; existing installs
  keep 24-hour formatting by default. It does not change reporting time zones,
  bucket boundaries, totals or the seven-day chart's weekday labels.
  Both periods support expansion, which survives usage updates but resets when
  the card closes or the period changes. Long lists scroll within the card.
  By default, the notch collapses
  to a small edge indicator when not in use. That indicator carries a gauge of
  the reported allowance, so the reading is legible without hovering. Hover
  expands the ring and detail
  card; moving away collapses them, and clicking keeps them open until an outside
  click. **Settings → General → Collapse when idle** controls
  this behavior; turn it off to keep the ring visible. **Show notch**
  turns the entire notch on or off, independently of full-screen hiding.
  A blue dot indicates observed work. Session status uses blue (working),
  violet (stopped), amber (warning), coral (error) and gray (idle/unknown),
  paired with distinct symbols and text. The ring still shows
  percentage **used**, not tokens, and the card leads with that same figure so
  both read the same way. The allowance turns amber at 75% used and red at 90%,
  and the ring's arc also changes texture at each step rather than relying on
  color alone. Normal content fits without scrolling;
  cramped displays can scroll while View history and Settings remain reachable.
  The menu's **Show Copilot summary** gives the card keyboard focus; hovering
  never steals it. Full account usage, including Usage on GitHub, is in Settings.
- The session headline prioritizes errors, warnings and unseen stopped turns
  ahead of the working count. Up to three session rows open source-aware details;
  **Details** keeps the full notice/session list reachable. A stop is not success,
  and a working duration measures observed work, not progress or a completion ETA.
  Each visible session has a small **Context** bar directly beneath its status,
  with a percentage and exact token counts available on hover and to VoiceOver.
  Context is the current reported window, not the sum of tokens used by the session.
  The same meter appears in Settings usage/session details. Missing context has a
  dashed bar labeled **Not reported**, never an assumed zero; readings older than
  five minutes stay visible in gray with **stale**. VS Code context is explicitly
  not reported because the supported telemetry does not provide window occupancy.
  Compatible CLI runtimes refresh on attachment, every 30 seconds, and after model
  changes, compaction or rewind. Old readings are invalidated before replacement.
  `/clear` reloads the extension for the new foreground conversation; its first
  reading includes any remaining system/tool context rather than assuming zero.
  Context stays live even while viewing last week's usage or another usage source.
  Update the CLI integration in Connections and reload extensions in each open CLI
  session to enable snapshot refreshes; unsupported runtimes retain event-only coverage.
  Deliberate opening acknowledges only displayed updates; hover needs one second
  of continuous exposure with at least half the row visible. Automatic notification
  expansion alone never marks updates viewed. Viewed stopped rows stay while the
  card is open and leave the notch when it closes.
  A quick visit also counts: when the card closes, every row that was visible for
  at least half a second while the pointer was on the notch or card (or any
  displayed row of a deliberately opened card) is treated as seen. Stops are marked
  viewed; requests, errors and warnings are dismissed so their attention marker
  clears. Untouched automatic expansions are still never acknowledged.
  Later supported evidence resolves warnings; a new prompt in the same session can
  supersede an old error/compaction failure without proving the earlier task succeeded.
  Idle reports and elapsed time are not recovery. Stale warnings remain explicitly
  last-reported until resolved, superseded or **Dismiss** is used in details.
- **Settings → Sessions → Session notices → Remember after quitting** is separately opt-in and off
  by default. Otherwise notices work in memory. Enabling starts fresh; no existing
  live notices or timelines are backfilled. The private operational ledger retains
  notice kinds, times, pseudonymous session labels and viewed/dismissed state, not
  prompts, raw errors, paths, live working counts or token readings. Unresolved
  notices have no age expiry; the 100-session capacity limit is disclosed when it
  removes older records. Closed records and up to 4,096 deduplication receipts
  expire after seven days. Restart restores last-reported notices, never live work.
  Confirmed opt-out deletes saved notices while retaining current in-memory state;
  **Clear session notices** and clear-live delete notice state and rotate its identity.
  Saved timelines, daily history and account/desktop-notification policies remain separate.
- Separate CLI and VS Code Preview adapters for documented start/stop events.
  The bounded native helper strips payload content before sending an event through
  an owner-only Unix socket. Installation requires an explicit action in
  onboarding or Settings > Connections.
  The CLI extension also reads its joined session's active/idle status every
  30 seconds, so long-running work does not expire just because no new prompt
  was submitted. Reload extensions or restart **each** existing CLI session
  after updating the integration in Connections.
- Opt-in notifications, independent banner/sound/session-card controls, stopped
  and CLI error categories, persistent deduplication, snooze and quiet hours.
  **Open the session card** expands every visible notch when **General → Show on
  all displays** is enabled; each card retains its own hover and dismissal state.
  Hidden notches and displays hidden for full-screen apps stay hidden, and
  automatic expansion does not steal keyboard focus or acknowledge notices.
  macOS controls the display used for native desktop banners; session cards
  provide the multi-display alert. **Play sound** plays one local chime per
  notification, regardless of the number of displays or whether macOS accepts
  a banner. Sound is off by default and uses the current audio output and volume;
  Tokenotch's notification mute, category, snooze and quiet-hour settings still apply.
  A separately opt-in **Input or approval requested** category observes explicit
  CLI dialogs. Notification clicks open the matching Tokenotch session details.
  Requests stay last-reported, not assumed to still be waiting or already answered.
  In the expanded notch card, the checkmark beside an input or approval request
  dismisses that notice without opening Settings. Requests also dismiss after
  three continuous seconds with at least half their row visible in a user-opened
  card, including keyboard opening; hover requires continued engagement.
  Scrolling the row out of view or closing/hiding the card resets the timer.
  Automatic notification expansion alone does not count as viewing.
  Each newly displayed request gets its own timer, and dismissal leaves the card
  open. It never answers or approves the request: retained notices remain in
  Details as **Dismissed, not confirmed resolved**. Errors, other warnings and
  stopped updates keep their existing behavior.
- Optional GitHub public service health, incident/recovery policy and redacted
  diagnostic preview/copy. No pasted access token, `gh` or Tokenotch backend is required.
- Clean Tokenotch preferences and data; no other products' credentials or settings are imported.

**Account usage and local tokens are separate.** Sign in through the official
Copilot CLI browser flow to display runtime-reported quotas, used/remaining
requests, percentages and future reset dates. The app refreshes these snapshots
every 60 seconds; the upstream runtime can cache or delay them.

An opt-in CLI extension streams input/output/cache-read/cache-write token counts, model identifiers and
context-window counts from sessions observed on this Mac. **Settings → Usage**
shows today's observed tokens (using the Mac's calendar/time zone), breakdowns
by model, and the raw combined total. Input, cache read, cache write, and output
are separate observed token categories, but the combined count is not a cost estimate. Settings also groups
usage by pseudonymous session and shows the latest context meter for each session.
Expand a session to see its input/output/cache-read/cache-write tokens, call count and context reading.
Readings older than five minutes are marked stale; missing data is unavailable,
not zero. The hover card summarizes all four token categories by model;
exact counts and full session lists remain in Settings.

**Read** and **Write** show cache activity alongside In/Out in the notch. A numeric `0` means
every observed call in that group explicitly reported zero for that cache category.
**Not reported** means the runtime omitted that category; **Unknown** means
older observations did not preserve reporting availability. A count followed
by `*` is partial: known cache amounts are retained, but some calls lack
reporting coverage. Help and detail views explain the reporting counts.
The compact notch uses `n/r` for Not reported and `?` for Unknown; hover and
accessibility descriptions retain the full explanation.
These states are consistent across live usage, saved history, and timelines.
Copilot CLI reports inclusive input. Tokenotch subtracts known cache reads and writes
once to obtain the remaining input. With complete reporting, that remainder is
regular input; otherwise it is labeled **Input (breakdown incomplete)** (`Input*`
in the notch) and may include unreported cache activity. The total always equals
runtime inclusive input + output, with known cache reads and writes counted
once, not added a second time. Missing category detail does not make that total
incomplete, although missed calls and sample limits still do.
This follows the inclusive-input accounting in the published
[Copilot CLI v1.0.88](https://github.com/github/copilot-cli/releases/tag/v1.0.88)
runtime, rather than assuming raw provider API fields share the same semantics.

Cache reads are generally discounted, not free; cache writes can cost more than
regular input. Rates depend on the model and billing tier; see
[GitHub's model pricing](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing).
Tokenotch shows counts, not monetary amounts, AI-credit estimates, or cache size.
Reasoning tokens are already included in output and are not added again.

After updating Tokenotch, use **Connections → Copilot CLI → Options → Review or repair setup**, then reload
extensions or restart each existing CLI session. Older token helpers/extensions
are rejected with an update notice so incompatible accounting cannot enter new
totals; other activity hooks continue working. Legacy saved values without
accounting provenance are preserved, with input/cache overlap explained in
tooltips rather than an inline warning. Stats show a quiet estimated-local-usage
note and direct users to GitHub or enterprise dashboards for official usage and billing.
New and legacy contributions remain distinguishable even on the same day/model.
An update cannot reconstruct discarded cache-write counts or past cache reports.

Live metrics are memory-only: up to 4,096 token calls and the latest context reading
for up to 100 sessions, retained for at most 24 hours. Breakdowns cover retained
samples, not just today; the notch's live-only Today view is day-scoped.
Hitting the call limit marks totals partial. Restarting
Tokenotch, clearing live observations or removing the CLI integration clears these metrics.
These are partial local observations, not account-wide billing totals, and
existing session history is not automatically backfilled. VS Code's hooks do not
provide token or context counts; its separate telemetry integration provides
supported per-call usage.

### VS Code local usage

The first-run guide embeds the same client setup controls used by Settings.
At least one chosen CLI or VS Code client must be successfully configured before
finishing; receiving activity is a separate verification step. Pausing preserves
progress without completing onboarding. The final welcome summarizes configured
clients, delivery status, and independent optional choices. Existing completed
users are not automatically re-enrolled.

**Connections** has one entry per client, not separate VS Code activity and usage
integrations. Under **Visual Studio Code**, choose **Set up VS Code...**.
Activity is included; **Include model & token usage** is optional and off by
default. The guide explains and walks through installing the setup extension,
reloading VS Code, approving profile settings, and verifying delivery.
Select **Visual Studio Code.app** (or **Visual Studio Code - Insiders.app**), not
Tokenotch, when asked to choose an editor. The extension uses public configuration
APIs and preserves unrelated settings. It configures Local Chat and Copilot
Agent Host separately behind the one connection.
Lifecycle hooks target Local sessions. Agent Host model usage does not establish
Agent Host lifecycle or attention coverage.

Activity and usage have independent statuses: off, setup incomplete, waiting
for data, or actual delivery. Installing a helper or approving settings does
not prove data is arriving. **Continue setup...** resumes a pending step;
**Manage connection...** changes the setup choices. Update, removal, and
usage-only disable are in **Options** (usage-only disable is also available inside
the setup guide), with technical information under
**Connection details**. Account quota and optional service status are separate
from these client integrations.
If removal is cancelled or blocked, collection stays off and the cleanup action
remains available in **Options**, including after an app restart.

**A working VS Code session without model stats usually means only lifecycle
hooks are connected.** Those hooks report neither model IDs nor tokens. In
**Settings → Connections → Visual Studio Code**, choose **Manage connection...**
and select **Include model & token usage**, approve setup in VS Code, and reload that window.
After a new model call completes, check that its source no longer says **No usage
received** and that the usage filter includes it (or select **All sources**).
Models such as `gpt-5.6-terra` do not need a separate model registration.
Earlier calls cannot be recovered unless a supported telemetry export was
already recorded.

**Activity works but Agent Host reports telemetry authentication failed:** older
Tokenotch receivers rejected the Agent Host's direct trace URL even with a matching
token. The receiver now accepts both its authenticated direct trace endpoint
and the conventional `/v1/traces` suffix. Metrics sharing the direct endpoint
are acknowledged without being counted as model calls. Rebuild/update and restart **Tokenotch**
to load this receiver fix; no environment changes or companion reinstall are
needed. A new completed call is needed to verify model usage. Previously rejected
calls are not backfilled automatically.

Receiver warnings clear after a clean, nonempty model-usage batch arrives.
Empty batches, metrics and filtered parent spans do not count as recovery.
**Connection details** retains rejected-request counts and the last request
error for the current app session, since earlier usage may still be incomplete.
Successful usage does not dismiss a separate, unresolved setup error.

VS Code's JavaScript OTel exporter streams requests with chunked HTTP framing.
Tokenotch accepts bounded, uncompressed chunked JSON as well as fixed-length JSON;
older receivers could show an unsupported-format warning for these requests
even while fixed-length Agent Host usage arrived successfully.

Usage arrives through an authenticated loopback-only OpenTelemetry receiver in
Tokenotch. Content capture stays off, no telemetry is forwarded externally, and only
allowlisted numeric usage, model IDs and hashed identifiers are retained. Model
calls are counted once; aggregate parent spans and standalone terminal CLI
telemetry are not added to CLI extension usage. Unknown fields or unsupported
producers show partial/unavailable coverage rather than invented zero counts.
The account quota ring is unchanged.

**All sources / CLI / VS Code Local / VS Code Copilot** filters apply to usage,
model breakdowns, charts and history, not to lifecycle activity or account quotas.
Missing session linkage, context and cache categories remain explicitly unavailable.
Remote execution, cloud agents and other providers are outside 1.0.0.
Existing external collectors, environment overrides and enterprise policy may
prevent configuration; Tokenotch does not silently replace them.

**OTel environment overrides detected:** the bundled companion shows the
blocking variable names (never their values) in the error dialog and
**Tokenotch: Check integration**. Remove only unneeded overrides at their source,
fully quit VS Code with **Cmd+Q**, reopen it from the corrected environment, and
retry setup under **Visual Studio Code**. Reloading a window or unsetting variables in an
existing terminal does not clear the parent environment. Keep intentional or
managed collectors intact; lifecycle-only setup remains available. See the
[companion troubleshooting guide](../integrations/VSCode/README.md#otel-environment-overrides).

If the only blocker is **`COPILOT_OTEL_FILE_EXPORTER_PATH`**, update the setup
extension to the version bundled with Tokenotch first. VS Code can set it internally to a
discard-only destination; earlier Tokenotch companions incorrectly blocked that
case. Real file-output paths remain blocked. Tokenotch never changes the environment,
and successful settings setup still requires verification with an actual model call.

If the blockers are exactly **`COPILOT_OTEL_ENABLED`**,
**`OTEL_EXPORTER_OTLP_ENDPOINT`** and
**`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT`** after an earlier setup,
update the setup extension to the version bundled with Tokenotch. VS Code's built-in Copilot Chat
sets them from Tokenotch's own settings; values that differ from those settings remain blocked.

**History → Import recorded usage** previews a user-selected supported telemetry
export before separately confirmed saving. Only already-recorded data can be
imported; enabling telemetry cannot reconstruct earlier usage. Imports affect
usage history only, not live sessions, timelines or notifications. Durable keyed
call receipts prevent repeated/overlapping imports and live delivery from
counting the same supported VS Code call twice. They remain with daily history
until it is deleted. Imported coverage remains partial, and hourly detail still
keeps only the latest seven reporting days.

### Local usage history

**Settings → History → Turn On History…** separately opts into daily
aggregates saved on this Mac. Compare days or months, use Today/7-day/30-day/month
presets, filter by model, and inspect charts or the accessible daily table.
Input/output/cache-read/cache-write tokens, model-call counts, independently sampled mean first-token
latency and mean call duration are shown where observed. Context high-water
marks and successful/failed compactions are recorded without model attribution.

The same opt-in also saves hourly total tokens, call counts and recording
opportunity/gaps for the latest seven reporting days, with no hourly model or
session identifiers. Schema-5 migration preserves daily totals and starts hourly
detail at upgrade time; it does not reconstruct old hours. **Hourly detail since …**
explains a partial first day, and its tooltip states the chart's own totals.
Hourly and daily writes share one transaction and deduplication. Cleanup runs on
open, writes, checkpoints and hourly reads, including when paused, not while the
app is closed. Daily aggregates are not aged out. Deleting usage history deletes
both resolutions.

The notch's chart and model breakdown default to **Today**. **Last 7 days** includes today
and the previous six days in the archive's fixed reporting time zone, unlike
completed-week comparisons. Saved history is preferred when available, even
while paused. Small, centered fine print at the very bottom of the card reads
**Usage data saved locally**, or labels paused
recording; partial coverage and known gaps are explained in its hover tooltip
and accessibility label. Without an
archive, Today uses labeled live-only samples in the Mac's current time zone,
and Last 7 days links to history consent rather than inventing a seven-day total.
Storage errors remain explicit; saved and live totals are never added together.
**Settings → Usage → Today** and **Models today** use the same saved snapshot,
source filter, token categories and reporting day as the notch's Today view.
Settings stays on Today when the notch switches to Last 7 days. Restarting the app,
clearing live samples or reaching the live sample cap does not reduce saved Today
totals. Both views identify saved/paused versus live-only coverage, and show
loading or storage failures rather than substituting a smaller live total.
The saved Today summary shows per-call tokens and sampled response times;
session activity remains in the separate live Sessions section.
Hourly bars use the event's reported time, not an estimated distribution over
call duration. Calendar buckets handle short/long daylight-saving days. Live
hours inherit the existing memory/sample limits and do not claim complete
recording coverage. The chart reuses batched usage updates and existing clock
boundaries, without a new timer, network request or chart dependency.

**View history** opens the selected period. Clicking a saved model also selects
that model; clicking a live-only model opens its exact captured Today breakdown
in Usage. Live snapshots expire when their oldest sample reaches the existing
24-hour retention limit, and clear with live observations or CLI removal.
The residual row opens the complete period breakdown, including
unavailable model IDs and archived detail limits. These counts are not model
costs, account-wide use, or productivity scores.

Daily aggregates remain until explicitly deleted. Pausing history, signing out
of the account, restarting Tokenotch, or removing the CLI integration does not erase
saved daily history; hourly detail remains subject to its seven-day retention.
**Settings → Privacy → Usage history → Delete…** requires confirmation and resumes
empty collection if still enabled. **Settings → Privacy → Live data → Clear…** is separate.
There is no transcript import or cloud sync. Pre-existing supported telemetry
exports require a separate explicit import; live collection never backfills them.

The history reporting time zone is fixed to the Mac's time zone at first opt-in
and displayed in History and Usage. Both Today views use that zone when an
archive is available; live-only Today uses the current Mac time zone.
Current multi-day comparisons use matched completed days, with today
shown separately. Daily summaries cannot reconstruct yesterday's exact usage
at the current clock time; partial/full day comparisons do not show a misleading
percentage. Missing dates are unknown, not zero account usage. All comparisons
are partial local observations, not billing or a productivity measure.

History uses private system SQLite storage, independent of the live sample cap.
Writes are batched for at most one second or 50 events; an interrupted app can
lose the uncommitted batch. Storage/queue failures pause recording visibly
without resetting saved data. Recording-opportunity minutes and interruption
markers are not proof of complete CLI coverage.

### Evidence-backed history insights

**Settings → History** compares model mix, mean first-token
latency, mean call duration, and compaction frequency over the last seven
completed reporting days versus the preceding seven. Each insight opens its
exact evidence snapshot in **Settings → History**, including period boundaries,
sample counts, missing fields, daily recording gaps, and model detail.

Model mix uses share of observed calls, with unknown/overflow models kept in the
denominator. Latency uses independent, sample-weighted means, not averages of
daily averages. Compaction frequency counts successful and failed completions
per 100 observed calls; starts are excluded and compactions are not attributed
to models. A change in model mix can affect aggregate latency; an insight is
not a causal diagnosis or a statistical-significance claim.

Directional headlines require calls on all fourteen days, collection beginning
before the window, and no known recording gaps. Model mix also requires 20 calls
per period. Each latency metric needs 20 valid samples and 80% field coverage
per period. Compaction comparisons require completions and calls in both periods:
no completions observed does not establish zero. Ineligible insights still open
their evidence and explain what is missing. Pauses and restarts can make a
comparison unavailable; missing coverage cannot always be detected.

### Saved session timelines

**Settings → Sessions → Record session timelines** is separate from daily-history
consent and starts off. It saves new, allowlisted session metadata to private
local SQLite storage. Turning it off pauses recording and keeps saved timelines.
The Sessions tab holds only these settings: recording, **Keep timelines for**,
**Saved timelines → Browse…** and **Delete…**; Privacy shows a summary with
**Manage in Sessions**. **View timeline** in session details or session metrics
opens the selected session directly; previously saved sessions remain browsable
after restart.
There is no pre-consent backfill or reconstruction from the latest live values.

Rows show observed calls, reported model/token/latency fields, context readings,
compaction start/completion, and supported lifecycle events. Differences between
successive known models are labeled observations, not explicit model-switch
events. A context decrease does not establish compaction, and a stop does not
establish success. Equal timestamps have no guaranteed chronology. VS Code
timelines can contain supported Local lifecycle hooks and independently enabled
live usage with a reported session identity. Usage without that identity cannot
be linked to a session; historical imports never create timeline rows.

Default retention is **7 days**, selectable **1/7/30 days**, with caps of **1,000
sessions, 2,000 events per session, and 100,000 events overall**. Oldest events
are pruned first; a saved timeline that may be partial (pruning, truncation or a
recording interruption) is labeled when opened.
Cleanup runs while Tokenotch is open, including while paused, and before displaying
saved sessions on the next launch. Shortening retention requires confirmation.

Archive-local pseudonymous IDs link retained events across restarts; raw client
IDs, stable bridge hashes, prompts, responses, commands, source, paths, and raw
errors are not archived. Pausing or removing a client's hooks stops new capture
for that client without erasing saved events. **Delete all session timelines**
deletes only this archive and rotates its identity; enabled recording resumes
empty. Daily-history deletion, account sign-out, and clearing live observations
do not erase saved timelines. Logical deletion is not forensic erasure.

### Developer attention notifications

Update the CLI integration through **Connections → Copilot CLI → Options → Review or repair setup**, then start
a new local CLI session (restart existing sessions to load updated hooks).
In **Settings → Notifications**, allow notifications and enable **Input or approval
requested (CLI only; starts off)**. Sound and automatic card expansion remain
separate choices, off by default. Existing category/channel choices are preserved.

Tokenotch observes the CLI's documented `notification` hook for `elicitation_dialog`
and `permission_prompt`, not ordinary assistant text, tool invocation or inactivity.
The existing CLI error category also covers `errorOccurred` with an explicit
`recoverable: false`; recoverable failures are ignored. An unrecoverable error
does not itself mean the session ended. A later terminal error in the same
observed episode does not produce a second error alert.

Requests appear in the existing notch indicator and session list even with desktop
notifications muted. Each distinct normalized report can notify once, honoring
quiet hours and snooze without replay. Click a notification to open that session's
Tokenotch details, then use **Open Terminal** if needed; this does not focus an exact
CLI tab. Expired or cleared targets show an explicit unavailable-details message.

The hook does not report when a request is answered. Details therefore say
**response status unknown**; viewing, active/idle snapshots and stopped turns do
not resolve requests. A later prompt or terminal session outcome can supersede
them, or you can dismiss them. Saved notices require the separate privacy opt-in.
No question, answer, command, raw error or path enters the notification, and these
observations are not added to usage history or saved timelines.

VS Code input/approval notifications, remote sessions, ordinary prose questions
and requests already pending before observation begins remain unsupported.
Documented schemas and synthetic/native fixtures are covered; real CLI dialog
delivery and macOS banner/click acceptance remain required before claiming
client-version support.

### Context and response latency

Reinstall the CLI integration and restart its session after updating Tokenotch to
observe optional latency and compaction events. Session details show latest
first-token latency/call duration, context utilization and actual compaction
status with reported before/after counts. The notch surfaces high-context and failed-compaction notices linked to the matching
CLI session. Unresolved old readings remain labeled stale rather than implying recovery.
The activity Details link preserves the full observed CLI/VS Code session list.
Missing fields
stay unavailable, and readings become stale after five minutes.

**Settings → Notifications → High context usage** starts off. When enabled, a
fresh upward 80% crossing can warn, rearming below 70% with a ten-minute
per-session cooldown. First/stale readings establish a baseline; mute, quiet
hours and snooze still apply. High context does not predict when compaction
will happen. Compaction never becomes a task-success or task-failure event.

Real signed-in client delivery of these optional events still requires
acceptance; synthetic fixtures alone do not establish client support.

No private `/copilot_internal/user` call, credential scraping, inferred AI-credit
conversion or invented enterprise budget is used. Credit-based targets remain
disabled until an approved source provides actual credit consumption.

An execution-stop event is **not task success**. A quiet session becomes
“No recent activity updates,” not “Finished,” when its work state is unknown.
Live CLI activity snapshots expire after 90 seconds without a refresh; hook-only
working reports retain the five-minute limit. Known stop/end/error outcomes are
not relabeled as missing observations. Idle sessions do not count as working.
The notch discloses stale sessions beside any remaining working count. CLI
snapshots are memory-only and never generate completion notifications or saved
timeline rows. The experimental activity RPC must be supported by the installed
CLI; unsupported/failed reads are reported rather than guessed from tokens or
running processes. Confirmed answer/approval completion, VS Code attention/failure,
remote sessions, exact-session focus and automatic usage/reset alerts are not
advertised as supported.

## Build and run

Requires macOS 15+ and Swift 6+. The bundle and smoke checks use `swiftc` directly
and work with matching Command Line Tools. Full Xcode is required for XCTest.
No third-party Swift package dependencies. Account sign-in requires an installed
official Copilot CLI; its runtime also supplies the optional extension SDK.
The smoke checks additionally use Python 3 and Node.js.

```sh
make vscode-companion # test/package the local setup extension (Node.js/npm)
make build       # ad-hoc signed build/Tokenotch.app, not notarized
open build/Tokenotch.app
make test        # XCTest via SwiftPM
make smoke       # executable core/IPC checks; works without XCTest
make smoke-telemetry # receiver, source migration, import/replay and privacy checks
make smoke-history # build and check consent/restart/pause/delete lifecycle
make smoke-timeline # insight thresholds and timeline privacy/persistence/retention
make smoke-notch # native notch/layout/render/interaction checks; needs a GUI session
python3 scripts/make-brand-assets.py # regenerate brand assets and the VS Code icon (needs Pillow and macOS iconutil)
python3 scripts/test-brand-assets.py # check logo variants and generated icons (same prerequisites)
```

`docs/design/tokenotch-notch-logo.png` is the source artwork for the in-app marks and
menu-bar icon. The generator trims transparent margins without changing its
proportions, redraws the dark linework in light ink for dark backgrounds (dropping
the white fill), and uses that linework as the menu-bar template.
`docs/design/tokenotch-logo-app-icon.png` is the source for the macOS app icon and
the VS Code companion icon. The generator cuts its rounded tile out of the black
backdrop and places it on the macOS icon grid with a drop shadow.
The generated assets supply Settings, About, the macOS app icon, this README,
and the local VS Code companion. After replacing the source, regenerate the
assets, repackage the companion with `make vscode-companion`, and rebuild the app.

`NOTCH_RENDER_PATH=/absolute/output/path make smoke-notch` also exports synthetic
notch/card fixtures for visual review. These checks capture only their own
fixture views, not the desktop or account data. They exercise the same checks as
the notch XCTest cases without requiring SwiftPM or XCTest.

Optional XcodeGen path: `make gen`, then open `Tokenotch.xcodeproj`, or run
`make test-xcode`. The native bundle script is the primary local development path.
No target installs over another product's app or publishes a release.
`make release` fails closed until recorded release gates and signing prerequisites are satisfied.

Use a coherent full Xcode installation for `make test`; a mismatched SwiftPM or
Command Line Tools installation is not evidence that XCTest passed.
`make build` and `make smoke` do not depend on SwiftPM. See
[contributing](../CONTRIBUTING.md) for prerequisites and focused validation.

## Connect local clients

For account quota, open **Settings → Usage → Copilot plan → Sign In…** and complete
the browser flow. Tokenotch keeps its runtime profile in
`~/.tokenotch/copilot-account`, separate from your interactive CLI profile.
**Choose CLI** is available if the executable is installed in a nonstandard
location. Signing in for quota does not automatically install monitoring hooks.
Disconnect stops polling and clears the displayed account; it does not revoke
the CLI-managed credentials. Tokenotch never receives or stores an access token itself.
The **GitHub Copilot account** section shows **Signed in** and your GitHub user ID
when the account snapshot is current, with **Switch GitHub account** available.
If a refresh fails, the user ID is labeled as last signed in and the sign-in status
is marked unverified rather than showing a stale account as currently signed in.

For live activity and developer metrics:

1. Open **Settings → Connections** and read the consent/limitations copy.
2. Choose **Set up Copilot CLI...**, review what is installed, then **Connect Copilot CLI**. This writes
   `$COPILOT_HOME/hooks/tokenotch-v1.json` and the uniquely owned
   `$COPILOT_HOME/extensions/tokenotch-token-usage/extension.mjs` (under `~/.copilot`
   when unset). Only lifecycle metadata, numeric token/context counts and bounded
   model identifiers are forwarded; prompts, tool arguments and results are not.
   Launch Tokenotch from the same environment if using `COPILOT_HOME`.
3. Choose **Set up VS Code...**. Leave **Include model & token usage** off for
   activity only, or select it for local usage too. Follow the extension
   installation, reload and approval steps. The companion merges Tokenotch's
   `chat.hookFilesLocations` entry while keeping existing locations. VS Code hooks
   use `~/.tokenotch/vscode-hooks`, not the CLI directory.
4. Restart the CLI and start a new local session in each client. Check for a
   start/working event, token samples from enabled sources, and an execution-stop
   event. Context readings remain CLI-only.
   Installation alone does not prove observation coverage.

Workspace hook precedence, Workspace Trust, enterprise policy and client
versions can prevent events. Do not change enterprise policy to force coverage.
Both integrations still need live-client acceptance before the public release is ready
for distribution; see [the capability matrix](tokenotch-integrations.md).

The helper is copied to a stable, private path so moving the app does not break
hooks. After an app update, use the CLI connection's **Options → Review or repair setup** to update the helper and
metrics extension, then restart your CLI session to load the updated extension.
Use each connection's **Options → Disconnect...** before deleting the app. The companion removes only
unchanged Tokenotch-owned settings; other user/workspace/admin hooks stay intact.
If a hook or extension was edited, Tokenotch withdraws its registration but refuses
to delete the edited file.
After removal, the remaining `.tokenotch` preferences/helper/state may be
deleted manually. The optional Copilot runtime profile can contain CLI-managed
credential references or credentials depending on the CLI's credential-store
configuration; treat that profile as private and do not export it.

## Privacy and distribution

See [privacy and operations](tokenotch-privacy.md). Optional network access
includes official Copilot runtime sign-in/quota requests, GitHub's public
status feed, and explicitly requested release checks; browser links are user initiated.
Notifications omit repository names and paths. CLI focus says **Open Terminal**,
not “Jump to session”; it cannot identify your originating terminal.

`io.github.rottathiago.tokenotch` is the independent production bundle identity, not a claim
of Apple signing or trademark clearance. There is no automatic updater or inherited
signing team/feed/key. Managed restrictions can disable hooks, notifications and
health polling, but full enterprise deployment is not certified.

[historical plan](plans/original-implementation.md) preserves the original proposal;
[TASKS.md](../TASKS.md) records implemented versus unvalidated/deferred work.
Obsolete Windows source, unrelated provider assets, and upstream
design/specification documents have been removed. Windows is not supported.
Inherited publication workflows and binary/update-feed artifacts are not Tokenotch deliverables.

## Attribution

Tokenotch is Copyright (c) 2026 rottathiago and released under the MIT License.
It includes MIT-licensed code, Copyright (c) 2026 Vinz. The original
copyright/license is retained in [LICENSE](../LICENSE). Native notch geometry
and full-screen detection retain upstream code. No upstream branding or binary
is shipped in the Tokenotch bundle.

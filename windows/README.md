# Tokenotch for Windows

The Windows implementation now connects the Rust/Tauri desktop to local collection,
account quota, optional archives and Windows notifications. It remains an
**unsigned local production build, not a publicly certified Windows release**.
The default distribution channel is `release`, with product version 1.0.0.
Real-client delivery, native ARM64 and installer/desktop acceptance are separate
gates; optimized compilation and production labels do not establish them.

All collection starts off. The app does not install hooks, enable editor telemetry,
sign in, contact GitHub status or save usage automatically. The existing macOS app
is unchanged; its shared CLI extension now selects the Windows helper filename,
and its VS Code companion also supports a Windows private-store broker.

## Implemented Windows features

| Area | Implementation |
| --- | --- |
| CLI | Explicit owned setup/repair/removal, Windows helper, bounded user-only named pipe, usage/context/activity and request/error observations |
| VS Code | Native ACL-checked setup broker, profile-bound public-settings consent, Local lifecycle, authenticated Local/Agent Host HTTP/JSON usage |
| Usage | Source filters, models, disjoint input/output/cache counts, reporting availability, call counts, sampled response times, stale context and account quota |
| Account | Auto-detected official CLI (optional override), reuse of the existing CLI sign-in or a separate private browser sign-in, protocol 2/3 quota reads, minute refresh and independent sign-out |
| History | macOS-matching periods, summary, stacked daily chart, models, previous-period comparison, weekly insights, context and daily breakdown; recorded by default, survives reinstalls and refreshes live |
| Imports | Preview and separate confirmation for supported OTLP JSON, completed-span JSONL and schema-1 SQLite exports; verified WAL/SHM replay in memory |
| Sessions | Live links to complete retained pseudonymous timelines, paged browsing, explicit interruption/pruning status, 1/7/30-day retention and separate notices |
| Notifications | Stopped/errors/requests, opt-in context crossings and service incidents/recovery, independent banner/sound/timed-card delivery, mute/quiet/snooze, durable suppression and typed activation |
| Desktop | macOS-style side notch (Copilot ring, quota percentage, working arc, optional slim gauge) with a separate hover/click-pinned summary card, clipped click-through regions, tray recovery, saved edge/position/scale/display, all-display widgets, fullscreen hiding and keyboard summary |
| Accessibility | Deliberate summary focus/close, inert folded cards, clipped-row exposure, monitor/work-area recovery, DPI region validation, Windows visual preferences and additional text/reduced-effect controls |
| Privacy | User-only Windows ACLs, no content persistence, separate archive deletion, redacted diagnostic preview, opt-in public service status |

### Connect your clients

Open **Connections**. It has two cards, **Copilot CLI** and **VS Code (GitHub
Copilot)**, each with **Connect** (shown as **Repair** once connected) and
**Disconnect**. Connecting the CLI installs only Tokenotch-owned files in the
selected `COPILOT_HOME` (default `%USERPROFILE%\.copilot`). **Usage history**
recording is on by default, so the History page has data; you can pause it in
**Privacy > Usage history**, and connecting a client resumes it. History lives in
`%USERPROFILE%\.tokenotch\usage.sqlite` and is kept across reinstalls. Earlier
builds left history off; on first launch, installs that never recorded history
turn it on, while paused archives stay paused. Reload extensions or restart **each** existing CLI
session. Setup is not proof that a running client has delivered events;
Connections reports these separately.

**Model/token breakdowns and live activity/context require the CLI usage
extension, not just the lifecycle hooks.** On CLI versions that gate extensions
behind Experimental features, launch with `copilot --experimental`, or choose
`/settings experimental on` in the CLI for future sessions, then restart.
This also enables other experimental features; Tokenotch never changes this
setting automatically. Check `/env` for the `tokenotch-token-usage` extension
and make sure it is enabled. A successful hook alone does not prove the extension
loaded. Connections shows received model/token samples separately from events.
Only subsequent completed API calls populate model breakdowns; missing past usage
is not reconstructed from transcripts. Without the extension, lifecycle activity
is last-reported only and becomes stale after five minutes.

For VS Code, choose **Connect VS Code**. Tokenotch installs the bundled
companion with VS Code's own `code --install-extension` (Stable first, then
Insiders), then opens a nonce-bound approval in that editor. **Capture Copilot
model & token telemetry** is on by default and can be cleared before connecting.
In the intended local profile, approve the request and reload the window.
Requests expire after ten minutes; interrupted requests are not replayed
after Tokenotch restarts. Removal stops collection immediately, then requires
approval (**Tokenotch: Remove owned configuration**) in the original profile.
Stopping telemetry only preserves lifecycle setup. Remote SSH, WSL, containers
and cloud agents are not supported.

**Continue setup in VS Code** appears while an unexpired request is pending.
The card's **Advanced** section has the Insiders handoff, **Show bundled VS Code
extension** and **Stop VS Code telemetry**. If VS Code is not detected, Connect
reveals the VSIX so you can use **Extensions: Install from VSIX** and run
**Tokenotch: Configure local integration**. Pending, expired and interrupted
requests are shown explicitly and never count as configured. Merely installing
native hooks does not change VS Code's profile settings.
The Windows companion recognizes Copilot's exact `\\.\nul` discard-only marker;
it still refuses real external exporters, content capture and conflicting settings.

Account quota lives in **Usage > Copilot plan**. **Sign in with GitHub** asks
once to enable quota, then finds the official `copilot.exe` automatically
(`PATH`, WinGet links/packages, `%LOCALAPPDATA%\Programs\copilot`), verifying it
with `--version`. If your normal Copilot CLI is already signed in, Tokenotch
reuses that sign-in through read-only account RPCs and shows **Disconnect**
instead of **Sign out**; otherwise it opens the CLI's GitHub browser sign-in into
a separate private home under `.tokenotch`. Tokenotch never receives a token,
the runtime does not inherit ambient tokens or telemetry configuration, and it
never creates inference sessions. **Account options** has the quota toggle and
an optional `copilot.exe` override for nonstandard installs.
**Refresh quota** and **Sign out**/**Disconnect** sit alongside explicit account
identity/status. Selecting the summary card's allowance row opens Usage.
Authentication is tracked separately from quota retrieval: an authenticated account
remains identifiable when quota is unavailable, while percentage stays **Not
reported**, not zero. Cached quota can remain marked stale only for the same
account; a confirmed sign-out or account change clears the previous percentage.
Finite entitlements show the reported used percentage; unlimited entitlements
show **Unlimited**. Account settings cannot change during an in-flight sign-in.

Token totals and model rows include only received API calls, not every open
CLI session or all account activity. When an observed session has no retained
token/model reports, Connections and Usage say so. Model names
come from each reported API call, including subagent calls; they are not replaced
with the foreground session's selected model. Input excludes separately reported
cache read/write tokens. Add those categories to compare with the CLI's inclusive
input count; do not add them twice.

Keep Tokenotch running and the CLI usage extension attached while collecting.
The extension retains pending accounting events in memory until acknowledged,
retrying failed helper deliveries with 250 ms to 5 second backoff instead of
dropping calls on failure or at a 64-event burst limit. Retries preserve original
call IDs and timestamps; Windows admits queued usage for less than 24 hours,
matching its receipt retention. Activity snapshots are coalesced while waiting.
Other hook readings expire after two minutes. Expiration produces an explicit
CLI warning that telemetry may be incomplete; extension termination/reload loses
undelivered in-memory events. These limits are not a guarantee of upstream delivery.
Context percentages above 100% remain visible as reported; only their visual bar
is capped.

### Storage and limits

`%USERPROFILE%\.tokenotch` is created with a protected current-user-only DACL.
New private files and the archive database receive the same explicit user owner
and DACL instead of relying on the launcher's default file owner, which can be
the Administrators group in elevated builds. Preparing an existing database never
truncates it or changes its permissions.
Unsafe existing permissions, links/reparse points and invalid files fail explicitly;
the application does not silently repair or replace unowned data.
The helper hashes identifiers and discards content before pipe delivery. It checks
the connected pipe server process's Windows user SID before sending credentials
or events; an unverifiable or different-user server is rejected. The
VS Code receiver binds only `127.0.0.1`, uses an installation-specific credential,
and bounds bodies to 4 MiB, headers to 16 KiB, concurrency to eight and requests
to five seconds. Disabling usage rotates that credential independently of editor
reload. No endpoint credential is included in diagnostic previews.

Live observations retain at most 4,096 calls and 100 activity/context sessions for
24 hours. History (on by default) is separate from those limits and is never added to
live totals. Daily model detail is bounded to 100 named entries per source/day
with an explicit overflow group. Timelines retain at most 1,000 sessions, 2,000
events per session and 100,000 events overall. Notices retain at most 100 sessions.
Stored timeline/notice identities are archive-local pseudonyms, not bridge hashes.
SQLite uses full-synchronous transactions; imports store only normalized numbers
and identifiers, never a raw export copy. Usage is archived independently of notice
storage, and archive receipts deduplicate retries independently of live samples.
Imports of `github-copilot` spans require `service.namespace = vscode.agent-host`
in OTLP, JSONL and SQLite alike; terminal/SDK exports without that provenance are
rejected rather than relabeled as Agent Host and counted again.
Import verification and writes run on
blocking workers, with small transactional batches that release the runtime lock
between writes so live collection can continue. Pausing or clearing history stops
the remaining batches, even if recording is immediately resumed. Completed
batches remain saved unless cleared; previewing and retrying an interrupted import
does not duplicate them. Logical deletion is not forensic erasure.

### History coverage and charts

Recording coverage measures **collection opportunity, not proof of client
delivery**. It requires history consent and a ready, configured collection path:
the CLI registration and named pipe, or the running VS Code receiver with
profile-bound metrics approval. Merely receiving calls does not add recording
seconds. All sources uses the union of available recording time, not the sum of
simultaneous source durations.

Today uses elapsed reporting hours, including a marked unfinished current hour.
Saved daily totals replace live samples in both Usage and the widget, even while
recording is paused or after the 4,096-call live cap is reached. Without a saved
archive, Today is explicitly live-only and uses retained samples; Last 7 days
requires saved history. Both charts and accessible values distinguish unavailable
observations, partial coverage (including no observed tokens), and zero tokens
during recorded coverage. Source filters affect totals and coverage together,
never live context. Hour labels respect the 12/24-hour preference and include
offsets to distinguish repeated DST hours.

Archive schema 3 retains daily opportunity durations, coalesced collection
intervals and source-specific gaps, plus seven reporting days of hourly detail.
The archive keeps its reporting time zone across restarts and device-zone
changes. Restarts, pauses, receiver interruptions, backwards clocks and heartbeat
delays over 65 seconds cannot fill unobserved time. Imports add numeric history
and explicit gaps but no opportunity, live activity or timelines. Deleting
history while recording starts a fresh baseline without backfilling live calls.
Schema-1 migration preserves existing numeric usage and repairs partial DST-hour
keys without inventing earlier coverage. History queries are bounded to ten years
per request and retain the explicit 20,000 model/day-row truncation warning.

### Detailed navigation and captured evidence

Select a chart period or model in the widget or Usage to open the exact captured
selection. Saved selections open History evidence; live-only selections open a
captured Usage breakdown, not a newly collected sample set. Source, reporting
zone, selected period/model and capture time remain explicit. Background delivery
does not change these detail values. Hourly history does not contain model
attribution, so hour details show their recorded totals and explicitly decline
to substitute models from the entire day.

The History page matches macOS: a **Period** picker (Today, Last 7 days, **Last
30 days** by default, This month, Previous month, Choose day, Choose month) with
source and model pickers and a Recording / Off / Waiting for a client /
Unavailable badge; Choose day/month add a **Compare with** date. It shows the
period summary (Daily average, or Per call for one day), a stacked **Daily
tokens** chart (days without calls stay blank), **Models** (select a row to
filter the page), **Compared with previous period** over completed days only,
**Weekly insights**, **Context window** and an expandable **Daily breakdown**.
It reloads in place whenever new usage is saved, history is deleted, recording
changes or the reporting day rolls over, including when the hidden Settings
window is shown again. Recording and deletion live in **Privacy > Usage
history**; when history is off, saved usage stays visible with a notice.

History models are labeled like macOS (Model unavailable, Other models (detail
limit)). Full source/period totals are aggregated before the 20,000 model/day-row
display limit and remain the denominator for model shares. Unreported and
capacity-overflow models are included; truncated model detail cannot produce a
renormalized share.

Each weekly insight opens its captured matched periods, source, model call
shares, independent first-token/duration sample counts, compaction completions and
coverage/gaps. Compaction starts are excluded and completions are not attributed
to models. Missing reports remain unknown, not zero or evidence of causation.

**Browse saved timelines** lists every retained session in pages of 100. Open one,
or follow **Open saved session timeline** from a live session, to page through all
its retained events with model/token/cache availability, independently reported
response times, historical context and compaction fields. Unlinked VS Code calls
have no session link. Retention cutoff, archive interruptions, archive pruning
and per-session truncation are visible in the browser/detail, not only help text.
Schema-1/2 timelines keep their observations but label earlier interruption
coverage unknown; no old coverage is invented.

Detail handoffs between native windows use a bounded, one-shot in-memory message
that expires after ten minutes if unconsumed. Archive generation identifiers
reject cleared targets without resolving a different period/session. Open details
are invalidated when their data is cleared or captured timeline events expire.
Back/Escape restores the originating view, filters, keyboard focus and scroll;
background refresh preserves expanded live-session rows and focused controls.
Live context remains independent of history/model filters.

### Desktop interaction and accessibility

Windows positioning intentionally uses **General > Screen edge / Position along
edge**, not a modifier-drag gesture. The position slider supports arrow keys and
Home/End and exposes its percentage to accessibility tools. Use **Open summary
with keyboard focus** in General or **Show Copilot summary** in the tray to open
one selected display's card deliberately. Hover and automatic alerts do not
request focus. The card has an explicit close button and keyboard Tab boundaries;
Escape closes it and restores the initiating window when that window still exists.
Explicit close also works when automatic idle closing is disabled.

Folded cards are inert and excluded from the browser accessibility tree, not
merely clipped away visually. Currently rendered notice rows must be at least
half visible within the card's scroll viewport. As on macOS, eligible continuous
exposure marks a notice viewed after one second (half a second on a deliberate
leave) and the notice stays readable while the card is open. The pointer resting
on the notch counts as engagement just as it does on the card: the two are separate
windows, so the card asks native code whether the pointer is over the drawn notch
or the open card (not the hover bridge between them). Folding the card by
any path (pointer leave, notch click, outside click, close button, Escape or focus
loss) dismisses every input, approval, error and warning notice seen during that
card session, which clears the notch attention badge and the card/Usage attention
rows; seen stopped notices simply stop highlighting. Neither operation resolves or
answers a request. Removed or clipped-out rows cannot accrue dwell. Hiding,
resizing, clock reversal or a sampling interruption over 750 ms resets continuous
exposure. Automatic cards still require deliberate engagement.

Card-state events and snapshots carry a shared revision. A snapshot requested
before a native fold but delivered after it is ignored, so a periodic refresh
cannot briefly resurrect a folded card or block re-opening it by hover.

Notices also clear themselves when the session continues: a new prompt, or a
model call reported after the notice (for example after approving or answering
directly in the CLI), resolves that session's input, approval, error and stopped
notices and withdraws any undelivered alert for them. Acknowledgements and
resolutions are broadcast to every notch, card and Settings window immediately.

Display state is keyed by monitor identity rather than enumeration order.
Removing/replacing a display clears its pin, alert, layout and focus state instead
of transferring that state to another screen. Offscreen or oversized Settings
windows are clamped into an available work area when display geometry changes or
Settings is explicitly opened; ordinary user movement is not continuously snapped.
**Hide widget for fullscreen apps** applies independently to each display, even
when focus is on another display or a smaller window is in front. It hides both
the notch and its summary card. Exiting fullscreen or disabling the toggle restores
only the notch, without restoring an old pinned card or replaying hidden alerts;
the master **Show activity widget** setting still takes precedence. Changes are
reconciled every 500 ms and immediately when preferences change.
Fullscreen detection excludes Tokenotch's own windows, cloaked windows, shell
surfaces and ordinary titled/maximized or work-area-only windows. Border-only
fullscreen windows and borderless fullscreen windows retaining the maximized
flag still count as fullscreen. Detection failures are reported and hide the
affected widget conservatively.

Native hit regions reject stale viewport, DPI and card-geometry updates. DPI
changes invalidate old regions before repaint, and the hover bridge uses the
drawn polygons rather than transparent corners of their bounding rectangles.
Summary windows remain managed by Tauri and are folded through their regions;
bypassing Tauri's visibility bookkeeping would break later keyboard focus.

General exposes 100-200% additional text scaling, reduced motion and opaque
surfaces. Windows text and transparency preferences are also read and honored;
lookup failures are shown rather than presented as successful detection.
Motion follows only Tokenotch's **Reduce motion** toggle: transitions, the notch
arc and session working icons animate even when Windows **Settings >
Accessibility > Visual effects > Animation effects** is off (common over Remote
Desktop, in VMs and with "Adjust for best performance"). General says when that
Windows setting is off. Refreshes preserve the indicators' rotation phase, and
Tokenotch never changes the Windows preference.
Large text wraps within a scrollable card with reachable footer controls.
High-contrast and reduced-effect styles preserve labels, focus outlines and
non-color status information. Narrator and physical mixed-DPI/multi-display
acceptance remain separate, unfinished gates.

### Notification policies and consent

Master notifications remain off by default. Context, incident and recovery
categories also default off, including when older preferences are migrated.
Existing stopped/error/request selections and independent banner/sound/card
choices are preserved. **Mute every notification channel**, snooze, quiet hours
and category controls suppress all delivery channels, not collection or in-app
notices. Equal quiet-hour start/end means quiet all day; local clock and DST
boundaries apply. Queued deliveries are rechecked against current settings and
newer observations, and missed alerts are not replayed after unmuting.

CLI context alerts require a fresh crossing from below 80% to at least 80%.
The first reading, a reading after invalidation or a changed context denominator,
and a reading after a gap over five minutes establish a baseline without warning.
After a crossing, context must fall below 70% to rearm; alerts have a ten-minute
per-session cooldown. Cooldown consumption survives restart, but live crossing
baselines do not. Enabling/disabling the category, toggling master/mute, clearing
live observations or disconnecting CLI resets the baseline. High context does not
predict compaction, and it cannot replace or answer an unresolved request.

Service alerts require the separate **Check public GitHub service health**
consent in Notifications. Enabling a notification category does not make network
requests. The first valid incident feed after startup or renewed service consent
is a silent baseline. Subsequent Copilot-affecting incident IDs can trigger an
incident alert; only an explicit `resolved` record for an observed incident can
trigger recovery. Feed omission, component status alone, unknown schemas and
failed fetches are not incident/recovery evidence. Requests are bounded to
256 KiB, concurrent checks are coalesced, and results from withdrawn consent are
discarded. Alert text is fixed application text, not remote incident content.

The macOS app does **not** currently feed account quota or local tokens into its
future credit-target rules. Windows therefore has no quota/credit/billing alert
category. Ring thresholds at 75%/90%, account changes, reset dates and token
counts remain display data, not notification contracts.

Suppression receipts are stored independently of remembered notices, including
muted events, before any delivery. They retain at most 4,096 hashed event IDs for
seven days and 100 pseudonymous context cooldowns for 24 hours; no context
readings, account IDs, incident descriptions or request content are written.
Clearing notices/live observations does not erase suppression receipts and replay
old alerts. An unreadable/unwritable receipt store fails explicitly without
delivering an unrecorded alert.

An eligible alert requests at most one banner and one sound, independently of
the number of displays. Native banners are silent to avoid a duplicate chime.
Windows banner permission is checked independently; a blocked banner does not
silence opted-in sound or cards. Notifications exposes permission lookup, the
Windows settings link, a stopped-category test button and per-channel results.
Automatic cards use independent three-second timers on visible displays; hidden
or fullscreen displays are skipped without replay on return. They do not focus
the widget, open Settings or acknowledge untouched requests. Click or keyboard
engagement is required during automatic display before exposure acknowledgement.
Deliberately expanded/pinned cards survive their alert timer.

Activation routes to the exact retained session notice, Usage for context, or
service status in Notifications without enabling checks. Expired/cleared session
targets fail explicitly. Opening a session notice from its notification counts as
viewing it: the notice is dismissed (stopped notices are marked viewed) so the
notch badge clears, but this never answers the request or marks it resolved. Real Windows toast activation/audio, physical multi-display
behavior and Windows Do Not Disturb/settings combinations remain manual
acceptance gates, separate from synthetic routing and card tests.

### Notch and summary card

The desktop surfaces follow the macOS design in `sources/Notch` and
`docs/design/tokenotch-stats1.png`. Every notch and card measurement is the macOS
reference pixel scaled by 44/117 and then by the saved notch scale. The palette
and the 75%/90% usage thresholds are the same, and the ring arc changes texture
as well as colour.

- **Notch window** (`widget`, `widget-N`): a black side notch whose inverse
  flares join the screen edge. It holds the Copilot glyph inside the account
  quota ring, the percentage beneath it (`—` unavailable, `∞` unlimited), a
  rotating working arc and an error/attention badge. **Fold the notch into a
  slim gauge when idle** (General) shows the macOS pill instead: a quota gauge
  and a status lamp.
- **Summary card window** (`card`, `card-N`): opened beside the notch by
  hover, with a curved tail aimed at the ring. Clicking the notch pins it;
  Escape, clicking outside a pinned card, or leaving the notch, card and the
  bridge between them closes it. The tray summary opens it with keyboard focus.
  Automatic alert cards never take focus.
- **Card content**, in macOS order: Usage (headline coloured only at 75% or
  more), Sessions with up to three rows and their context meters, Models'
  Usage Chart (source menu, Today/Last 7 days, coverage marks, coloured
  input/output/cache breakdown), Models Breakdown (top three named models plus
  Remaining models, Show all models), and a footer with View history,
  Settings… and GitHub model pricing. Provenance fine print sits beneath the
  footer.
- Both windows clip their native hit region (`SetWindowRgn`) to the drawn
  shape, so flares, corners and the space around the tail pass clicks through.
  The card window is shown once and then opened or folded by its region:
  showing a window again on Windows would activate it.
- Windows notice identities are pseudonyms, not live-session hashes. A request
  notice and its live session therefore appear as separate rows, where macOS
  can merge them.

Settings uses a dark rendition of the macOS grouped style: a sidebar with
coloured section icons (Appearance is now **General**), grouped cards, switches,
the stats2 Copilot plan and Today tiles with a stacked token bar, and the stats3
History toolbar, stacked daily chart and model share table.

## Development environments

Use the Mac for editing, portable Rust checks and the browser frontend. Use
actual Windows for Windows APIs, WebView2, installed helpers and desktop testing.
An ARM64 Windows guest on Apple Silicon can run the ARM64 app natively; running
the x64 app under emulation is not native x64 acceptance.

The engineering baseline is Windows 11 24H2 (build 26100) or later, with native
x64 and ARM64 payloads. This is a build target, not a compatibility certification.
Use separate local NTFS checkouts in Windows. Do not share Cargo build output,
`node_modules`, app data or credentials between hosts.

Required development tools:

- Rust 1.98.1 through rustup, including rustfmt and Clippy.
- Node 22.13+ with npm and Python 3.
- On Windows, Microsoft C++ Build Tools, the matching native MSVC/Windows SDK
  components, PowerShell 7 and the WebView2 Evergreen runtime.
- For installer inspection, 7-Zip (`7z` or `7zz`) on PATH.

The private Cargo/npm package versions describe the development workspace.
The product version comes from the repository's `config/Release.json`.
Run `python3 scripts/release-config.py --write` after changing shared identity.
Windows-only packaging inputs live in `windows/config/`.
`windows/config/release.json` selects `release` by default; `development` is also
an explicit supported channel. After changing it, regenerate metadata with the
same command. Debug compilation and browser preview remain available regardless
of the selected distribution channel.

## Portable work on the Mac

From the repository root:

Ensure Cargo is on PATH. If rustup was installed without changing your shell
configuration, run `. "$HOME/.cargo/env"` in the current Mac terminal first.

```sh
cd windows
cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked
cargo fmt --all -- --check
cargo clippy -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --all-targets --locked -- -D warnings
cd ..
npm ci --prefix windows/desktop --ignore-scripts --no-audit --no-fund
npm test --prefix windows/desktop
npm run lint --prefix windows/desktop
npm run build --prefix windows/desktop
npm run dev --prefix windows/desktop
```

Open `http://127.0.0.1:1420`. The page explicitly identifies itself as a browser
preview. General controls change only the demonstration, not the Mac desktop.
The notch and its summary card preview together at `/?surface=widget`; the
native app loads them as separate windows (`?surface=notch` and `?surface=card`).

Browser interaction checks use Playwright. From `windows/desktop`, run
`npx --no-install playwright install chromium` once, then `npm run test:browser`.
They do not replace native WebView2 acceptance.

`make smoke-contracts` runs the same hook corpus through the Swift implementation
using Command Line Tools. XCTest includes it through `WindowsContractTests`.
The shared corpus covers hook normalization and selected activity, deduplication,
retention and context-invalidation transitions. Rust also tests OTel producer
routing and cache accounting. These do not establish full notice/history parity
or live-client compatibility.

## Building Windows installers on the Mac

Native Windows remains the acceptance environment. When it is unavailable,
the supported cross-build path can produce genuine x64 and ARM64 Windows
executables and unsigned NSIS installers for later Windows testing.

Additional build prerequisites are `cargo-xwin` 0.23.1, LLVM, NSIS and 7-Zip.
The exercised Homebrew tools were LLVM 23.1.2, NSIS 3.13 and 7-Zip 26.03.
`cargo-xwin` downloads the Microsoft CRT/SDK required by MSVC targets.
Keep Tauri's locked runtime/macro/codegen dependency family together; an
uncoordinated Cargo update can select incompatible transitive versions.

After installing those prerequisites, from the repository root:

```sh
export PATH="$HOME/.cargo/bin:$(brew --prefix llvm)/bin:$PATH"
rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc
bash windows/scripts/cross-build.sh all --allow-unsigned
```

Use `x64` or `arm64` instead of `all` for one architecture. Installers and SHA-256
files are written under `build/windows/<architecture>/`. The script checks the
PE architecture of the embedded app/helper and verifies archive integrity,
metadata and the license notice without executing the installer.
Windows targets statically link the Visual C++ runtime; the payload checker
rejects ordinary or delayed imports requiring a separate VC++ Redistributable.
WebView2 is still required and is handled separately by the installer.

Cross-compilation is experimental in Tauri. It does not verify installation,
WebView2 behavior, native Windows IPC/ACLs, real clients or desktop interaction.
It is not a substitute for either Windows CI job or a signed-release gate.

<a id="native-windows-development"></a>

## Native Windows production builds

Run from the repository in PowerShell 7, selecting the **native OS architecture**:

After installing Rust, open a new terminal so Cargo is on PATH. If rustup was
installed without modifying PATH, add it for the current PowerShell session:

```powershell
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
```

```powershell
.\windows\scripts\build.ps1 -Architecture x64
.\windows\scripts\package.ps1 -Architecture x64 -AllowUnsigned
```

Use `-Architecture arm64` on Windows ARM64. The script refuses a different native
OS architecture rather than reporting an emulated run as native. Both builds
are required for two-architecture acceptance. Packaging already runs the build
script; run the standalone build command only when an installer is not needed.
It restores locked frontend dependencies when missing or invalid, runs checks,
builds the release helper, stages architecture-specific resources and builds the
desktop with embedded frontend assets and a static Visual C++ runtime.

Unsigned installers and checksums go to `build/windows/<architecture>/`.
The release filenames are `Tokenotch-1.0.0-windows-x64-setup.exe` and
`Tokenotch-1.0.0-windows-arm64-setup.exe`, each with an `.exe.sha256` file.
An explicitly selected development channel retains `-development` in its
artifact names. Packaging requires `-AllowUnsigned`; omission fails before
building. Signing, public release publishing and automatic updates are not
implemented. **Check for updates** opens official releases.

The staging step inspects the exact installer before copying it and calculating
its checksum: app/helper architecture, runtime imports and exact release binary contents, release metadata,
license, and the bundled companion's package/VSIX identity and contents. The
executable comparison permits only Tauri's documented NSIS bundle-type marker
patch, not other binary differences. Ambiguous
old installer outputs are rejected rather than silently chosen. To inspect and
hash a staged x64 installer independently:

```powershell
python windows\scripts\verify-installer.py --architecture x64 build\windows\x64\Tokenotch-1.0.0-windows-x64-setup.exe
Get-FileHash -Algorithm SHA256 build\windows\x64\Tokenotch-1.0.0-windows-x64-setup.exe
```

Keep `TAURI_CONFIG` and `TOKENOTCH_TEST_HOME` unset for production builds;
smoke overrides are rejected explicitly. The installer is per-user and retains
the existing application identity. WebView2 may require a bootstrapper download.
Unsigned executables may trigger Windows reputation warnings or organization
policy; do not disable those protections.

### Replacing a local development installation

Creating an installer does not replace a running installation. Obtain separate
confirmation before installing it. Existing development installers also use
version 1.0.0, so this can be a same-version reinstall, not a version upgrade.
Keep a known-good installer or app payload for rollback and close the app before
replacement. Use the normal NSIS per-user reinstall path; do not use the
disposable uninstall test below against a real profile.

Preserve `.tokenotch` settings, archives, account state and client consent.
Do not uninstall integrations or delete history as part of replacement. An
already-connected client can still use its previously copied helper; if repair
is needed, use the existing owned **Repair** flow with the required consent and
editor approval. Do not silently connect disabled clients or resume paused
collection. Verify the installed version/channel, settings and history after
launch. Native ARM64 acceptance requires a separate native ARM64 Windows machine.

### Isolated native development checks

An isolated native regression check exercises actual WebView2, named pipes,
the helper and native ACL broker without touching real client configuration.
It also polls snapshots during automatic-card expiry and widget hiding to
check that main-thread commands remain responsive across visibility changes.
Build a debug-only smoke identity first (a normal installed instance can keep
running):

```powershell
$env:TAURI_CONFIG = '{"identifier":"io.github.rottathiago.tokenotch.smoke"}'
Set-Location windows
cargo build -p tokenotch-platform --examples --locked
cargo build -p tokenotch-hook --locked
python scripts\prepare.py --target x86_64-pc-windows-msvc --helper target\debug\TokenotchHook.exe
cargo build -p tokenotch-desktop --features custom-protocol --locked
npm run test:native --prefix desktop
Remove-Item Env:TAURI_CONFIG
```

After that build, `npm run test:native --prefix desktop -- --fullscreen` runs
only the fullscreen and pointer regressions. A separate DPI-aware native window fixture
exercises actual Win32 detection, live and saved toggle changes, fullscreen
startup, native notch visibility/card clipping, pinned and always-open card
dismissal, late expansion requests, hidden alerts and focus-preserving restoration.
It also moves the real cursor (and restores it afterwards) to check that the card
opens and folds along each pointer path with and without the auto-hidden notch,
and that resting on the notch alone views a stopped notice and clears its badge.
Do not touch the mouse while it runs. Add `--real-browser` to also put a temporary
Microsoft Edge profile into fullscreen while the pointer rests on the notch.
Multi-display assertions run when multiple monitors are available; a single-display
run explicitly reports that limitation. The fixture is not part of the installed
application.

`npm run test:native --prefix desktop -- --identity` checks only the native
version/channel and unsigned distribution presentation in the isolated debug
app, without setting up synthetic connections. It does not replace the full
smoke suite or certify a release executable.

Building the desktop copies the staged helper sidecar beside it, so always stage
the debug helper as above before a smoke build. A release helper ignores
`TOKENOTCH_TEST_HOME` and would deliver the synthetic hooks to a real installed
Tokenotch; the native smoke now refuses to start when the helper beside the
binary does not honor the isolated home. Re-stage the release helper before
packaging an installer.

Build frontend resources and the VSIX first, as above. Use the ARM64 target on
ARM64. The smoke uses a temporary private root through `TOKENOTCH_TEST_HOME`,
which is compiled only into debug builds, and a separate WebView2 profile.
It does not launch a real Copilot client, approve real editor settings, display
desktop notifications or execute an installer. The existing companion's POSIX
permission fixtures require macOS; run `node --test integrations\VSCode\test\windows.test.cjs`
from the repository root for portable Windows companion fixtures.

The slower maximum-size import regression is opt-in. Run it from `windows` to
import 100,000 spans while checking that concurrent live deliveries stay within
the hook's 900 ms deadline:

```powershell
cargo test -p tokenotch-platform --test runtime maximum_size_import_keeps_live_delivery_within_hook_deadline --locked -- --ignored --nocapture
```

On a designated disposable Windows environment only:

```powershell
.\windows\scripts\verify-install.ps1 -Architecture x64 `
  -Installer <setup.exe> -DisposableEnvironment
```

This installs into a unique temporary location, checks payload architecture,
runs the installed helper diagnostic and invokes the uninstaller. It does not
certify desktop interaction or live clients. Do not use a production installation
or shared user profile for installer tests.

The `Windows build checks` workflow runs both architectures and uploads
explicitly unsigned artifacts; it does not publish a release. The x64 hosted image is
Windows Server, so actual Windows 11 desktop acceptance remains separate.

### Native x64 verification: September 30, 2026

Source revision `e607e38e3bec` was built and exercised on native x64 Windows 11
Enterprise, build 26200, from a local NTFS checkout. The environment used Rust
1.98.1, Visual Studio 2026 C++ tools, PowerShell 7.6.6, Node 24.19.0,
Python 3.14.6 and WebView2 154.0.4258.48.

| Check | Result |
| --- | --- |
| `.\windows\scripts\package.ps1 -Architecture x64 -Development` | Passed: release app/helper, 18 Rust tests, 4 frontend tests, formatting, Clippy, ESLint, static-runtime/PE checks and helper diagnostic. Unsigned NSIS installer and checksum produced. |
| `python scripts\test-project.py` | Passed: 7 publication regression tests. |
| `python scripts\test-release.py` | Passed: 22 release regression tests. |
| `python windows\tests\test_packaging.py` | Passed: 5 packaging regression tests. |
| `npm run test:browser --prefix windows\desktop` | Passed: 3 browser presentation tests after installing the pinned Playwright Chromium build. |
| `python windows\scripts\verify-installer.py --architecture x64 build\windows\x64\Tokenotch-1.0.0-windows-x64-development-setup.exe` | Passed with 7-Zip 26.03: embedded x64 payloads, static runtime, metadata, license and archive integrity. The staged SHA-256 also matched. |

A separate automated smoke check attached Playwright to the **release app's
native WebView2**, using an isolated temporary WebView2 profile, not the Vite
browser preview. Both app surfaces loaded with real Windows runtime status and
collection disabled. All four edge selections and widget visibility controls
round-tripped through native IPC. Hover expanded the widget WebView2 to
320 by 224 logical pixels, and its settings action completed without an IPC
error. The checked screens had no visible errors or uncaught JavaScript errors.
The native helper also rejected unsupported invocations without waiting for stdin.

This verifies the x64 development build, not a supported release. The installer
was inspected but **not executed**: this development machine was not designated
as disposable.
Installation/uninstallation, upgrade/recovery, native ARM64, the minimum Windows
build 26100, tray/keyboard/Narrator interaction, multi-display/fullscreen behavior
and real Copilot clients remain unverified. No hooks or client telemetry were
enabled, and nothing was published.

### Integration implementation verification

The new implementation was exercised on native Windows x64 with synthetic,
isolated clients. The installed Tokenotch instance was not stopped or replaced,
and real Copilot credentials, hooks and VS Code settings were not used.

| Check | Result |
| --- | --- |
| `.\windows\scripts\package.ps1 -Architecture x64 -Development` | Passed: native app/helper, workspace tests, formatting, Clippy, frontend tests/lint/build, VSIX packaging and unsigned NSIS installer. |
| `npm run test:native --prefix windows\desktop` after the isolated smoke build above | Passed: actual WebView2, owned CLI setup and named-pipe delivery, duplicate usage, context, notices, saved usage/timelines, fake account stdio RPC, restart and removal. The real Windows ACL broker also configured/removed synthetic VS Code profile settings, including usage-only removal preserving lifecycle. |
| `cargo test -p tokenotch-platform --test runtime --test receiver --test sqlite_import --locked --quiet` from `windows` | Passed: 15 focused runtime/HTTP/archive/import regressions, including native ACL/hard-link checks and read-only WAL replay. |
| `npm test --prefix windows\desktop` and `npm run test:browser --prefix windows\desktop` | Passed: 10 frontend unit tests and 3 browser interaction tests. |
| `node --test integrations\VSCode\test\windows.test.cjs` | Passed: 2 Windows companion tests. Existing POSIX ownership fixtures cannot run meaningfully on Windows and remain macOS checks. |
| `node --experimental-vm-modules scripts\extension-smoke.mjs` and `node --experimental-vm-modules scripts\context-extension-smoke.mjs` | Passed: shared extension accounting, activity, context, invalidation and privacy regressions. |
| `python scripts\test-project.py`, `python scripts\test-release.py`, `python windows\tests\test_packaging.py` | Passed: 34 publication/release/packaging regressions. |
| `node scripts\docs\check.mjs` with pinned lychee on PATH | Passed: Markdown and offline local links. |
| `python windows\scripts\verify-installer.py --architecture x64 build\windows\x64\Tokenotch-1.0.0-windows-x64-development-setup.exe` with 7-Zip on PATH | Passed: embedded payloads, metadata, licensing and archive integrity; installer not executed. |

These checks establish development behavior, not real-client compatibility,
native ARM64 support or installer lifecycle acceptance. No publication occurred.

### History coverage implementation verification

Package 1 was exercised on September 30, 2026, on native Windows x64. The following
checks cover the working-tree implementation, not a published release.

| Command | Result |
| --- | --- |
| `cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked --quiet` from `windows` | Passed: 44 tests, including 11 archive/calendar/coverage fixtures. |
| `cargo fmt --all -- --check` from `windows` | Passed. |
| `cargo clippy --workspace --all-targets --features tokenotch-desktop/custom-protocol --locked -- -D warnings` from `windows` | Passed, including the native desktop commands. |
| `npm test --prefix windows\desktop` | Passed: 18 frontend fixtures, including saved/live precedence, source unions, coverage states, reporting midnight and DST calendars. |
| `npm run lint --prefix windows\desktop` | Passed. |
| `npm run test:browser --prefix windows\desktop` | Passed: 5 browser checks, including shared Usage/widget totals, source selection, clock labels and live-only history restrictions. |
| `npm run build --prefix windows\desktop` | Passed: production frontend assets. |
| `cargo build -p tokenotch-platform --examples --locked` and `cargo build -p tokenotch-hook --locked` from `windows` | Passed: isolated account fixture and native helper. |
| `python scripts\prepare.py --target x86_64-pc-windows-msvc --helper target\debug\TokenotchHook.exe` from `windows` | Passed: staged x64 development resources. |
| `cargo build -p tokenotch-desktop --features custom-protocol --locked` from `windows` with the documented `.smoke` `TAURI_CONFIG` | Passed: isolated native x64 desktop. |
| `npm run test:native --prefix desktop` from `windows` after the isolated build | Passed: actual WebView2, matching saved Usage/widget chart totals, source-aware CLI/approved VS Code opportunity, duplicate calls, restart, archive deletion and existing integration regressions. |
| `node scripts\docs\check.mjs` with the existing pinned lychee 0.24.2 on PATH | Passed: 20 Markdown files and offline local links. |

The deterministic fixtures also cover opt-in boundaries, delayed/imported calls,
pause/resume, model overflow, 4,097 calls surviving the live cap, independent cache
reporting, storage-failure pausing, 23/25-hour days, Lord Howe's half-hour DST,
schema-1 numeric preservation and seven-reporting-day hourly pruning. The native
smoke used disposable synthetic settings and private data, cleaned up afterward;
it did not stop or replace an installed app, access real credentials or configure
real clients. ARM64, actual client delivery and broader desktop acceptance remain
unverified.

### Detailed navigation implementation verification

Package 2 was exercised on September 30, 2026, with the existing isolated x64 smoke
identity and synthetic client profile. Its schema-3 metadata does not backfill
timeline coverage or change history/accounting consent.

| Command | Result |
| --- | --- |
| `cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked --quiet` from `windows` | Passed: 49 tests, including 5 new navigation/archive fixtures. A 21,003-row archive preserves its full denominator while exact model queries reach beyond the display limit. |
| `cargo fmt --all -- --check` from `windows` | Passed. |
| `cargo clippy --workspace --all-targets --features tokenotch-desktop/custom-protocol --locked -- -D warnings` from `windows` | Passed, including the new native command permissions and routing. |
| `npm test --prefix windows\desktop` | Passed: 25 frontend fixtures, including immutable captures, unknown/overflow denominators, exact hourly evidence, independent latency samples and complete retained timeline pages. |
| `npm run lint --prefix windows\desktop` | Passed. |
| `npm run test:browser --prefix windows\desktop` | Passed: 11 checks, including widget handoffs, live-only capture, missing/cleared/expired targets, 201-session/event pagination, preserved focus/scroll/filter state and exact insight evidence. |
| `npm run build --prefix windows\desktop` | Passed: production frontend assets. |
| `cargo build -p tokenotch-platform --examples --locked` and `cargo build -p tokenotch-hook --locked` from `windows` | Passed: rebuilt native fixture/helper. |
| `python scripts\prepare.py --target x86_64-pc-windows-msvc --helper target\debug\TokenotchHook.exe` from `windows` | Passed: staged x64 development resources. |
| `cargo build -p tokenotch-desktop --features custom-protocol --locked` from `windows` with the documented `.smoke` `TAURI_CONFIG` | Passed: isolated native desktop. |
| `npm run test:native --prefix desktop` from `windows` after the isolated build | Passed: actual WebView2 widget-to-settings evidence, unchanged captured totals after new delivery, live-session timeline links, focus restoration, cleared targets and the existing integration/account/restart regressions. |
| `node scripts\docs\check.mjs` with pinned lychee 0.24.2 on PATH | Passed: Markdown and offline local links. |

The smoke profile was cleaned up. No real client configuration, credentials or
installed application were changed. Native ARM64, real-client delivery, Narrator
and broad desktop/release acceptance are still unverified.

### Notification policy implementation verification

Package 3's policy/delivery implementation was exercised on September 30, 2026.
Its remaining native acceptance checkbox is intentionally open.

| Command | Result |
| --- | --- |
| `cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked --quiet` from `windows` | Passed: 62 tests, including 13 new notification fixtures for thresholds, cooldown/restart, stale/invalidation baselines, quiet-hour DST, muted persistence, explicit service recovery, consent races, independent channel failures and per-display timers. |
| `cargo fmt --all -- --check` from `windows` | Passed. |
| `cargo clippy --workspace --all-targets --features tokenotch-desktop/custom-protocol --locked -- -D warnings` from `windows` | Passed, including native WinRT permission lookup and notification routing. |
| `npm test --prefix windows\desktop` | Passed: 26 frontend fixtures. |
| `npm run lint --prefix windows\desktop` | Passed. |
| `npm run test:browser --prefix windows\desktop` | Passed: 15 checks on the notification implementation snapshot before concurrent chart edits, including independent category/network consent, automatic-card exposure and typed activation. See final rerun limitation below. |
| `npm run test:browser --prefix windows\desktop -- --repeat-each=2` | Final full rerun: 28 passed, 2 failed in the saved-chart fixture after concurrent chart markup changed. Those chart changes were not overwritten by this task. |
| `node --test windows\tests\frontend\notifications.test.mjs` and `npm run test:browser --prefix windows\desktop -- notifications.spec.js --repeat-each=2` | Final scoped rerun passed: the exposure unit fixture and all 8 notification browser runs. Timer assertions advance every interval deterministically rather than skipping timers. |
| `npm run build --prefix windows\desktop` | Passed: production frontend. |
| `cargo build -p tokenotch-platform --examples --locked` and `cargo build -p tokenotch-hook --locked` from `windows` | Passed: isolated native fixture/helper. |
| `python scripts\prepare.py --target x86_64-pc-windows-msvc --helper target\debug\TokenotchHook.exe` from `windows` | Passed: staged x64 development resources. |
| `cargo build -p tokenotch-desktop --features custom-protocol --locked` from `windows` with the documented `.smoke` `TAURI_CONFIG` | Passed: isolated native x64 desktop. |
| `npm run test:native --prefix desktop` from `windows` after the isolated build | Passed for native card/routing behavior: fresh context-triggered card-only delivery, three-second timeout, Settings retaining focus, untouched requests remaining unviewed/undismissed, exact and expired targets, independent service navigation, durable receipts and previous regressions. OS toasts and audio were not emitted. |
| `node scripts\docs\check.mjs` with pinned lychee 0.24.2 on PATH | Passed: Markdown and offline local links. |

**Observed limitation:** `notification_status` fails explicitly for the
unregistered `.smoke` application identity. The smoke checks that failure rather
than treating it as permission granted. Reading permission on a registered
installation, actual Windows toast activation (including app restart), audible
sound, physical multiple displays and Windows notification/Do Not Disturb
combinations are not accepted by these checks. Use a designated disposable
registered installation for those checks; this task did not install/register an
app, alter an existing app or client configuration, emit desktop toasts/audio, or
change Windows notification settings.

**Concurrent-worktree limitation:** Another UI change replaced the chart markup
and added presentation/geometry/glyph modules during the final verification.
The existing saved-chart browser selectors then stopped matching. Native
card/routing evidence above predates that concurrent UI rewrite; notification
policy fixtures and notification-specific browser checks were rerun successfully.
The combined UI and notification changes were later verified together; see
[visual parity implementation verification](#visual-parity-implementation-verification).

### Visual parity implementation verification

The notch, summary card and Settings redesign was verified on September 30,
2026 together with the notification-policy changes above. Native runs used the
isolated `.smoke` build.

| Check | Result |
| --- | --- |
| `npm test --prefix windows\desktop` | Passed: 36 unit tests, including geometry, glyph, presentation, card-placement and chart checks. |
| `npm run lint --prefix windows\desktop` | Passed. |
| `npm run test:browser --prefix windows\desktop` | Passed: 21 checks. These include the six new design checks (ring and working arc, stats1 card section order, card placement on each edge, slim gauge, request dismissal, stats2/stats3 Settings) and the updated chart, notification and navigation checks. |
| `npm run build --prefix windows\desktop` | Passed. |
| `cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked` from `windows` | Passed, including notch size, card placement, hover bridge and bounds tests. |
| `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --features tokenotch-desktop/custom-protocol --locked -- -D warnings` from `windows` | Passed. |
| `npm run test:native --prefix desktop` from `windows` after the isolated build | Passed: the separate notch and card WebView2 windows. Chart totals, model capture, automatic card display without focus or acknowledgement, and the previous regressions all hold. |

A throwaway isolated launch captured the real right-edge and left-edge cards,
plus the slim gauge. Desktop content showed through outside the clipped shapes.
That screen capture is not acceptance of click-through, focus or Narrator
behavior on physical, mixed-DPI or multiple displays.

### Desktop interaction implementation verification

Package 4's implementation checks ran on October 1, 2026, on Windows build
26200, native x64. Tauri reported one 3816 x 1348 display at scale factor 1,
with a 3816 x 1300 work area. This single-display configuration does not establish
physical multi-display, mixed-DPI or hot-plug acceptance.

| Command | Result |
| --- | --- |
| `cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked --quiet` from `windows` | Passed: 72 tests, including 7 new desktop fixtures for stable monitor ownership, recovery bounds, DPI/edge geometry, fullscreen exclusions, polygon hit testing, explicit close and native GDI region round trips. |
| `cargo fmt --all -- --check` from `windows` | Passed. |
| `cargo clippy --workspace --all-targets --features tokenotch-desktop/custom-protocol --locked -- -D warnings` from `windows` | Passed. |
| `npm test --prefix windows\desktop` | Passed: 41 frontend fixtures, including exact exposure thresholds, removed/clipped rows, sampling interruptions and combined visual preferences. |
| `npm run lint --prefix windows\desktop` | Passed. |
| `npm run test:browser --prefix windows\desktop` | Passed: 28 checks, including keyboard opening/closing, Tab boundaries, folded-card accessibility, scroll clipping, row replacement, large text, reduced motion/high contrast and keyboard positioning. |
| `npm run build --prefix windows\desktop` | Passed: production frontend. |
| `cargo build -p tokenotch-platform --examples --locked` and `cargo build -p tokenotch-hook --locked` from `windows` | Passed: isolated fixture/helper. |
| `python scripts\prepare.py --target x86_64-pc-windows-msvc --helper target\debug\TokenotchHook.exe` from `windows` | Passed: staged development resources. |
| `cargo build -p tokenotch-desktop --features custom-protocol --locked` from `windows` with the documented `.smoke` `TAURI_CONFIG` | Passed: isolated native desktop. |
| `npm run test:native --prefix desktop` from `windows` after the isolated build | Passed: actual Windows visual-preference lookup, passive hover, deliberate card focus, Escape restoring Settings focus, inert folded cards, untouched automatic alerts and earlier integration/navigation regressions. |
| `node scripts\docs\check.mjs` with pinned lychee 0.24.2 on PATH | Passed: Markdown and offline local links. |

The native focus check caught and corrected a visibility-bookkeeping mismatch:
direct Win32 showing made the window visible while Tauri still considered it
hidden. Managed visibility restores deliberate focus without changing the
region-folded card lifecycle. No installed app, real client settings, credentials,
Windows visual preferences or physical monitor configuration were modified.

Manual acceptance is still required for Narrator, physical transparent-corner
click-through, monitor hot-plug/primary changes, mixed DPI/text settings, native
outside-click behavior across other applications and per-display fullscreen
cases. Registered toast/audio/settings acceptance and ARM64 also remain open.

## Remaining parity and acceptance gates

The [Windows implementation plan](IMPLEMENTATION-PLAN.md) breaks the remaining
work into prioritized packages, source pointers and acceptance criteria for the
next implementation.

The September 30 verification above describes the original foundation revision,
not acceptance of the new integration features. Synthetic/native regressions do
not establish compatibility with real Copilot CLI or VS Code versions.

Full macOS parity is not yet certified. Source-aware history opportunity, coverage
charts and captured history/model/timeline evidence navigation are implemented.
Position uses an accessible edge slider rather than
Option-drag. The initial Windows UI is English. Context-crossing and explicit
service incident/recovery notification policies are implemented; real native
toast/audio/settings and physical multi-display acceptance remain open. Account
quota is displayed separately and intentionally does not trigger billing alerts.

Native ARM64 execution; actual CLI/VS Code delivery and browser account sign-in;
toast click/sound, Narrator, reduced transparency, acceptance of the native
click-through regions, multi-display hot-plug/fullscreen behavior; disposable install/uninstall and
upgrade/recovery; and signed release acceptance still require verification.
Do not describe this development build as a completed parity or release gate.

The helper supports `--self-test`, allowlisted CLI/VS Code hooks and the constrained
`--store` companion broker. Unsupported invocations fail before reading stdin.

Shared contracts are described in [contracts](../contracts/README.md). Existing
[privacy](../docs/tokenotch-privacy.md) and
[integration](../docs/tokenotch-integrations.md) documents remain behavioral
requirements; their macOS acceptance records do not certify Windows clients.

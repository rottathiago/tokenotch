# Windows implementation plan

Status: October 1, 2026. This document tracks the next implementation work
needed to bring Windows to macOS feature parity and then establish release
readiness. It is a backlog, not a claim that the unchecked features work.

The behavioral references are the [macOS feature reference](../docs/features.md),
[integration contracts](../docs/tokenotch-integrations.md) and
[privacy requirements](../docs/tokenotch-privacy.md). The
[Windows README](README.md) records the current implementation, setup instructions
and verification evidence.

## Starting point: do not rebuild these features

The Windows development build already includes consent-based CLI and VS Code
setup, private Windows storage and named-pipe transport, authenticated OTel
collection, live tokens/models/sessions/context, separate account quota,
optional history and timelines, telemetry imports, remembered notices,
stopped/error/request notifications, and saved multi-display widget preferences.

Native x64 builds and isolated WebView2/helper/broker checks have passed.
Synthetic checks do not prove delivery from real Copilot clients. The installer
has been built and inspected, but it has not been installed or uninstalled as
part of the new implementation's local acceptance.

## Recommended implementation order

| Order | Work package | Depends on | Completion evidence |
| --- | --- | --- | --- |
| 1 | History coverage and chart parity | Existing archive and usage services | Deterministic coverage/calendar fixtures and matching Usage/widget totals |
| 2 | History, model and timeline navigation | Stable period/source/coverage snapshots from package 1 | Browser and native navigation tests |
| 3 | Remaining notification policies | Existing account, health, attention and notification services | Policy fixtures, then real Windows notification acceptance |
| 4 | Desktop interaction and accessibility | Existing widget fleet; coordinate with packages 2 and 3 | Native display, keyboard and Narrator checks |
| 4a | macOS visual parity (notch, card, Settings) | Packages 1-3 data and navigation | Design fixtures/screenshots, browser and native WebView2 checks |
| 5 | Localization | Shared Windows string catalog introduced before adding more UI text | Missing-key checks and localized layout review |
| 6 | Real-client and architecture acceptance | Completed feature paths being accepted | Recorded CLI/VS Code versions and native x64/ARM64 evidence |
| 7 | Installer and release readiness | Accepted application behavior and packaging | Disposable install/upgrade/uninstall evidence and release gates |

Client compatibility checks can start early to expose integration problems.
They must not be confused with acceptance of unfinished features. Localization
infrastructure can also start in parallel; do not wait until every view is done
to centralize user-facing strings.

## 1. History coverage and chart parity

**Implemented: September 30, 2026.** Schema 2 stores source-specific recording
opportunity and coalesced gaps, with an all-source duration union. Usage, History
and widget charts now share explicit coverage states. Deterministic fixtures,
browser checks and isolated native x64 WebView2 checks passed; this does not
establish real-client delivery or ARM64/desktop acceptance.

- [x] Persist recording-opportunity durations and known gaps at the required
  resolutions, separately from whether a client actually delivered calls.
- [x] Implement distinct chart states for unavailable observations, partial
  coverage with no observed tokens, and zero tokens during recorded coverage.
- [x] Complete Today and Last 7 days chart behavior: elapsed hours only, current
  unfinished bucket markers, hourly aggregation across selected sources,
  zero-based scaling, and exact accessible values.
- [x] Render a labeled live-only Today chart when no saved archive exists;
  Last 7 days must continue to require history rather than fabricate old data.
- [x] Preserve the archive's reporting time zone, daylight-saving boundaries,
  seven-reporting-day hourly retention and 12/24-hour label preference.
- [x] Preserve saved-versus-live precedence, cache reporting availability,
  overflow attribution and explicit storage failures during all changes.
- [x] Add migrations without backfilling coverage that was never observed.

**Acceptance:** Cover restarts, pause/resume, deletion while recording,
midday opt-in, delayed events, imports, duplicate calls, the live sample cap,
midnight, daylight-saving changes and source filters. Saved Today totals must
agree between Usage and the widget; live samples must never be added to them.
An import must not increase recording-opportunity duration or live activity.

Evidence and exact commands/results are recorded in the
[Windows README](README.md#history-coverage-implementation-verification).
The fixtures include source changes without delivery, pause/restart/deletion,
late and duplicate calls, model overflow, 4,097 calls exceeding the live cap,
reporting midnight, 23/25-hour days, half-hour DST, schema-1 migration and explicit
storage failure. Isolated native checks compare the Usage and widget chart totals
and verify opportunity for CLI and both approved VS Code usage sources.

Start in [archive.rs](platform/src/archive.rs), [runtime.rs](platform/src/runtime.rs),
[calendar.rs](platform/src/calendar.rs),
[usage.js](desktop/src/usage.js), [insights.js](desktop/src/insights.js) and
[main.js](desktop/src/main.js). Compare with
[UsageHistoryStore.swift](../sources/Core/UsageHistoryStore.swift) and
[UsageTimeline.swift](../sources/Core/UsageTimeline.swift).

## 2. Detailed navigation and evidence

**Implemented: September 30, 2026.** History model filtering, captured chart/model
and insight evidence, cross-window widget routing, and complete retained
per-session timelines are implemented. Browser and isolated native x64 checks
passed; real-client, Narrator and broader desktop acceptance remain separate.

- [x] Add model filtering and model-specific period details, preserving
  unavailable and overflow contributions in denominators.
- [x] Connect widget chart/model selections to the exact period, source and
  model in History, or to the captured live-only breakdown in Usage.
- [x] Add complete per-session timeline browsing and direct links from live
  session details; expose reporting availability, latency and compaction fields.
- [x] Make truncation, retention pruning and recording interruptions explicit
  in timeline navigation rather than relying only on general help text.
- [x] Open each history insight's exact evidence: matched completed periods,
  call/model shares, independently sampled latency, compaction counts and gaps.
- [x] Preserve keyboard focus, scroll position and selected filters during
  background refreshes and when returning from a detail view.

**Acceptance:** Navigation must open the selected evidence, not a freshly
recomputed unrelated snapshot. Test cleared/expired targets, missing models,
unlinked VS Code usage, empty periods and archives larger than the display limits.
Context remains live and independent of historical usage filters.

Evidence and exact commands/results are recorded in the
[Windows README](README.md#detailed-navigation-implementation-verification).
Schema 3 adds independent timeline interruption and pruning metadata; older
timeline coverage remains explicitly unknown. Full source/period denominators
survive the 20,000-row display limit, and exact model queries can reach models
outside that limit. Hour selections show saved hourly totals without substituting
daily model attribution that was never recorded. Native checks exercise actual
widget-to-settings capture, live-session timeline links, focus restoration and
cleared targets without using real client settings.

Start in [main.js](desktop/src/main.js), [bridge.js](desktop/src/bridge.js),
[insights.js](desktop/src/insights.js) and the
[native commands](desktop/src-tauri/src/main.rs). Use the macOS
[HistoryInsights.swift](../sources/Core/HistoryInsights.swift) and
[SessionTimelineView.swift](../sources/Settings/SessionTimelineView.swift) as
behavioral references.

## 3. Remaining notification policies

**Implementation complete; native acceptance partially open: September 30, 2026.**
Context crossings and incident/explicit-recovery categories are wired with
independent consent, durable suppression, dispatch-time gating and timed
non-focusing cards. Deterministic, browser and isolated native card/routing checks
passed. The unregistered smoke identity cannot read Windows notification
permission; registered-installation toast/audio/settings and physical
multi-display acceptance remain required.
The final full-browser rerun also encountered concurrent chart markup changes;
notification-specific checks pass, but combined UI acceptance remains open as
recorded in the Windows README. That unrelated chart work was preserved.

- [x] Port supported context-crossing notification policy, including freshness,
  invalidation, rearming and cooldown behavior.
- [x] Add opt-in service incident/recovery notification behavior without treating
  a failed status fetch as an incident or recovery.
- [x] Reconcile account/usage alert expectations with the actual macOS policy.
  The ring's 75%/90% visual thresholds do not, by themselves, define a notification
  contract; do not invent AI-credit or billing alerts from token counts.
- [x] Add the required preference fields, migration defaults, controls and
  persistent deduplication for each supported category.
- [x] Apply mute, quiet hours, snooze, independent banner/sound/card choices,
  hidden/fullscreen displays and non-focusing automatic expansion consistently.
- [ ] Complete native acceptance for toast activation, expired targets, sound,
  multiple displays and Windows notification settings.

**Acceptance:** Test first observation, repeated observations, real threshold
crossings, stale data, account/reset changes, restarts and muted delivery.
Missed or muted alerts must not replay unexpectedly. Viewing or dismissing a
request must never answer it or imply that the request was resolved.

The [Windows README](README.md#notification-policy-implementation-verification)
records commands/results and remaining acceptance. Context uses a fresh 80%
crossing, below-70% rearming and ten-minute cooldown; live baselines reset without
erasing consumed cooldowns. Service alerts require incident IDs and explicit
resolution; first valid observations after startup/re-enabling establish a silent
baseline. Suppressed events and channel failures do not replay. Quota, account
reset and local token counts intentionally generate no billing alerts: macOS's
credit-target types have no current observation producer.

Synthetic multi-display/card and channel-failure fixtures are not physical
monitor, toast or sound acceptance. The isolated WebView2 check verifies a real
context-triggered card without focus theft or request acknowledgement, exact and
expired activation routes, and durable receipts. It deliberately emits no OS
toasts/audio and does not install/register an app or change Windows settings.

Start in [attention.rs](platform/src/attention.rs),
[preferences.rs](platform/src/preferences.rs), [runtime.rs](platform/src/runtime.rs),
[desktop.rs](platform/src/desktop.rs) and the
[native notification wiring](desktop/src-tauri/src/main.rs). Compare with
[NotificationPolicy.swift](../sources/Core/NotificationPolicy.swift).

## 4. Desktop interaction and accessibility

**Hardening implemented: October 1, 2026; physical acceptance remains open.**
Monitor identities, work-area recovery, DPI-aware regions, deliberate keyboard
focus, folded-card accessibility, clipped-row exposure and visual accessibility
preferences are wired and covered by deterministic/browser/native checks. This
does not certify Narrator or physical mixed-DPI/multi-display interaction.

- [x] Retain keyboard-accessible edge/position controls rather than introduce
  modifier-drag on Windows. Arrow keys and Home/End position the notch without
  assigning a conflicting Windows modifier gesture.
- [x] Preserve display ownership across enumeration changes; clear removed
  displays' card/pin/focus state and recover offscreen Settings into a work area.
- [x] Reject stale viewport/DPI/geometry region updates, invalidate regions when
  DPI changes, and use drawn polygons for the native hover bridge.
- [x] Add deliberate keyboard summary opening, a close control, Tab boundaries,
  Escape focus restoration and inert/hidden accessibility state for folded cards.
- [x] Track only currently rendered, at-least-half-visible notice rows inside
  scroll clips. Reset dwell on hiding, resizing, removal or missed sampling;
  preserve automatic-alert non-acknowledgement and independent request dismissal.
- [x] Follow Windows text/animation/transparency settings, add app text/effect
  controls, and support wrapping large text and high-contrast/reduced-effect layouts.
- [ ] Verify transparent corners pass clicks through on physical displays. Native
  GDI region round trips pass; mixed-DPI and multi-display acceptance is open.
- [ ] Complete physical focus/outside-click and per-row exposure review across
  display changes. Isolated native hover, deliberate keyboard focus, Escape
  restoration and untouched automatic cards have passed.
- [ ] Exercise monitor hot-plug, primary-display changes, negative coordinates,
  mixed DPI/scaling, taskbar edges and cramped work areas.
- [ ] Verify per-display fullscreen hiding, including fullscreen on an unfocused
  monitor and ordinary maximized windows that must remain distinguishable.
- [ ] Complete keyboard-only and Narrator review, high contrast, reduced motion,
  reduced transparency, text scaling and long-content layouts.

**Acceptance:** Every control and recovery route remains reachable without a
mouse. Display changes must not strand a widget or settings window offscreen.
Record actual Windows builds and display configurations; a browser preview is
not evidence for native input, focus, hit regions or accessibility.

Start in [desktop.rs](platform/src/desktop.rs),
[display.rs](platform/src/display.rs), [interaction.js](desktop/src/interaction.js),
[placement.rs](core/src/placement.rs), [main.rs](desktop/src-tauri/src/main.rs),
[main.js](desktop/src/main.js) and [styles.css](desktop/src/styles.css).

The [Windows README](README.md#desktop-interaction-implementation-verification)
records commands, actual native host/display configuration and outstanding
physical/Narrator gates. GDI region checks and simulated display/DPI matrices are
not substitutes for physical click-through, hot-plug or screen-reader acceptance.

## 4a. macOS visual parity

**Implemented: September 30, 2026.** The Windows notch, summary card and Settings
follow the macOS design in [sources/Notch](../sources/Notch),
[sources/DesignSystem](../sources/DesignSystem) and
[docs/design](../docs/design). Browser, unit, Rust and isolated native WebView2
checks passed; see the
[Windows README](README.md#visual-parity-implementation-verification).

- [x] Port the NotchLayout measurements (reference pixels × 44/117), Palette,
  Typography, 75%/90% thresholds and arc textures to
  [geometry.js](desktop/src/geometry.js), [presentation.js](desktop/src/presentation.js),
  [styles.css](desktop/src/styles.css) and [placement.rs](core/src/placement.rs).
- [x] Draw the side notch (inverse flares, every edge), Copilot glyph, quota ring,
  working arc, attention badge and the optional slim gauge (`autoHideNotch`).
- [x] Show the summary card in its own window beside the notch, with a tail aimed
  at the ring, macOS card placement, a hover bridge, click-to-pin, and
  Escape/outside-click/leave closing.
- [x] Mirror the card content and order of `tokenotch-stats1.png`, including the
  source menu, the Today/Last 7 days switch, coverage-marked bars, the coloured
  token breakdown, the top-three models with Remaining models, the footer links
  and the provenance line.
- [x] Clip native hit regions to the drawn shapes and fold the card through its
  region, so hover never re-shows (and activates) the card window.
- [x] Restyle Settings in dark mode after stats2/stats3. This covers the grouped
  sidebar (Appearance renamed General), the Copilot plan card, Today tiles and
  stacked token bar, attention cards, session rows, the History toolbar, the
  stacked daily chart and the model share table.

**Remaining:** physical-display click-through, focus and Narrator acceptance
(package 4). The design screenshots in `test-results/` come from fixtures, not
real usage. Windows notice pseudonyms keep request notices and live sessions as
separate rows, where macOS merges them.

## 5. Localization

**Current gap:** Windows user-facing strings are embedded in JavaScript and Rust,
and the initial interface is English.

- [ ] Introduce a shared localization strategy for frontend text, native errors,
  setup guidance, accessibility labels and notification content.
- [ ] Match the macOS application's supported languages and terminology after
  inventorying [L10n.swift](../sources/L10n.swift) and its resources.
- [ ] Preserve locale-aware number/date formatting and the explicit 12/24-hour
  preference without changing reporting zones or accounting.
- [ ] Add missing-key/interpolation checks and review longer translated layouts.

**Acceptance:** No untranslated implementation keys or raw native errors reach
the user. Translated strings cannot introduce HTML injection, hidden truncation
or inconsistent meanings for Not reported, Unknown, Partial and Stale.

## 6. Real-client and architecture acceptance

**Current gap:** Existing integration evidence uses synthetic clients and fake
account RPCs. Native ARM64 and actual supported client versions remain unverified.

- [ ] Verify CLI setup/repair/removal with the supported Windows distributions.
  Confirm executable discovery and whether npm launcher support is needed;
  account setup currently selects an `.exe`.
- [ ] Verify new and already-running CLI sessions, extension reload, long-running
  activity, usage/cache fields, context invalidation, compaction and explicit
  request/error hooks.
- [ ] Verify actual browser account sign-in, saved credentials, quota refresh,
  sign-out, protocol mismatch, offline/rate-limited responses and account changes.
- [ ] Verify VS Code Local lifecycle and separately enabled Local/Agent Host
  usage in supported local profiles, including Insiders where applicable.
- [ ] Exercise external collector conflicts, telemetry-off/managed settings,
  denied consent, expired/interrupted setup, source-specific removal and repair.
- [ ] Run native x64 and ARM64 checks on Windows 11 24H2/build 26100 or later;
  include the minimum supported build, not only a newer developer machine.
- [ ] Extend automated Windows fixtures where practical; keep macOS-only POSIX
  permission fixtures running on macOS rather than weakening their assertions.

**Acceptance:** Record OS/client versions, native architecture, commands/results,
actual observed delivery, and remaining limitations in
[compatibility](../docs/compatibility.md) and the Windows README. Require explicit
consent before using real client settings or credentials. Remote SSH, WSL,
containers, cloud agents and other providers remain outside this port's scope.

## 7. Installer and release readiness

**Current gap:** Unsigned development packaging exists. Inspection of an installer
is not installation, upgrade, recovery or uninstall acceptance.

- [ ] Use disposable environments to test clean install, launch, update,
  interrupted update, recovery and uninstall on both native architectures.
- [ ] Verify bundled helper/VSIX paths, Windows application identity, toast
  activation, WebView2 prerequisites and the static-runtime requirement.
- [ ] Define and test treatment of consented integrations and user data during
  upgrade/uninstall; never remove edited or unrelated client files.
- [ ] Establish the chosen release channel, signing requirements, publisher
  identity and publication workflow before distributing a supported release.
- [ ] Keep manual update lookup functional. Automatic updates are a separate
  future feature, not an implied requirement of the current macOS manual flow.
- [ ] Update release notes and compatibility claims only after evidence exists.

**Acceptance:** Follow the repository's [release guidance](../docs/releasing.md)
and [Windows packaging instructions](README.md#native-windows-development).
Use `verify-install.ps1` only in a designated disposable environment. Never
publish or install over a developer's existing app as an automated smoke test.

## Validation and handoff

Use the existing smallest applicable commands; the Windows README contains the
full build and isolated native-smoke prerequisites.

```powershell
# From the repository root
npm test --prefix windows\desktop
npm run lint --prefix windows\desktop
npm run test:browser --prefix windows\desktop
node --test integrations\VSCode\test\windows.test.cjs

# From windows
cargo test -p tokenotch-core -p tokenotch-platform -p tokenotch-hook --locked
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --features tokenotch-desktop/custom-protocol --locked -- -D warnings
```

For each completed package, check its items, record exact commands and outcomes,
update affected documentation, and keep implementation status separate from
real-client, desktop, architecture and release acceptance. Preserve existing
uncommitted work; this plan does not authorize commits, publication, installation,
credential access or automatic client configuration.

The next focused implementation should be **package 5: localization**, while
package 4's physical display/Narrator acceptance remains open. Package 3's
registered-installation toast/audio/settings acceptance also remains unchecked.
Real-client, architecture, desktop and release acceptance remain separate gates.

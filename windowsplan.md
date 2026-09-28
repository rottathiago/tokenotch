# Tokenotch for Windows implementation plan

Prepared: September 28, 2026.

Status: proposed implementation plan, not a support or release commitment.
This document does not add a Windows application or change the macOS release.

## 1. Goal and planning decisions

Build a Windows-native desktop companion with the same truthful Copilot activity,
usage, consent, and privacy semantics as Tokenotch on macOS.
Use a separate Windows implementation rather than attempting to compile SwiftUI
or AppKit for Windows.

| Area | Proposed decision |
| --- | --- |
| Native/backend language | Rust, using the MSVC Windows toolchain |
| Desktop framework | Tauri 2, with WebView2 for rendering |
| Interface | TypeScript, HTML, and CSS; Vite for development and bundling |
| Frontend structure | Small typed view/state modules; start without a larger UI framework |
| Initial platform | Windows 11 x64, standard non-administrator accounts |
| Installer | Per-user NSIS setup executable produced through Tauri |
| macOS application | Keep the existing Swift/SwiftUI application and release pipeline |
| Shared surfaces | Explicit event contracts, synthetic fixtures, approved branding, and compatible JavaScript integrations |
| Updates | User-initiated release checks and manual installation initially; no automatic updater in the first release |
| Development model | Windows development/test machine plus Windows CI; macOS can support documentation and portable work |

Select the exact supported Windows 11 builds, Rust/Node versions, and client
versions during the feasibility phase. Pin toolchains and dependencies then.
An x64 binary running under ARM emulation is not native ARM64 support.

### Initial preview versus supported beta

The first internal preview should support Copilot CLI lifecycle and numeric usage,
a tray icon, an edge widget, connection setup, and explicit failure/stale states.
Optional account quota is a separate feature and must not block local activity.

A supported beta additionally requires local VS Code lifecycle and numeric usage,
independent notification controls, the agreed history/timeline subset, accessible
desktop interactions, and an exercised installer/upgrade/uninstall path.
Do not call the CLI-only preview a feature-complete Windows port.

Defer Windows ARM64, Windows 10, WSL, SSH, containers, Codespaces, cloud agents,
other providers, automatic updates, enterprise deployment packages, and
historical telemetry import. Advanced history insights can follow the beta.
Deferred features must be absent or explicitly unavailable, never simulated.

## 2. Existing foundations and required changes

Treat the following as implementation references, not Windows compatibility claims:

| Existing surface | Windows work |
| --- | --- |
| [Integration contracts](docs/tokenotch-integrations.md) and [compatibility matrix](docs/compatibility.md) | Preserve semantics; establish a separate Windows client/OS acceptance matrix |
| [Activity normalization](sources/Core/Activity.swift) and [usage models](sources/Core/CopilotUsage.swift) | Implement Rust equivalents with shared synthetic golden fixtures |
| [Native hook](sources/Hook/TokenotchHook.swift) and [local bridge](sources/Core/LocalBridge.swift) | Replace Darwin calls, Unix sockets, and Unix ownership checks with Windows implementations |
| [Copilot runtime](sources/Core/CopilotRuntime.swift) | Adapt executable discovery, stdio RPC, environment isolation, timeouts, and process cleanup |
| [CLI extension](integrations/CopilotUsage/extension.mjs) | Keep supported event handling; add an explicit Windows helper-path/launch adapter |
| [VS Code companion](integrations/VSCode/src/companion.cjs) and [private storage](integrations/VSCode/src/private-store.cjs) | Replace the macOS-only gate only after Windows storage and ownership checks exist |
| [OTel receiver](sources/Core/OTLPReceiver.swift) and [normalizer](sources/Core/CopilotOTelNormalizer.swift) | Replace Apple's Network implementation while preserving admission and accounting rules |
| [Usage history](sources/Core/UsageHistoryStore.swift) and [timeline storage](sources/Core/SessionTimelineStore.swift) | Implement scoped Rust storage, migrations, and independent retention controls |
| [Notch presentation](sources/Notch/NotchPresentation.swift) and [palette](sources/DesignSystem/Palette.swift) | Re-create product behavior in a Windows-appropriate interface, not a SwiftUI translation |
| [Release identity](config/Release.json), [metadata generator](scripts/release-config.py), and [release runbook](docs/releasing.md) | Extend platform-aware generation and add separate Windows acceptance/signing gates |

Two repository blockers must be handled deliberately:

- [The publication checker](scripts/check-project.py) currently rejects every
  `windows/` path as a retired distribution tree. Update that policy and its
  [tests](scripts/test-project.py) before admitting the new Windows source tree.
  Continue rejecting generated output, installer binaries, secrets, and retired
  product identities.
- The VS Code companion requires `process.platform === "darwin"` and relies on
  UID, mode bits, `O_NOFOLLOW`, and Unix directory synchronization. Removing the
  platform check without replacing those protections is not a Windows port.

Use the current lowercase top-level folders. Preserve the existing worktree and
case-only renames. Do not restore the deleted historical Windows implementation.

### Provenance boundary

Write new Windows implementation code from Tokenotch's requirements, approved
contracts, and platform documentation. Do not copy or mechanically translate
the previously reviewed upstream Windows source, styles, comments, or artwork.
Review the provenance of any reused Tokenotch files, fixtures, and assets too.

Keep the current [MIT notices](LICENSE) intact. A new Windows implementation
does not remove obligations from macOS code, reused assets, or published history.
Record third-party dependencies and notices in the Windows distribution.
This plan is not a clean-room claim or legal clearance to remove attribution.

## 3. Architecture and repository layout

### Proposed new tree

All paths below are planned, not files already provided by this task.

```text
windows/
  README.md
  Cargo.toml
  Cargo.lock
  rust-toolchain.toml
  config/
    release.json
  core/
    Cargo.toml
    src/
  hook/
    Cargo.toml
    src/
  desktop/
    package.json
    package-lock.json
    src/
      components/
      views/
      state/
      styles/
    src-tauri/
      Cargo.toml
      build.rs
      tauri.conf.json
      capabilities/
      src/
        platform/
        commands/
        integrations/
  scripts/
    build.ps1
    package.ps1
    verify-install.ps1
  tests/
    integration/
    desktop/
contracts/
  events/
  fixtures/
```

The Rust workspace members are `core`, `hook`, and `desktop/src-tauri`.
Build outputs under `windows/target`, frontend output, sidecar staging files,
and dependency directories must be ignored and excluded from source publication.

### Responsibility boundaries

- **Rust core:** validation, accounting, deduplication, ordering, stale states,
  consent/retention policy, and storage. Keep domain logic independent of Tauri
  so synthetic tests do not need a WebView or real client.
- **Native app:** Windows handles and APIs, per-user single-instance behavior,
  private files, named pipes, OTel receiver, controlled child processes,
  notifications, tray integration, and window positioning.
- **Native helper:** bounded stdin, content stripping, normalization, and
  authenticated delivery. It must not contain a WebView or require users to
  install Rust, Python, or Node.
- **Frontend:** render sanitized typed snapshots and request narrowly defined
  actions. No direct credential access, arbitrary filesystem access, or shell
  command execution.
- **Existing JavaScript integrations:** share contract-level behavior where
  appropriate, with explicit macOS and Windows adapters rather than a forked,
  silently diverging copy of the companion.

Generate or validate Rust/TypeScript contract types from versioned definitions.
Expose specific commands such as reading connection status or requesting setup,
not a generic native command runner. Define per-window capabilities and explicit
custom-command permissions; registering a Tauri command alone does not restrict
which app window may invoke it.

### Windows paths and identity

Use the Windows Known Folder API for a private local data root, proposed as
`%LOCALAPPDATA%\Tokenotch`. Keep installed executable files separate from mutable
data. Do not use the current directory or accept a data/helper path supplied by
an untrusted URI.

Use a per-user, non-elevated installation. Confirm the installation directory,
AppUserModelID, notification activation, startup registration, and helper location
in the feasibility prototype. Do not assume another application's identifier
or registration.

Keep product version, publisher, and repository derived from
`config/Release.json`. Its `minimumOS` and current bundle settings are
macOS-specific: do not reinterpret them as Windows settings. Store Windows-only
support/packaging fields in `windows/config/release.json`; extend the metadata
generator with validation and fixtures rather than maintaining unrelated copies
of product versions.

## 4. Integration, privacy, and correctness requirements

### Shared semantics

Extract synthetic fixtures before porting behavior. Capture both raw test inputs
and expected normalized output without using real user events.

- Preserve supported event schemas 1 through 4 and reject unknown versions.
  Keep CLI usage accounting contract 1 and explicit cache-reporting availability.
- Specify timestamp units and encoding at every boundary. CLI hook milliseconds,
  setup-request Unix seconds, and Swift's encoded `Date` representation must not
  be assumed interchangeable.
- Preserve bounded integer checks, Boolean-versus-number rejection, pseudonymous
  identifiers, and the distinction between absent, zero, unlimited, and stale.
- Stopped does not mean successful. Viewing/dismissing a request does not approve
  it or prove resolution. Usage observations do not establish task lifecycle.
- Keep account quotas separate from local token observations and saved history.
  Do not assume the quota account is the one used by either local client.
- Preserve source attribution and avoid counting CLI usage again through VS Code
  telemetry. Agent Host usage is not evidence of Agent Host lifecycle coverage.
- Preserve authoritative context-event precedence, model/reset invalidation,
  bounded fallback reads, and explicit unavailability of unsupported Preview RPCs.

Freeze the initial contract fixtures at a reviewed revision. Run equivalent
Swift and Rust fixtures on their respective CI platforms; a behavior change
requires a deliberate contract decision, not an accidental port difference.

### Private helper transport and files

Use per-installation local named pipes for normalized helper events, with an
explicit security descriptor restricted to the intended user/logon context.
Reject remote pipe clients, verify peer identity, detect pipe-name squatting,
and retain installation/source authentication. A pipe name is not a secret.

Replace Unix permission checks with handle-based Windows validation: owner SID,
effective DACL, reparse-point/junction rejection, hard-link policy, file identity,
bounded reads, and safe atomic replacement. Validate ancestors and leaf objects;
do not make a path-based check and then blindly reopen a different object.
Protect persistent registration secrets with user-scoped Windows protection
where appropriate. File ACLs do not imply encrypted database contents or
protection from malware already running as the same user.

For the VS Code private-store adapter, use a reviewed native broker for these
operations rather than weakening existing checks in JavaScript. Limit the broker
to fixed owned request/receipt/result operations. Resolve its executable from a
verified installation location, never from arbitrary URI arguments.

The helper must produce no approval response or raw payload on stdout. Bound
input, delivery time, queue size, and retries. An unavailable app must not block
the coding agent or silently appear healthy: record only a fixed safe health
status and expose recovery in Connections.

### Copilot CLI

Verify the actual supported Windows CLI distribution before selecting a launcher.
Do not assume a native `copilot.exe` always exists. Prefer a directly executable
supported entry point; if a shim is necessary, explicitly validate its invocation
and quoting for spaces, Unicode, and shell metacharacters.

Use official hooks and the existing numeric usage extension. Patch only owned
hook entries, retain unrelated client configuration, and provide repair/removal
receipts. Updating the helper must not be reported as reloading existing client
sessions.

For optional account quota, use the official CLI's explicit browser sign-in and
bounded read-only stdio RPC. Preserve separate `COPILOT_HOME`, saved-credential
loading, protocol negotiation, identity consistency checks, and cancellation.
Adapt the minimal child environment to Windows runtime requirements without
inheriting ambient authentication tokens or unrelated telemetry settings.
Own launched process trees with Windows job objects and reap them on timeout or
app exit. Do not create an inference session to obtain quota.

### VS Code and OTel

Retain public configuration APIs, user confirmation, selected installation/profile
ownership, expiring requests, nonce checks, and selective cleanup. Preserve
unrelated collectors, environment overrides, managed settings, and user edits.
Provide Windows-specific recovery copy rather than macOS paths or shortcuts.

Keep lifecycle and numeric telemetry setup independent. The current
`1.138.0` engine target is a contract target, not proven Windows acceptance.
Record actual client and extension versions and verify delivered observations.
Remote windows remain unsupported even when their UI runs locally.

Implement the OTel listener separately from the helper pipe. Bind only to
loopback, use installation credentials and producer-specific routes, reject
browser-origin requests, and never log credential-bearing URLs or raw spans.
Preserve the existing 4 MiB body limit, 16 KiB header limit, 2,048-span limit,
eight concurrent connections, and five-second deadline unless a reviewed
contract change is made. Test fixed-length and uncompressed chunked framing.

### Consent and retention

Follow [the existing privacy contract](docs/tokenotch-privacy.md), with Windows
paths and notification-system behavior documented separately. Account sign-in,
VS Code metrics, notifications, usage history, timelines, remembered notices,
startup, and public service health must not enable one another implicitly.

Keep optional persistent collections off on a fresh installation. Never retain
prompts, responses, commands, repository names, raw hook input, or raw telemetry.
Provide separate clear-live, history, timeline, notice, and account-disconnect
actions. Removing a source does not delete unrelated history.

Version Windows storage independently if necessary; preserve behavioral and
accounting compatibility through fixtures. Do not promise database interchange
or import another installation's database. Reject unknown/corrupt schemas without
overwriting them. Exercise migrations, locked files, full disks, crash recovery,
and concurrent writers.

## 5. Desktop UX and visual direction

Keep Tokenotch recognizable while behaving like a Windows utility, not a web
dashboard floating above the desktop.

| Design choice | Direction |
| --- | --- |
| Primary surface | Compact screen-edge activity indicator, expanding into a left-aligned session list |
| Secondary surfaces | Native tray entry, focused details, and a conventional settings window |
| Typography | Segoe UI Variable with Segoe UI/system fallbacks; tabular numerals for changing counts |
| Baseline colors | Surface `#000000`, foreground `#FFFFFF`, secondary `#A6A6A6`, working `#58A6FF`, stopped `#BC8CFF`, attention `#E3B341` |
| State communication | Words, icons, progress texture, and timestamps in addition to color |
| Motion | Restrained state feedback; respect reduced-motion settings and avoid persistent decorative animation |
| Accessibility | Keyboard operation, visible focus, Narrator labels, zoom/text scaling, and Windows high-contrast behavior |

The palette references current product semantics, not proof of asset ownership.
Use approved Tokenotch artwork and implement Windows geometry independently.
Do not add a macOS camera-notch imitation or a generic card-grid layout.
High-contrast settings override fixed visual tokens when required.

The collapsed indicator must not steal keyboard focus. A deliberately opened
interactive surface needs a reliable keyboard entry/exit path. Test transparent
regions for click-through and visible controls for hit testing; do not make the
whole window globally click-through.

Support four screen edges, saved placement, taskbar/work-area changes, monitor
hot-plugging, mixed DPI, and sleep/resume. Fullscreen hiding must be per display.
Restore a reachable position when a monitor disappears. Default startup behavior
must remain user-controlled.

Review the first implementation against actual Tokenotch tasks: identify working
sessions, distinguish an unresolved request from a stopped turn, inspect usage,
and repair a disconnected client. Remove visual elements that do not help those
tasks before adding cosmetic polish.

## 6. Delivery phases and exit criteria

Estimates below are working days for one experienced developer, not commitments.
They exclude waiting for signing identity, accounts, hardware, or owner approval.

| Phase | Depends on | Deliverables | Exit criterion | Estimate |
| --- | --- | --- | --- | --- |
| P0: feasibility and scope | None | Windows environment; disposable Tauri overlay/tray prototype; real-client compatibility probes; approved beta scope and performance targets | Prove window behavior and supported client entry points; record unsupported capabilities rather than assuming parity | 3-5 days |
| P1: foundation | P0 | New workspace, locked dependencies, source-publication rules, metadata generation, fixture layout, baseline CI, development packaging skeleton | Fresh Windows checkout builds; macOS checks remain intact; generated artifacts are excluded | 2-4 days |
| P2: contracts and secure transport | P1 | Rust validation/state core, golden fixtures, private files, named-pipe transport, helper and health reporting | Positive/negative fixtures agree with the contract; forged, malformed, cross-user, stale, and oversized inputs are rejected | 5-8 days |
| P3: CLI vertical slice | P2 | Owned hook setup/removal, shared extension adapter, live activity/tokens/context, optional account quota | A supported real Windows CLI session delivers data; repair, cancellation, shutdown, and unavailable states work | 4-7 days |
| P4: Windows presentation | P1; final integration needs P3 | Edge widget, tray, settings/onboarding, keyboard/Narrator support, monitor/DPI/fullscreen behavior | Internal CLI preview passes desktop scenarios without stealing focus or stranding windows | 4-7 days |
| P5: VS Code integration | P2 and P3 | Windows private-store broker, companion adapters, Local lifecycle, separate OTel producers and metrics consent | Real accepted Windows VS Code clients deliver the advertised capabilities; no duplicate CLI accounting; macOS companion regressions pass | 6-10 days |
| P6: beta retention and notices | P3 and P5 | Scoped history/timelines, notifications and remembered notices, migrations, independent clearing/retention | Synthetic and real scenarios preserve consent, totals, deduplication, and notice semantics across restart/recovery | 5-9 days |
| P7: distribution and acceptance | P4, P5, and P6 | Final installer, signing, upgrade/uninstall checks, support docs, exact-artifact acceptance, protected release workflow | Signed candidate passes all agreed beta gates; owner explicitly authorizes publication | 5-10 days |

Start P4's fixture-driven UI work after P1 while backend work continues if a second
developer is available. Packaging feasibility begins in P1; do not discover
sidecar installation problems only in P7.

Planning envelope: roughly 4-6 developer-weeks for the internal CLI preview and
7-12+ developer-weeks for the scoped beta. Re-estimate after P0 and P3.
Full macOS feature parity is a separate milestone, not included automatically.

### Suggested first implementation batch

1. Record the Windows 11 x64, local-client-only preview boundary and obtain a
   real Windows test environment.
2. Prove a transparent non-focus-stealing Tauri edge window, tray/settings
   access, and the supported Windows CLI launch/authentication path.
3. Extract representative synthetic activity, usage, context, and invalid-input
   fixtures from the current contracts.
4. Update the publication checker and tests, then scaffold only the new Windows
   workspace and platform-aware metadata.
5. Add a minimal Windows CI build and an installer containing a placeholder-free,
   runnable app/helper pair before integrating live user data.

Stop or revise scope if supported client APIs cannot deliver a required feature.
Do not substitute transcript scraping, credential discovery, or guessed usage.

## 7. Installer, updates, and release process

### Development packaging

Produce a clearly labeled development NSIS installer for Windows x64. Stage the
native helper separately before Tauri bundling and use the correct target-triple
sidecar naming. Verify the installed helper's actual path; do not assume its
build-time suffix or relative location survives bundling unchanged.

Bundle only the app, native helper, frontend assets, approved branding, license
notices, release metadata, and the local VS Code companion where required.
Do not bundle development dependencies, fixtures, credentials, or private data.
Use a stable helper location whose upgrade behavior is tested against installed
hook references. Install required runtime components or link them appropriately;
end users must not need the Rust toolchain or Visual Studio.

Install WebView2 through a documented Evergreen bootstrapper path when missing.
Explain any network requirement and show an actionable installation failure.
Do not promise fully offline installation unless an offline-runtime package is
explicitly built and exercised.

### Upgrade and removal

Require a standard-user fresh install, reinstall, upgrade from the prior beta,
and attempted downgrade. Preserve settings and consent, handle locked executables,
stop only owned processes, and fail visibly on incomplete upgrades.
Reject downgrades that cannot safely read the installed storage schema.

Before uninstalling executables, attempt selective removal of owned client
configuration and invalidate receiver credentials. Preserve unrelated hooks,
collectors, and user edits. If editor approval/reload is required, explain the
remaining cleanup rather than claiming complete removal.

Keep user data by default on uninstall. Offer a separate explicit deletion
choice with an exact inventory and boundary checks. Remove owned startup/tray
registrations and executable files; never delete another product's directory.

### Production distribution

- Sign and timestamp the app, helper, and setup executable using an owned
  Authenticode identity or supported signing service. Keep private material out
  of Git and PR jobs.
- Verify signatures, architecture, embedded identity, resources, dependency
  notices, and SHA-256 checksums after packaging.
- Evaluate browser-download/SmartScreen behavior on a clean Windows system.
  Signing is not a guarantee that every new binary immediately has reputation;
  do not make bypassing security warnings the installation procedure.
- Generate a dependency/license inventory and exact-revision build record.
  Record acceptance against the actual candidate artifact as well as its source.
- Publish only through the configured Tokenotch repository and an owner-approved,
  protected release job. Never inherit another project's publisher, release
  endpoint, signing key, or workflow credentials.

Keep the initial update policy consistent with macOS: an explicit user action
checks the official release service and opens the relevant official download.
Filter for a compatible Windows asset and stable channel; absence of a Windows
asset is not an available update. Do not bundle repository access tokens.

Automatic Tauri updates are a later, separately approved feature. They require
updater signature keys, feed/channel design, key rotation/recovery, consent,
rollback/schema policy, and additional testing. Updater signatures do not replace
Windows Authenticode signing.

## 8. Validation and CI

Create separate Windows build/test and protected release jobs. Shared contracts,
integration adapters, metadata generators, or companion changes must also trigger
the relevant macOS jobs. Pin actions and toolchains, use locked dependencies, and
give PR jobs no signing or publishing secrets.

The following are proposed commands once the workspace and package scripts exist:

```powershell
# Run from windows/; these commands are not available from this plan alone.
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
npm ci --prefix desktop
npm run typecheck --prefix desktop
npm test --prefix desktop
npm run build --prefix desktop
.\scripts\build.ps1
.\scripts\package.ps1 -Development
.\scripts\verify-install.ps1
```

Define those scripts in P1/P7; make them fail on missing inputs, wrong architecture,
missing sidecars, stale metadata, or failed verification. Do not silently build a
different target or return a success-shaped fallback.

### Required test matrix

| Area | Required cases |
| --- | --- |
| Contracts | Schema versions, timestamp units/bounds, malformed fields, unknown models, absent/zero counts, cache categories, context invalidation |
| Lifecycle | Working/stopped/failed/cancelled, out-of-order events, duplicates, restart, stale observations, no inferred approvals or successes |
| Privacy and IPC | Content stripping, wrong user/source/registration, pipe squatting, expired nonces, reparse points, hard links, changed file identity, bounded input/queues |
| Client setup | Fresh setup, refusal/cancellation, repair, partial failure, changed profile/install identity, managed policies, reload requirements, selective removal |
| Metrics | Local versus Agent Host routing, parent-span filtering, CLI double-count prevention, missing conversation identity, malformed/chunked/oversized HTTP |
| Persistence | Consent boundaries, migrations, database locks, disk-full errors, crash recovery, repeated events, independent clearing and deletion failures |
| Desktop | Mixed DPI, multiple displays, each screen edge, taskbar changes, fullscreen per display, lock/unlock, sleep/resume, keyboard, Narrator, high contrast |
| Packaging | No Rust/Node developer installation, missing WebView2, paths with spaces/Unicode, standard-user install, helper delivery, upgrade/downgrade, uninstall |
| Compatibility | Exact Windows/client/extension versions; optional Preview features explicitly classified; unsupported remote contexts rejected |

Most checks must use synthetic input, fake clients, and disposable private
directories. Real-client tests require consent and must never read developer
credentials or modify real hooks merely because CI ran.
Hosted CI does not certify interactive desktop, hardware, Narrator, or actual
client behavior; maintain a manual acceptance checklist with retained evidence.

### Provisional performance targets

These are proposed budgets to measure in P0 and approve before release, not current
performance claims. Record reference hardware and include app, helper, and
WebView2 child processes in measurements.

- First usable UI: p95 at or below three seconds over 20 normal launches with
  WebView2 already installed; measure cold starts separately.
- Idle CPU: average at or below 1% of one logical core over 30 minutes, including
  normal idle polling.
- Warm idle private working set: at or below 200 MiB for the app/WebView process
  group; measure loaded-session/history scenarios separately.
- Helper delivery: p95 at or below 100 ms under normal local load, with an overall
  one-second delivery deadline after bounded stdin collection.
- Accepted live event to visible state: p95 at or below one second while the
  relevant UI is open.

Exercise the current session/receipt capacity limits and a sustained synthetic
burst without unbounded memory growth. Report failed budgets and revise the design
or explicitly reapprove targets; do not silently relax them after implementation.

## 9. Risks and decisions to close

| Risk or decision | Planned response |
| --- | --- |
| CLI/VS Code contracts differ or are unavailable on Windows | Probe real clients in P0; publish per-capability status; block required support claims |
| Transparent WebView windows have focus, hit-test, or high-DPI defects | Prototype early; keep a tray/settings recovery path; use narrowly scoped Win32 code |
| Cross-platform companion changes regress macOS | Keep platform adapters explicit and require both operating systems' tests |
| Replacing UID/mode checks weakens isolation | Implement native SID/DACL/handle checks and adversarial fixtures before removing platform gates |
| Historical Windows code or artwork is accidentally reused | Keep new implementation provenance and notices review; do not restore the retired tree |
| Existing publication policy blocks the new tree | Change and test it in P1, retaining generated-output and secret exclusions |
| Signing, reputation, and managed-device policy delay release | Begin identity/distribution planning early; keep development builds distinct from public releases |
| History/notice parity expands the first milestone | Freeze beta feature scope in P0; defer import/advanced insights explicitly |
| Frontend receives sensitive native state | Use sanitized DTOs, strict CSP, explicit command/window permissions, and no remote UI content |
| Windows-only defects escape a macOS workflow | Require Windows CI and real Windows acceptance; cross-compilation alone is insufficient |

Review contributor/reporting readiness, dependency licensing, and platform-specific
privacy documentation before public participation or distribution. These are
independent of whether the application compiles.

## 10. Definition of done for the supported Windows beta

- [ ] The agreed Windows 11 x64/client combinations are recorded with real
  delivery evidence; unsupported combinations are clearly identified.
- [ ] CLI and local VS Code connections work without inferred telemetry,
  credential scraping, or unwanted changes to client configuration.
- [ ] The edge widget, tray, onboarding, settings, focus behavior, accessibility,
  multi-display placement, and fullscreen behavior pass acceptance.
- [ ] Every shipped optional collection and notification feature has independent
  consent, bounded data, explicit failure states, and correct removal behavior.
- [ ] Contract, native, frontend, companion, installer, and macOS regression checks
  pass for the selected revision.
- [ ] Standard-user install, upgrade, recovery, and uninstall work on a clean
  machine without development tools.
- [ ] App/helper/installer identity and signatures, required notices, checksums,
  dependency inventory, and artifact contents are verified.
- [ ] Measured performance meets the approved budgets.
- [ ] Windows setup, compatibility, privacy, troubleshooting, and release docs
  describe delivered behavior rather than future plans.
- [ ] The owner approves exact-revision/exact-artifact release evidence and
  publication through the protected release process.

## References

- [Tokenotch feature reference](docs/features.md)
- [Tokenotch integration contracts](docs/tokenotch-integrations.md)
- [Tokenotch privacy and retention](docs/tokenotch-privacy.md)
- [Tokenotch compatibility and acceptance](docs/compatibility.md)
- [Tokenotch release process](docs/releasing.md)
- [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/)
- [Tauri Windows installers](https://v2.tauri.app/distribute/windows-installer/)
- [Tauri sidecar packaging](https://v2.tauri.app/develop/sidecar/)
- [Tauri capabilities and custom-command permissions](https://v2.tauri.app/security/capabilities/)
- [Tauri Windows signing](https://v2.tauri.app/distribute/sign/windows/)
- [Windows named-pipe security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)

# Setup, recovery, and uninstall

## Unsigned downloads

Official GitHub Releases may offer unsigned DMG and PKG installers. Signing and
Apple notarization are optional; the release notes identify the actual status,
source revision and SHA-256 checksums. Only download installers from
[the official release page](https://github.com/rottathiago/tokenotch/releases).

macOS may refuse to open an unsigned installer or application. After trying to
open it, if you trust that download, go to **System Settings > Privacy & Security**
and choose **Open Anyway** where available. Confirm the per-app approval, then
open Tokenotch from Applications. See [Apple's instructions](https://support.apple.com/en-us/102445).
Managed Macs may prohibit this; contact your administrator rather than bypassing
their policy. Do not disable Gatekeeper, remove quarantine, or override warnings
that software contains malware or is damaged.

An unsigned release's app is ad-hoc signed but has no verified Apple Developer ID
and has not been notarized. A regular GitHub release can still be offered by
**Check for Updates**; that lookup is not an Apple trust or security assessment.

## Connections

First-run onboarding includes the client-specific guides directly. Choose Copilot
CLI, Visual Studio Code or experimental Claude Code CLI metrics and successfully
configure at least one before finishing.
Account quota and VS Code model/token usage are optional; account sign-in alone
does not satisfy the client requirement. No activity event is needed to finish,
but the result remains **Waiting for first activity** until data arrives.

For VS Code lifecycle activity, use a **Local** session target. Copilot sessions
on Agent Host use a different hook implementation; their separately enabled
model/token telemetry does not establish lifecycle or attention coverage.

**Pause setup** and window dismissal save your unfinished step and chosen client,
without marking setup complete. **Resume Setup** in Settings reopens it. External
browser or editor approval leaves the guide at the same step. If Tokenotch quits
before VS Code approval is processed, review the choices and request fresh
approval rather than reusing an old request. Within the same app session,
**Open approval** reuses the pending request, even after pausing the guide.

Errors and recovery actions stay inside the guide. A failed optional feature or
second client does not block finishing when one chosen client is configured;
the welcome summary explains what remains unfinished. If all clients are blocked,
pause and resolve the reported problem or contact your administrator.

After first-run setup, use Settings > Connections to add, repair, or disconnect
clients. General > Review Setup Guide preserves existing connections and consent.
Collection requires explicit setup. Reload every existing CLI session after an extension
update; reloading one session does not reload others. For VS Code, select the
editor application, not Tokenotch, and approve changes in the original local profile.

Updating Tokenotch.app does not replace the CLI's separately installed extension.
Connections checks that the installed extension matches the app's bundled version
and marks missing or outdated setup as needing repair. Use **Review or repair
setup > Repair setup**, then reload extensions or restart **each** CLI session.
An older extension can still deliver activity while incorrectly replacing context
percentages during idle or user-attention pauses; “Data received” alone does not
establish that the latest integration is running.

“Waiting for data” means no actual supported delivery has been verified.
Workspace overrides, enterprise policy, unsupported versions, disabled
telemetry, or an intentional external collector can block a capability. Tokenotch
will not override those controls. Usage and lifecycle have separate statuses.
Unsupported quota/metric APIs do not justify scraping client storage or tokens.

### Experimental Claude Code CLI

Choose **Set up Claude Code** in Connections or the setup guide. Select the
local user configuration root, default `~/.claude`, and first check Claude
`/status` for managed telemetry or an external collector. Do not continue if
either applies. Tokenotch cannot inspect the client's effective shell environment
or server-managed policy. Existing exporter settings, opt-outs, unsafe files,
symlinks and visible managed policy are blockers, not settings to overwrite.

Setup inserts only approved logs-only exporter entries, with content capture off.
If an owned `settings.json` is readable by other users, setup shows **Make Claude
settings private?** before reading it or enabling collection. **Make private and
continue** changes only that exact file to owner-read/write (`0600`), then resumes
the normal setup checks. **Cancel** leaves permissions and settings unchanged.
The folder is not modified; a normal owned `0755` folder is accepted. File
ownership, symlinks, hardlinks and unsafe directories are not repaired
automatically. Private file permissions remain after disconnect.
Restart Claude and use an ordinary session to verify **Data received**; Configured
alone is not delivery evidence. CLI metrics do not establish lifecycle or quota.
Only local Claude Code CLI sessions are collected. Other Claude clients,
remote sessions and working/attention events are not collected. No local installation
marker is required.
If Connections reports unsupported observations, the warning now names the
most frequent rejection reason in the latest batch. Expand **Coverage and
privacy** for in-memory reason counts. A missing server request ID is a
compatibility limit: Tokenotch does
not invent identities or count those calls. These diagnostics contain fixed
categories and counts, never rejected field values or raw telemetry.

The former experimental Desktop integration is removed. Startup retires only
unchanged marker entries owned in the CLI settings receipt; other settings and
saved history remain. If you manually pasted `tokenotch.local_installation`
into an environment in the Claude app, remove only that attribute there.
Tokenotch never reads or edits the app's private environments.
No minimum supported version is established; see the
[contract and acceptance evidence](claude-code-contract.md).

For account sign-in, expand **Claude account sign-in** in Connections. Select
the official Claude CLI executable, choose **Sign in to Claude**, and finish
the CLI's browser flow in Terminal. Choose **Check sign-in** to reuse or verify
an existing login. Checks keep only authentication status/method, not identity
fields or credentials, and use the selected CLI configuration root.
**Stop account checks** preserves the shared CLI login; it does not run logout.
Account sign-in does not enable telemetry, saved history or quota collection.

For quota/reset windows and per-session context, choose **Enable quota & context**
under the Claude connection after metrics setup. This separate opt-in uses
Claude's documented CLI status line, not credentials or transcript scraping. Existing
status lines are never replaced: resolve the displayed conflict in Claude before
retrying. Existing sessions report on their next status-line update; resume or
restart if needed. Project settings can override the user status line.
The custom status line may hide some built-in Claude keyboard hints.

Eligible subscriptions report 5-hour and 7-day usage and reset times after an
API response. If Claude omits them, Tokenotch shows **Not reported**, not zero.
Reset times that have passed wait for another report; idle readings become
stale after five minutes. Current context includes input and cache tokens, not
cumulative token usage. A compacted/uninitialized window remains unavailable.
**Turn off quota & context** removes its owned status line while keeping numeric
usage connected. This path has synthetic checks, not real-client certification.

For sessions to disappear when they close, choose **Enable session tracking**
under the Claude connection, then restart or resume CLI sessions. This separately
adds `SessionStart` and `SessionEnd` hooks while preserving existing hooks.
Observed open sessions stay visible while idle; end events remove only the
matching session, preserving usage totals. Finishing a response is not a close.
Force-quitting Claude or missing hooks can prevent end delivery. Without tracking,
sessions age out after five minutes without a usage/context report.

Receiver errors and edited owned settings stop only Claude collection. Use
**Retry receiver** for a transient port conflict, or review setup after an
interrupted settings write. **Disconnect** removes only unchanged owned entries.
Edited entries survive with a cleanup warning; finish cleanup in the same
explicitly selected root, without deleting unrelated settings. Restart Claude
after removal. Copilot and retained history are unaffected.

Recording usage history and numeric session timelines require separate Claude
consent. Deleting Claude usage also deletes its reported cost aggregates and
usage receipts, not saved session timelines. Timeline deletion is separately
named and confirmed. Neither operation changes another provider or recording
consent. Hiding the notch cell does not disconnect collection.

## Account sign-in

The CLI browser flow returns to `http://127.0.0.1:<port>/callback`; this temporary
local address is expected, not a Tokenotch website. Keep Tokenotch open until sign-in
finishes. Never share the complete callback URL: it contains temporary OAuth
credentials. If the callback cannot connect, start a new sign-in from Tokenotch
rather than reusing an old callback URL.

If the browser reports success but Tokenotch still asks you to connect, update and
reopen Tokenotch before signing in again. Earlier builds rejected CLI protocol 3
and disabled loading the saved account during quota refresh. The corrected
build supports protocols 2 and 3 and reuses the isolated account authorization;
an already enabled account connection refreshes on launch. No normal CLI
credentials need to be deleted. If refresh still fails, share only Tokenotch's
status message, not the callback URL or account profile.

## Recovery

Tokenotch opens its existing `~/.tokenotch` data and
`io.github.rottathiago.tokenotch` preferences directly. It does not import other
applications' data or settings. Preserve backups when troubleshooting; do not
reset saved data to bypass a startup error.

- If preferences cannot be decoded, Tokenotch does not overwrite them. General
  offers a reset with a recovery copy; restart afterward to retry storage.
- If an archive is corrupt or newer than the running version, preserve it.
  Do not replace it with an empty database or downgrade into it.
- If another copy is running, quit it before starting a second copy. The
  application launch lock and local bridge lock prevent competing instances.
- If launch-at-login needs approval, General links to Login Items in System
  Settings and does not label the item enabled prematurely.
- Account Disconnect stops polling and clears the displayed identity; it does
  not revoke CLI-managed credentials. The production account profile is isolated
  in `~/.tokenotch/copilot-account`. To remove it, first disconnect and quit Tokenotch,
  then use an appropriate supported CLI logout flow scoped to that profile or
  explicitly remove that isolated profile only. Do not delete your normal CLI home.
- Preview the redacted diagnostic report in Privacy before sharing it. Never
  attach transcripts, credentials, raw telemetry, or private configuration.

## Updating and uninstalling

Updates are manual. Quit Tokenotch before replacing the application. Reopen it and
follow any Connections repair/reload instructions. For unsigned downloads, follow
the per-app approval guidance above; do not disable Gatekeeper or remove quarantine.
A failed update check is not a claim that the installed build is current.
If Tokenotch reports that no public stable release is available, the repository may
still be private or its release may still be a draft. Account sign-in does not
grant the updater access to private releases; no repository token is required or
accepted for updating.

To uninstall:

1. Disconnect each client in Connections. Finish pending cleanup using the
   original VS Code profile. Tokenotch removes only exact-owned settings/hooks.
2. Turn off Open Tokenotch at Login. Delete saved usage history, timelines, and
   notices separately if you do not want to retain them.
3. Disconnect the quota account; remove its isolated credentials separately if
   desired. Quit Tokenotch.
4. Remove Tokenotch.app from Applications. The sideloaded VS Code companion can be
   removed in the editor after its owned settings have been cleaned up.
5. If you explicitly want to remove all remaining Tokenotch data, remove only the
   inspected `~/.tokenotch` directory and its production preferences domain
   `io.github.rottathiago.tokenotch`. `~/.tokenotch-launch.lock` is an inert lock file
   while Tokenotch is closed.

Deleting an app does not delete archives, backups, CLI-managed credentials,
macOS notification history, or application preferences. Logical deletion is not
forensic erasure. Never remove unrelated hooks, editor settings, or credential
directories to troubleshoot Tokenotch.

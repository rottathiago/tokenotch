# Setup, recovery, and uninstall

## Connections

First-run onboarding includes the client-specific guides directly. Choose Copilot
CLI or Visual Studio Code and successfully configure at least one before finishing.
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
follow any Connections repair/reload instructions. Do not use Gatekeeper
bypasses. A failed update check is not a claim that the installed build is current.
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

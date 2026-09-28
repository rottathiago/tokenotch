# Tokenotch local VS Code companion

An inert-until-invoked, public-API setup and diagnostics extension for **local macOS VS Code 1.138.0 or newer**. Extension ID: `rottathiago.tokenotch-vscode`; extension kind: `ui`. Runtime: CommonJS and built-in Node modules only. No private Copilot APIs, network requests, receiver probes, model inference, environment changes, telemetry of its own, or automatic configuration on activation.

## Build and package

From the repository root, with Node 22.12+ and npm:

```sh
cd integrations/VSCode
npm ci --ignore-scripts --no-audit --no-fund --cache node_modules/.npm-cache
npm test
npm run package
npm run package:contents
```

The pinned development-only packager and lockfile produce **`integrations/VSCode/TokenotchVSCode.vsix`**, ready for the native bundler to copy to **`Contents/Resources/TokenotchVSCode.vsix`**. The package script is exactly:

```sh
vsce package --no-dependencies --out TokenotchVSCode.vsix
```

The VSIX includes `package.json`, this README, the MIT license, `icon.png`, and the
`src/*.cjs` modules, including generated production identity metadata. The icon
is generated from the project's app icon artwork with `python3 scripts/make-brand-assets.py`
at the repository root. It excludes tests, dependency packages, the lockfile, and
build artifacts. No publishing or installation is part of these commands. The
VSIX is locally packaged and included inside Tokenotch's signed distribution; no
marketplace registration or separate VSIX-signature claim is implied.

Tests use `node:test`, fake public VS Code APIs, and disposable owner-only fixture directories inside `test/`. They do not use the real home directory or VS Code settings.

## Public interface

| Command palette title | Command ID | Behavior |
| --- | --- | --- |
| Tokenotch: Configure local integration | `tokenotch.configureLocalIntegration` | Approve the pending private `configure` request |
| Tokenotch: Remove owned configuration | `tokenotch.removeOwnedConfiguration` | Approve the pending private `remove` request |
| Tokenotch: Check integration | `tokenotch.checkIntegration` | Read-only public effective configuration diagnostics |

Commands accept **no arguments**. Feature selection and destinations come only from the private app request, never command arguments. Both mutating commands require a fresh request created by Tokenotch, even for removal.

Public URIs (the native coordinator retains the selected app's scheme):

```text
vscode://rottathiago.tokenotch-vscode/setup?nonce=<64-lowercase-hex-nonce>
vscode-insiders://rottathiago.tokenotch-vscode/setup?nonce=<64-lowercase-hex-nonce>
```

Only `/setup`, the exact extension authority, and exactly one `nonce` query parameter are accepted. The scheme must be `vscode` or `vscode-insiders` and exactly match the receiving window's public `vscode.env.uriScheme`. The nonce must match the private request. Tokens, endpoints, and other query parameters are rejected. This URI dispatches either operation according to that request. A link landing in the wrong profile cannot authorize reuse of another profile's receipt.

Remote SSH, WSL, containers, Codespaces, and other `vscode.env.remoteName` windows are rejected before accessing private storage; non-macOS hosts are also rejected. Workspace Trust is required, and virtual workspaces are unsupported.

## Native app contract

The native app owns `~/.tokenotch`, an owned, non-symlink directory with **0700** permissions. It creates `vscode-setup-request.json`, an owned regular file with **0600** permissions, one hard link, no symlink, and at most **16 KiB**:

```text
{
  version: 1,
  nonce: string containing exactly 64 lowercase hexadecimal characters,
  expiresAt: integer Unix seconds,
  operation: "configure" | "remove",
  hooks: boolean,
  metrics: boolean,
  endpoints?: {
    vscodeLocal: "http://127.0.0.1:PORT/64hextoken/vscodeLocal",
    vscodeCopilot: "http://127.0.0.1:PORT/64hextoken/vscodeCopilot"
  }
}
```

`endpoints` is required only for `configure` requests with `metrics=true`. Removal may omit endpoints, including when metrics is true and the receiver was never configured: the validated ownership receipt is authoritative for removal. Whenever endpoints are provided, they are still validated. Ports must be 1-65535 without leading zeroes. Both destinations must have the same port and lowercase 64-hex token, the exact corresponding source path, and no extra URL material. Unknown request properties are rejected.

`expiresAt` must be strictly in the future and at most ten minutes ahead. File modification time must be within the previous ten minutes (at most five seconds ahead for clock skew). Request freshness and the configuration preflight are checked again after consent. The app should atomically write a fresh request and use a new nonce for every operation; it must not replace a request while its consent dialog is open.

The companion presents a modal, token-free summary before any settings changes. Cancelling writes `cancelled`, makes no setting changes, and leaves the request unconsumed until it expires or the app withdraws it. Invalid or conflicting requests are not consumed. A matching approved request is atomically renamed out of the pending name, verified against its original inode and content fingerprint, then deleted **before** applying settings. Reopening the same URI without a new request cannot replay it.

### Private result

`vscode-setup-result.json` is an atomic, owner-only, bounded JSON file:

```text
{
  version: 1,
  nonce: the validated request nonce,
  operation: "configure" | "remove",
  status: "configured" | "removed" | "cancelled" | "blocked" | "failed",
  message: one fixed string from src/contract.cjs MESSAGES
}
```

Messages never contain paths, endpoints, tokens, headers, environment values, or raw errors. Results are written for validated matching requests, including cancellation, expiration, conflicts, and partial failures. When no trustworthy request/nonce is available, in remote windows, or when private storage is unsafe, there is no result write; a generic VS Code error is shown instead. Failure to persist a result is explicitly shown, never reported as success.

The native app can watch `vscode-settings.receipt.json` to update ownership UI and reads the result's `status` for the operation outcome; it does not need to parse `message`. **A receipt is a recovery journal, not evidence of successful telemetry delivery or even a completed installation.**

## Settings and consent boundaries

Settings use only the public `workspace.getConfiguration().inspect/get/update` APIs. Updates always use `ConfigurationTarget.Global` for the selected window's user profile; no JSONC file is opened or rewritten. Installation/profile ownership uses public extension context and environment metadata, not profile enumeration or private APIs.

Hooks merge only `'~/.tokenotch/vscode-hooks': true` into `chat.hookFilesLocations`, preserving other global entries. The app, not this extension, installs and maintains:

- `~/.tokenotch/TokenotchHook`
- `~/.tokenotch/vscode-hooks/tokenotch-v1.json` (`SessionStart`, `UserPromptSubmit`, `Stop`)

The companion reports the hook setting, not the executability or successful delivery of those native hooks.

These lifecycle hooks target VS Code's **Local** harness. Copilot sessions on
Agent Host use a distinct SDK hook implementation; configuring Agent Host usage
below does not establish lifecycle or attention coverage for those sessions.

| Source | Settings |
| --- | --- |
| Local | `github.copilot.chat.otel.enabled=true`, `.exporterType="otlp-http"`, `.protocol="http/json"`, `.otlpEndpoint=endpoints.vscodeLocal`, `.captureContent=false` |
| Agent Host | `chat.agentHost.otel.enabled=true`, `.exporterType="otlp-http"`, `.otlpEndpoint=endpoints.vscodeCopilot`, `.captureContent=false` |

Destinations, exporter settings, and content controls are staged before either source is enabled. Removal restores enablement first. The unsupported/ignored `chat.agentHost.otel.otlpProtocol` setting is never set. Authentication is the opaque endpoint path. Existing headers are never read, added, changed, or included in a receipt. DB/file capture is never enabled.

Local Chat appends `/v1/traces` to its configured base URL. Agent Host can instead treat its configured non-root URL as the complete destination for both traces and metrics. Tokenotch accepts the exact authenticated `/<token>/vscodeCopilot` path as well as the conventional `/<token>/<source>/v1/{traces,metrics,logs}` routes. The direct endpoint requires a single OTLP JSON signal envelope; metrics and logs are acknowledged without counting them as model calls. Both forms use the same token, source validation, JSON-only admission and per-call deduplication. Older native receivers returned HTTP 401 for the valid direct Agent Host path; updating/restarting Tokenotch fixes that case without changing the companion settings.

The JavaScript OTel exporter uses streamed HTTP requests. The native receiver supports either `Content-Length` or a single `Transfer-Encoding: chunked`, never both. Chunked requests retain the 4 MiB decoded-body limit, total wire-size and connection-time limits, and a maximum of 2,048 data chunks. Compression, trailers, chunk extensions, ambiguous framing and unauthenticated paths remain unsupported. A fixed-length Agent Host stream can work even when an older receiver rejects JavaScript-exported traces or metrics as unsupported.

All required keys must exist in the public schema as exposed by `inspect`. Setup refuses telemetry-off preferences, conflicting explicit exporters/protocols/endpoints, active external/default collectors, content capture, supported outfile/file/DB capture settings, conflicting workspace/folder/language overrides, and nonempty process environment overrides beginning with `OTEL_`, `COPILOT_OTEL_`, `GITHUB_COPILOT_OTEL_`, `VSCODE_OTEL_`, or `VSCODE_AGENT_HOST_OTEL_`. The exact discard-only SDK marker is the sole environment exception; see [OTel environment overrides](#otel-environment-overrides).

Unmodified app-owned endpoints can be rotated from a new private request; preexisting external collectors cannot be silently adopted or replaced. Public settings are re-read after updates, including every open workspace folder. Policy information not exposed by public APIs, child-process environment, and actual starter runtime state cannot be discovered reliably. A non-overridable value found after a write is reported as blocked, with the partial changes retained in the recovery journal rather than claimed configured.

## Ownership, removal, and failure recovery

The bounded 0600 receipt has this versioned shape:

```text
{
  version: 1,
  owner: {
    id: <64-hex random identity from this profile's extension globalState>,
    scope: <64-hex fingerprint of the installation and public storage location>
  },
  settings: {
    "<allowlisted OTel key>": {
      previous: { present: false } | { present: true, value: <safe primitive> },
      installed: [<installed primitive or { sha256: <endpoint fingerprint> }>]
    }
  },
  hook?: { previous: { present: false } | { present: true, value: false }, installed: true }
}
```

Only the nine listed OTel keys and the single hook entry are accepted. Full settings maps, unrelated entries, raw endpoint tokens, and headers are never stored. Prior endpoints can only be unset or empty: external destinations are refused before installation. Prior boolean values can only be false; a receipt cannot authorize enabling content capture. An already-true hook entry is **not** adopted.

Every nonempty receipt requires `owner`. After approval, the companion persists a random identity under `tokenotch.receiptIdentity.v1` in the public, per-profile `ExtensionContext.globalState`; it does not register that key for Settings Sync. The receipt stores that identity and a SHA-256 fingerprint of `vscode.env.uriScheme`, `vscode.env.appRoot`, and the public `ExtensionContext.globalStorageUri`. Both local `file:` and VS Code's `vscode-userdata:` storage URIs are supported. The exact URI, including its scheme, remains part of the fingerprint; it is never converted to a filesystem path or used to read profile files. Existing `file:` fingerprints are unchanged. Names and storage/application paths are not written into receipts, results, or messages.

Both identity fields must match before setup, removal, or interpreting the receipt in diagnostics. Ownership is checked again after consent and around awaited configuration/journal writes. Matching settings values alone never establish profile ownership. Another profile, a different installation, a different storage location, a copied marker with a different scope, missing/corrupt extension state, or unavailable public identity metadata blocks the action with a fixed actionable message. It does not overwrite the receipt or edit that window's settings. No profile enumeration, other-profile settings access, or automatic identity adoption is attempted.

**Legacy nonempty receipts without an owner are deliberately refused.** Restore a matching profile-bound receipt and its original extension state, or manually resolve the original integration before resetting an unbound receipt. Do not invent a new owner for old settings. Moving an installation/user-data directory or deleting its extension state can likewise require returning to the original scope or manual recovery. The proof is scoped to public local extension state; it is not authentication against a same-user process that clones or tampers with all of that state.

Partial installation and partial removal retain the owner. Once no owned fields remain, the receipt is atomically saved as `{ "version": 1, "settings": {} }` without an owner, allowing a later explicitly approved request to pair another profile. This also safely accepts an existing empty legacy receipt. Only one nonempty installation/profile receipt can own the shared native integration at a time. The app request and result schemas are unchanged.

Each change is journaled before the configuration update. Receipt writes use a no-follow/create-exclusive 0600 temporary file, file sync, atomic rename, and directory sync. During endpoint rotation, the journal temporarily accepts both old and new endpoint fingerprints, so a crash on either side of the settings write remains reversible. Removal restores only still-matching installed values, preserves user edits, and drops an entry from the durable receipt only after restoration. Hook removal edits only the owned dictionary member; an emptied map remains `{}`.

The removal flags choose the subset: `hooks=false, metrics=true` disables owned metrics while retaining hooks; `hooks=true, metrics=false` removes owned hooks while retaining metrics. Removal does not require telemetry to be enabled or external conflicts to be cleared. A new approved removal request can undo a partially completed installation. A malformed or unsafe receipt is refused rather than trusted.

`vscode-setup.lock` serializes cooperating companion windows. It is an exclusive 0600 file containing only a version and PID, held through consent and result persistence. An interrupted process can leave a stale lock: after confirming all setup dialogs and the recorded process are gone, use the native app or manually remove **only that lock file**, then create a fresh request. Never delete the ownership receipt to work around a failure. The companion deliberately does not guess at stale-lock ownership or reclaim a live lock.

The private directory and the native coordinator share the current OS user's trust boundary. No-follow/inode/ownership checks reject symlinked ancestors, unsafe files, and observed path replacements. Node and VS Code expose neither descriptor-relative filesystem transactions nor compare-and-swap settings writes; these checks do not claim protection from a malicious process running as the same OS user. Unrelated hook edits are merged from the latest global map immediately before each update.

## Diagnostics and reload

Tokenotch shows one **Visual Studio Code** connection with separate **Activity** and **Model & token usage** statuses. Choose **Set up VS Code...** (or **Manage connection...**) to enter the guided flow. Activity is included; **Include model & token usage** is optional and off by default for new connections. Existing usage consent is preserved; use **Options > Turn off model & token usage...** to withdraw it.

The **Install setup extension...** application picker expects **Visual Studio Code.app**, or **Visual Studio Code - Insiders.app** for Insiders, not Tokenotch itself. The extension is needed to request consent and change settings through public VS Code APIs. Installing it alone does not enable collection. Reload that editor, choose **I've reloaded; continue**, approve the settings in VS Code, then reload again and send a prompt to verify delivery. If Tokenotch previously installed the companion, the flow proceeds to approval without reinstalling it; **Options > Update setup extension...** remains available for repair.

Closing the guide preserves the selected capabilities for the current app session. **Continue setup...** resumes an installation or outstanding approval. **Open approval** reuses the same private request instead of replacing a request while its consent dialog may be open. Approvals are remembered for presentation, not treated as proof of current effective settings or delivery. Actual observations take precedence, including for integrations configured by an earlier app version.

Earlier development companions incorrectly rejected valid `vscode-userdata:` storage URIs with an installation/profile identity error, even in a new local profile. Update to the companion bundled with Tokenotch and reload the window before retrying. Do not reset extension state or delete an ownership receipt to work around that error.

### OTel environment overrides

The bundled companion shows the triggering **variable names**, never their values, in the setup error dialog and **Tokenotch: Check integration** diagnostics. The guard remains conservative: nonempty variables with one of the OTel prefixes listed above block metrics, including a value such as `false`, except for the narrowly matched SDK/settings cases below. A detected variable is not proof that an external collector is running. Empty and unset variables do not block setup.

**The bundled companion accepts `COPILOT_OTEL_FILE_EXPORTER_PATH` only when its value is exactly `/dev/null` on the supported macOS host.** VS Code's [embedded Copilot SDK initialization](https://github.com/microsoft/vscode/blob/fdcbb6d8e610d0ed53d41f278c84b7559209a80d/extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSessionService.ts#L198-L220) sets this discard-only marker internally when external OTel export is not enabled. The extension host is shared, so Tokenotch can see it even when no shell or launcher override exists. VS Code's [OTel resolver snapshots its inputs before later SDK mutations](https://github.com/microsoft/vscode/blob/fdcbb6d8e610d0ed53d41f278c84b7559209a80d/extensions/copilot/src/platform/otel/common/otelConfigResolution.ts#L55-L69).

Only that exact variable/value pair is exempted; real output paths, path variants, explicit file-output settings, other environment overrides, content capture and telemetry-off preferences remain guarded. Tokenotch does not remove or rewrite the marker. Consent and diagnostics explain that a discard-only setting is present without exposing its value. Public APIs cannot prove whether it was created internally or inherited; an inherited marker may still suppress delivery. Reload after approved setup and verify actual usage in Tokenotch rather than treating configuration as a working connection. If an older companion shows this variable as the sole blocker, update the setup extension before editing your environment.

**The bundled companion also recognizes settings-derived variables when retrying setup after Tokenotch has enabled `github.copilot.chat.otel.enabled`.** Once that setting is explicitly enabled, VS Code's built-in Copilot Chat extension copies its own settings into the shared extension host as `COPILOT_OTEL_ENABLED=true`, `OTEL_EXPORTER_OTLP_ENDPOINT=<normalized github.copilot.chat.otel.otlpEndpoint>` and `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false`. These three variables are exempted only while that setting is `true` and each value exactly matches what Copilot derives from the current settings; any other value, including an external endpoint, `1` or content capture `true`, is still reported. If an older companion lists exactly these three names after a previous setup, update the setup extension instead of editing your environment.

Review the names in the affected VS Code window, not just a terminal: the extension host can have a different environment. Remove unneeded overrides at their source, such as a shell startup file, launcher, or managed environment. **Fully quit VS Code with Cmd+Q and reopen it from the corrected environment**, then retry setup under **Connections > Visual Studio Code** in Tokenotch. Reload Window or running `unset` in an existing integrated terminal cannot clear the parent application's inherited environment.

If the overrides are intentional or managed, leave model & token usage unchecked rather than disrupting an existing collector. Activity-only setup still works without metrics, and owned settings can still be removed with overrides present. If usage was already requested, turn it off through the connection's **Options** menu first. Tokenotch never edits the environment automatically.

Variable names are shown only in the interactive dialog, not added to the private result or ownership receipt. Nonstandard names are hidden and long lists are explicitly truncated; environment values, endpoints, headers, and raw errors remain excluded.

### Delivery status

Diagnostics are source-specific: unsupported, blocked, not configured, or **effective configured; reload may be needed; awaiting actual data**. They do not open connections, issue prompts to models, or claim live metrics from settings alone. Actual source delivery and successful native hook execution must be verified by the Tokenotch receiver/app.

After successful metrics configuration or removal, VS Code offers an optional **Reload Window** action. Only selecting it invokes the public reload command. There is no forced reload/restart. A settings match cannot prove whether an already-running telemetry starter has reloaded, so diagnostics retain that qualification.

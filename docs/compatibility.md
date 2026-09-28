# Supported capability and acceptance matrix

The implementation targets macOS 15+, arm64 and x86_64. A universal build
proves that both slices compile; it does not prove live Intel or OS behavior.
**No public 1.0.0 support certification is claimed until the acceptance record
is approved for the exact source revision and artifact.**

| Capability | Contract | Required behavior |
| --- | --- | --- |
| CLI lifecycle | Documented client hooks | Start/work/stop must deliver for release acceptance; stop is not success. |
| CLI numeric metrics | Extension SDK usage events, accounting contract 1 | Unsupported fields/versions stay unavailable; do not block valid lifecycle observations. |
| CLI active-work snapshots | Experimental `metadata.activity()` RPC | Optional Preview, bounded single outstanding read, explicit stale/failure behavior. |
| CLI context snapshots | Experimental `metadata.getContextAttribution()` RPC and root model/conversation events | Optional Preview; resolved-model, nonempty-conversation fallback only until authoritative usage arrives. Stop/idle must preserve reported usage. Reset/model-change invalidation, bounded reads and stale/unavailable disclosure; event-only context works without the RPC. |
| CLI context/latency/compaction/requests | Optional documented signals | Only reported observations; no inference from inactivity, tokens, or ordinary text. |
| Account quota | Official CLI, stdio protocols 2 and 3 | Unknown protocols rejected before auth/quota RPCs; missing quota remains unavailable. Headless polling reuses the explicitly signed-in account without initiating browser login. |
| VS Code lifecycle | Local harness Preview hooks | Local activity required; Agent Host lifecycle parity is not claimed; no invented error/approval semantics. |
| VS Code Local usage | Public configuration and allowlisted OTel spans | Separate usage consent and actual delivered call required. |
| VS Code Agent Host usage | Separate public OTel settings | Separate producer attribution; parent spans and terminal CLI calls excluded. |
| VS Code companion | VS Code 1.138.0+ manifest target | Public APIs, local trusted window, selected installation/profile; target is not blanket future-version certification. |

Copilot CLI releases with the expected published contracts are candidates, not
automatically accepted clients. Record the exact CLI version, VS Code version,
Copilot extension version, macOS version, architecture, and observed capabilities
for each accepted combination. The signed-in quota account is not assumed to
match either local client.

Before publishing, fill the external acceptance record described in
[releasing](releasing.md). Both local clients, native Apple Silicon and native
Intel, minimum macOS, advertised newer OS versions, upgrade/recovery, permissions,
keyboard/VoiceOver, real multi-display/full-screen behavior, and performance
must pass. Optional Preview capabilities may be explicitly unavailable; neither
a required client nor an architecture can silently be removed from the release.

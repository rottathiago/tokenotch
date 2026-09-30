# Cross-platform behavior fixtures

`fixtures/hooks.json` contains synthetic raw inputs and expected normalized
fields for the existing Swift helper and the new Windows Rust core. It includes
an injected clock and content-stripping sentinels; it contains no real sessions,
credentials or prompts.

Each case must contain exactly one outcome: `expected`, `error`, or `filtered`.
Expected objects compare selected fields recursively. Both adapters additionally
verify the hashed synthetic session identity and reject raw IDs/content in output.
The Rust adapter also checks usage-call identity.

`timestampUnixMs` is a canonical fixture field, not a change to the existing
macOS socket wire format. Swift's default Codable `Date` representation is not
Unix time; the Swift adapter converts it explicitly before comparison.

Run `make smoke-contracts` on macOS or `WindowsContractTests` through XCTest.
Run `cargo test -p tokenotch-core --locked` from `windows/` for Rust.

The initial corpus covers CLI lifecycle, usage/cache accounting, context,
compaction, attention, filtering and Local VS Code hook normalization.
`fixtures/live-state.json` additionally compares selected activity ordering,
freshness boundaries, call deduplication, context invalidation and retention
transitions through both implementations. The shared checks use the same injected
clock and compare counts, labels and exact totals, not timing sleeps.

Source-aware OTel has separate Rust coverage, while shared OTel, notice/history
storage and native IPC still require additional fixtures and real platform
tests before full parity is claimed.

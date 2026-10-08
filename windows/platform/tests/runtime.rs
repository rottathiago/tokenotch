use serde_json::json;
use std::{fs, path::PathBuf};
use tokenotch_core::hook::{self, EventKind, Source};
use tokenotch_platform::{
    archive::Archive,
    attention::Attention,
    connections::Connections,
    preferences::Preferences,
    runtime::Runtime,
    storage::{random_id, Store},
    transport::{now_ms, Envelope},
};

struct Fixture {
    root: PathBuf,
    store: Store,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("tokenotch-test-{}", random_id().unwrap()));
        let store = Store::open(root.clone()).unwrap();
        Self { root, store }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}
fn event(kind: &str, at: f64) -> hook::Observation {
    let value = json!({"sessionId":"synthetic-session","timestamp":at,"eventId":"synthetic-call","usageContract":1,
        "inputTokens":100,"outputTokens":20,"cacheReadTokens":30,"cacheReadTokensReported":true,
        "cacheWriteTokens":10,"cacheWriteTokensReported":true,"model":"fixture-model",
        "stopReason":"end_turn","active":true,"prompt":"NEVER SAVE THIS CONTENT"});
    hook::normalize(&serde_json::to_vec(&value).unwrap(), Source::Cli, kind, at)
        .unwrap()
        .unwrap()
}

fn import_preview(f: &Fixture, count: usize) -> tokenotch_platform::import::Preview {
    let at = now_ms() - 86_400_000.0;
    let spans: Vec<_> = (0..count)
        .map(|index| {
            json!({
                "traceId": format!("{:032x}", index + 1),
                "spanId": format!("{:016x}", index + 1),
                "startTimeUnixNano": format!("{:.0}", (at + index as f64) * 1_000_000.0),
                "endTimeUnixNano": format!("{:.0}", (at + index as f64 + 1.0) * 1_000_000.0),
                "attributes": [
                    {"key":"gen_ai.operation.name","value":{"stringValue":"chat"}},
                    {"key":"gen_ai.provider.name","value":{"stringValue":"github"}},
                    {"key":"gen_ai.usage.input_tokens","value":{"intValue":"100"}},
                    {"key":"gen_ai.usage.output_tokens","value":{"intValue":"20"}}
                ]
            })
        })
        .collect();
    let path = f.store.path("import.json").unwrap();
    fs::write(
        &path,
        serde_json::to_vec(&json!({"resourceSpans":[{
            "resource":{"attributes":[{"key":"service.name","value":{"stringValue":"copilot-chat"}}]},
            "scopeSpans":[{"spans":spans}]
        }]}))
        .unwrap(),
    )
    .unwrap();
    let preview = tokenotch_platform::import::preview(path).unwrap();
    assert_eq!(preview.events.len(), count);
    preview
}

#[test]
fn archive_batches_roll_back_on_error_and_deduplicate_after_restart() {
    let f = Fixture::new();
    let preview = import_preview(&f, 130);
    let prefs = Preferences {
        timelines: true,
        ..Preferences::default()
    };
    let mut archive = Archive::open(&f.store).unwrap();
    let day = archive.today(preview.events[0].timestamp_unix_ms).unwrap();
    let mut invalid = preview.events[1].clone();
    invalid.version = 0;
    assert!(archive
        .record_batch(&[preview.events[0].clone(), invalid], &prefs, true)
        .is_err());
    assert_eq!(archive.history_revision(), 0);
    assert!(archive.history(&day, &day).unwrap().days.is_empty());
    assert_eq!(
        archive.record_batch(&preview.events, &prefs, true).unwrap(),
        130
    );
    assert_eq!(archive.history_revision(), 130);
    assert!(archive.timeline(None).unwrap().is_empty());
    drop(archive);
    let mut archive = Archive::open(&f.store).unwrap();
    assert_eq!(
        archive.record_batch(&preview.events, &prefs, true).unwrap(),
        0
    );
    let saved = archive.history(&day, &day).unwrap();
    assert_eq!(
        saved.days.iter().map(|row| row.usage.calls).sum::<u64>(),
        130
    );
    assert_eq!(
        saved.days.iter().map(|row| row.usage.input).sum::<u64>(),
        13_000
    );
    assert!(saved.coverage.is_empty());
    assert!(!saved.source_gaps.is_empty());
}

#[tokio::test]
async fn imports_release_runtime_for_live_delivery_within_hook_deadline() {
    import_with_live_delivery(4096).await;
}

#[tokio::test]
#[ignore = "Exercises the 100,000-span limit with concurrent live delivery"]
async fn maximum_size_import_keeps_live_delivery_within_hook_deadline() {
    import_with_live_delivery(100_000).await;
}

async fn import_with_live_delivery(count: usize) {
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};
    use tokenotch_platform::runtime::commit_import;

    let f = Fixture::new();
    let preview = import_preview(&f, count);
    let day_at = preview.events[0].timestamp_unix_ms;
    let fingerprint = preview.fingerprint.clone();
    let mut state = Runtime::open(f.store.clone()).unwrap();
    state.connections.cli_home = f.root.join("client");
    state.pending_import = Some(preview);
    f.store.write("cli.registration", b"registration").unwrap();
    let shared = Arc::new(Mutex::new(state));
    let importing = tokio::spawn(commit_import(shared.clone(), fingerprint));
    let mut delivered = 0;
    let mut interleaved = false;
    let mut longest = Duration::ZERO;
    while !importing.is_finished() {
        let began = Instant::now();
        tokio::time::sleep(Duration::from_millis(5)).await;
        let state = shared.clone();
        let progress = tokio::task::spawn_blocking(move || {
            let mut state = state.lock().unwrap();
            let progress = state.archive.as_ref().unwrap().history_revision();
            let mut usage = event("usage", now_ms());
            usage.tokens.as_mut().unwrap().call_id = hook::digest(&format!("live-{delivered}"));
            state
                .accept(Envelope {
                    registration: "registration".into(),
                    event: usage,
                })
                .unwrap();
            progress
        })
        .await
        .unwrap();
        longest = longest.max(began.elapsed());
        interleaved |= progress > delivered && progress < count as u64 + delivered;
        delivered += 1;
    }
    assert_eq!(importing.await.unwrap().unwrap(), count);
    assert!(
        interleaved,
        "live events must be admitted before import completes"
    );
    assert!(
        longest < Duration::from_millis(900),
        "live delivery stalled for {longest:?}"
    );
    eprintln!("Imported {count} calls with {delivered} live deliveries; longest wait: {longest:?}");
    let mut state = shared.lock().unwrap();
    let archive = state.archive.as_ref().unwrap();
    let first = archive.today(day_at).unwrap();
    let last = archive.today(now_ms()).unwrap();
    let history = state.history(&first, &last).unwrap();
    assert_eq!(
        history.days.iter().map(|row| row.usage.calls).sum::<u64>(),
        count as u64 + delivered
    );
    assert_eq!(state.tokens.sample_count(), (delivered as usize).min(4096));
}

#[tokio::test]
async fn pausing_or_clearing_history_cancels_remaining_import_batches() {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tokenotch_platform::runtime::commit_import;

    for clear in [false, true] {
        let f = Fixture::new();
        let preview = import_preview(&f, 2048);
        let at = preview.events[0].timestamp_unix_ms;
        let fingerprint = preview.fingerprint.clone();
        let mut state = Runtime::open(f.store.clone()).unwrap();
        state.connections.cli_home = f.root.join("client");
        state.pending_import = Some(preview);
        let shared = Arc::new(Mutex::new(state));
        let importing = tokio::spawn(commit_import(shared.clone(), fingerprint));
        let saved = loop {
            tokio::time::sleep(Duration::from_millis(1)).await;
            let mut state = shared.lock().unwrap();
            let saved = state.archive.as_ref().unwrap().history_revision();
            if saved == 0 {
                assert!(!importing.is_finished());
                continue;
            }
            assert!(saved < 2048);
            if clear {
                state.clear("history").unwrap();
            } else {
                let mut prefs = state.preferences.clone();
                prefs.history = false;
                state.preferences(prefs.clone()).unwrap();
                prefs.history = true;
                state.preferences(prefs).unwrap();
            }
            break saved;
        };
        let error = importing.await.unwrap().unwrap_err();
        assert!(error.contains("paused or cleared"), "{error}");
        let mut state = shared.lock().unwrap();
        let day = state.archive.as_ref().unwrap().today(at).unwrap();
        let history = state.history(&day, &day).unwrap();
        let calls = history.days.iter().map(|row| row.usage.calls).sum::<u64>();
        assert_eq!(calls, if clear { 0 } else { saved });
        assert!(state.preferences.history);
    }
}

#[tokio::test]
async fn imports_recheck_approval_and_file_before_writing() {
    use std::sync::{Arc, Mutex};
    use tokenotch_platform::runtime::commit_import;

    let f = Fixture::new();
    let shared = Arc::new(Mutex::new(Runtime::open(f.store.clone()).unwrap()));
    for changed in [false, true] {
        let preview = import_preview(&f, 1);
        let fingerprint = preview.fingerprint.clone();
        if changed {
            fs::write(&preview.path, b"changed after preview").unwrap();
        }
        shared.lock().unwrap().pending_import = Some(preview);
        let error = commit_import(
            shared.clone(),
            if changed { fingerprint } else { "wrong".into() },
        )
        .await
        .unwrap_err();
        assert!(
            error.contains(if changed {
                "export changed"
            } else {
                "approval does not match"
            }),
            "{error}"
        );
        let state = shared.lock().unwrap();
        assert_eq!(state.archive.as_ref().unwrap().history_revision(), 0);
        assert!(state.preferences.history);
    }
}

#[test]
fn private_files_round_trip_and_reject_traversal() {
    let f = Fixture::new();
    f.store
        .save("settings.json", &json!({"enabled":false}))
        .unwrap();
    assert_eq!(
        f.store
            .load::<serde_json::Value>("settings.json")
            .unwrap()
            .unwrap()["enabled"],
        false
    );
    f.store
        .save("settings.json", &json!({"enabled":true}))
        .unwrap();
    assert!(f.store.path("..\\secret").is_err());
    assert!(f.store.path("file:stream").is_err());
    assert!(f.store.path("../secret").is_err());
    assert!(f.store.read("settings.json", 1).is_err());
    f.store.remove("settings.json").unwrap();
    assert!(f.store.read("settings.json", 1024).unwrap().is_none());
}

#[test]
fn owned_cli_setup_preserves_edits_and_withdraws_consent_before_cleanup() {
    let f = Fixture::new();
    let helper = f.root.join("bundled.exe");
    fs::write(&helper, b"MZ fixture").unwrap();
    let connections = Connections {
        store: f.store.clone(),
        cli_home: f.root.join("client"),
    };
    connections.install(Source::Cli, &helper).unwrap();
    assert!(connections.configured(Source::Cli).unwrap());
    let hook = connections.cli_home.join("hooks").join("tokenotch-v1.json");
    let original = fs::read(&hook).unwrap();
    fs::write(&hook, b"user edit").unwrap();
    assert!(connections.install(Source::Cli, &helper).is_err());
    assert!(connections.remove(Source::Cli).is_err());
    assert_eq!(fs::read(&hook).unwrap(), b"user edit");
    assert!(f.store.read("cli.registration", 128).unwrap().is_none());
    fs::write(&hook, original).unwrap();
    connections.remove(Source::Cli).unwrap();
    assert!(!hook.exists());
}

#[test]
fn collection_requires_registration_and_records_history_by_default_without_content() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    assert!(runtime.preferences.history);
    runtime.connections.cli_home = f.root.join("client");
    let usage = event("usage", now_ms());
    assert!(runtime
        .accept(Envelope {
            registration: "unknown".into(),
            event: usage.clone()
        })
        .is_err());
    f.store.write("cli.registration", b"registration").unwrap();
    runtime
        .accept(Envelope {
            registration: "registration".into(),
            event: usage.clone(),
        })
        .unwrap();
    runtime
        .accept(Envelope {
            registration: "registration".into(),
            event: usage,
        })
        .unwrap();
    assert_eq!(runtime.tokens.sample_count(), 1);
    drop(runtime);
    let raw = fs::read(f.root.join("usage.sqlite")).unwrap();
    assert!(!raw
        .windows(b"NEVER SAVE THIS CONTENT".len())
        .any(|w| w == b"NEVER SAVE THIS CONTENT"));
    assert!(!f.root.join("notices.json").exists());
}

#[test]
fn saved_usage_bumps_the_history_revision_and_reports_peak_context() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    let start = runtime.change_signature();
    let revision = |runtime: &Runtime| runtime.archive.as_ref().unwrap().history_revision();
    assert_eq!(revision(&runtime), 0);
    let at = now_ms();
    runtime.observe(&event("usage", at), false).unwrap();
    assert_eq!(revision(&runtime), 1);
    assert_ne!(runtime.change_signature(), start);
    runtime.observe(&event("usage", at), false).unwrap();
    assert_eq!(revision(&runtime), 1, "a duplicate call is not new history");
    let context = hook::normalize(
        &serde_json::to_vec(
            &json!({"sessionId":"synthetic-session","timestamp":at + 1.0,
            "eventId":"context-1","currentTokens":45,"tokenLimit":100}),
        )
        .unwrap(),
        Source::Cli,
        "context",
        at + 1.0,
    )
    .unwrap()
    .unwrap();
    runtime.observe(&context, false).unwrap();
    let day = runtime.archive.as_ref().unwrap().today(at).unwrap();
    let history = runtime.history(&day, &day).unwrap();
    let value = serde_json::to_value(&history).unwrap();
    assert_eq!(value["contextPeaks"], json!([[day, 0.45]]));
    let before = revision(&runtime);
    runtime.clear("history").unwrap();
    assert!(revision(&runtime) > before);
}

#[cfg(windows)]
#[test]
fn notice_write_failure_cannot_lose_saved_usage_or_duplicate_it_on_retry() {
    use std::os::windows::fs::OpenOptionsExt;
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.connections.cli_home = f.root.join("client");
    let mut prefs = runtime.preferences.clone();
    prefs.remember_notices = true;
    prefs.timelines = true;
    runtime.preferences(prefs).unwrap();
    let lock = fs::OpenOptions::new()
        .read(true)
        .share_mode(3)
        .open(f.store.path("notices.json").unwrap())
        .unwrap();
    let usage = event("usage", now_ms());
    let error = runtime.observe(&usage, false).unwrap_err();
    assert_eq!(error, "Private file replacement failed.");
    assert_eq!(runtime.notification_error.as_deref(), Some(error.as_str()));
    assert!(runtime.preferences.history);
    assert_eq!(runtime.archive.as_ref().unwrap().history_revision(), 1);
    drop(lock);
    runtime.observe(&usage, false).unwrap();
    let mut next = event("usage", now_ms());
    next.tokens.as_mut().unwrap().call_id = hook::digest("next-call");
    runtime.observe(&next, false).unwrap();
    let live = runtime.tokens.totals(None).unwrap();
    assert_eq!(
        (
            live.calls,
            live.input,
            live.output,
            live.cache_input,
            live.cache_write
        ),
        (2, 120, 40, 60, 20)
    );
    let snapshot = runtime.snapshot().unwrap();
    let days = snapshot["today"]["days"].as_array().unwrap();
    assert_eq!(days.len(), 1);
    assert_eq!(days[0]["usage"]["calls"], 2);
    assert_eq!(days[0]["usage"]["input"], 120);
    assert_eq!(days[0]["usage"]["output"], 40);
    assert_eq!(days[0]["usage"]["cacheInput"], 60);
    assert_eq!(days[0]["usage"]["cacheWrite"], 20);
    assert_eq!(
        runtime
            .archive
            .as_ref()
            .unwrap()
            .timeline(None)
            .unwrap()
            .len(),
        2
    );
    let day = runtime
        .archive
        .as_ref()
        .unwrap()
        .today(usage.timestamp_unix_ms)
        .unwrap();
    drop(runtime);
    let archive = Archive::open(&f.store).unwrap();
    assert_eq!(archive.history(&day, &day).unwrap().days[0].usage.calls, 2);
}

#[test]
fn live_duplicates_still_complete_missing_archive_transactions() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.connections.cli_home = f.root.join("client");
    let usage = event("usage", now_ms());
    runtime.tokens.observe(&usage, now_ms(), false).unwrap();
    assert_eq!(runtime.archive.as_ref().unwrap().history_revision(), 0);
    runtime.observe(&usage, false).unwrap();
    runtime.observe(&usage, false).unwrap();
    assert_eq!(runtime.tokens.sample_count(), 1);
    assert_eq!(runtime.archive.as_ref().unwrap().history_revision(), 1);
    let snapshot = runtime.snapshot().unwrap();
    assert_eq!(snapshot["today"]["days"][0]["usage"]["calls"], 1);
    assert_eq!(snapshot["today"]["days"][0]["usage"]["input"], 60);
}

#[test]
fn delayed_cli_delivery_is_saved_once_at_its_original_time() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.connections.cli_home = f.root.join("client");
    f.store.write("cli.registration", b"registration").unwrap();
    let at = now_ms() - 180_000.0;
    runtime
        .archive
        .as_mut()
        .unwrap()
        .checkpoint(true, &[], at - 1.0, true)
        .unwrap();
    let usage = event("usage", at);
    for _ in 0..2 {
        runtime
            .accept(Envelope {
                registration: "registration".into(),
                event: usage.clone(),
            })
            .unwrap();
    }
    assert_eq!(runtime.tokens.samples().next().unwrap().date, at);
    let day = runtime.archive.as_ref().unwrap().today(at).unwrap();
    let saved = runtime.history(&day, &day).unwrap();
    assert_eq!(saved.days.len(), 1);
    assert_eq!(saved.days[0].usage.calls, 1);
    assert_eq!(saved.days[0].usage.input, 60);
    assert_eq!(saved.days[0].usage.output, 20);
    assert_eq!(saved.days[0].usage.cache_input, 30);
    assert_eq!(saved.days[0].usage.cache_write, 10);
}

#[test]
fn usage_retries_do_not_restore_cleared_history_or_timelines() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.connections.cli_home = f.root.join("client");
    let mut prefs = runtime.preferences.clone();
    prefs.timelines = true;
    runtime.preferences(prefs).unwrap();
    let usage = event("usage", now_ms());
    runtime.observe(&usage, false).unwrap();
    assert_eq!(
        runtime
            .archive
            .as_ref()
            .unwrap()
            .timeline(None)
            .unwrap()
            .len(),
        1
    );
    std::thread::sleep(std::time::Duration::from_millis(2));
    runtime.clear("timelines").unwrap();
    runtime.observe(&usage, false).unwrap();
    assert!(runtime
        .archive
        .as_ref()
        .unwrap()
        .timeline(None)
        .unwrap()
        .is_empty());
    runtime.clear("history").unwrap();
    runtime.observe(&usage, false).unwrap();
    let day = runtime
        .archive
        .as_ref()
        .unwrap()
        .today(usage.timestamp_unix_ms)
        .unwrap();
    assert!(runtime.history(&day, &day).unwrap().days.is_empty());
    assert_eq!(runtime.tokens.sample_count(), 1);
}

#[test]
fn legacy_installs_that_never_recorded_turn_history_on_but_paused_archives_stay_paused() {
    let f = Fixture::new();
    let legacy = Preferences {
        history: false,
        ..Preferences::default()
    };
    f.store.save("preferences.json", &legacy).unwrap();
    let runtime = Runtime::open(f.store.clone()).unwrap();
    assert!(runtime.preferences.history);
    assert!(runtime.archive.is_some());
    let saved: Preferences = f.store.load("preferences.json").unwrap().unwrap();
    assert!(saved.history);
    drop(runtime);

    f.store.save("preferences.json", &legacy).unwrap();
    let runtime = Runtime::open(f.store.clone()).unwrap();
    assert!(!runtime.preferences.history);
    let saved: Preferences = f.store.load("preferences.json").unwrap().unwrap();
    assert!(!saved.history);
}

#[test]
fn vscode_handoff_is_fresh_nonce_bound_and_never_exposes_receiver_credentials() {
    let f = Fixture::new();
    let connections = Connections {
        store: f.store.clone(),
        cli_home: f.root.join("client"),
    };
    let now = now_ms();
    assert_eq!(
        connections.vscode_setup(now).unwrap()["status"],
        "notRequested"
    );
    assert!(connections.vscode_setup_url("vscode", now).is_err());
    connections
        .request_vscode(false, true, true, 43180, &"a".repeat(64))
        .unwrap();
    let pending = f
        .store
        .load::<serde_json::Value>("vscode-pending.json")
        .unwrap()
        .unwrap();
    let status = connections.vscode_setup(now).unwrap();
    assert_eq!(status["status"], "pending");
    assert_eq!(status["canOpen"], true);
    assert!(!status.to_string().contains("endpoints"));
    let url = connections.vscode_setup_url("vscode", now).unwrap();
    assert_eq!(
        url,
        format!(
            "vscode://rottathiago.tokenotch-vscode/setup?nonce={}",
            pending["nonce"].as_str().unwrap()
        )
    );
    assert!(!url.contains(&"a".repeat(64)));
    assert!(connections.vscode_setup_url("https", now).is_err());
    f.store
        .save(
            "vscode-setup-result.json",
            &json!({"nonce":pending["nonce"],"status":"blocked"}),
        )
        .unwrap();
    assert_eq!(connections.vscode_setup(now).unwrap()["status"], "blocked");
    assert!(connections
        .vscode_setup_url("vscode-insiders", now)
        .unwrap()
        .starts_with("vscode-insiders://"));
    assert!(connections
        .vscode_setup_url("vscode", now + 601_000.0)
        .is_err());
    f.store.remove("vscode-setup-result.json").unwrap();
    assert_eq!(
        connections.vscode_setup(now + 601_000.0).unwrap()["status"],
        "expired"
    );
    f.store.remove("vscode-setup-request.json").unwrap();
    assert_eq!(
        connections.vscode_setup(now).unwrap()["status"],
        "interrupted"
    );
    assert!(connections.vscode_setup_url("vscode", now).is_err());
}

#[test]
fn authentication_is_separate_from_quota_and_never_reuses_another_accounts_percentage() {
    use tokenotch_platform::account::{self, Authentication, Snapshot};
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.connections.cli_home = f.root.join("client");
    let identity = json!({"isAuthenticated":true,"login":"fixture"});
    let authentication = Authentication::parse(&identity).unwrap();
    assert!(Authentication::parse(&json!({})).is_err());
    let quota = json!({"quotaSnapshots":{"premium_interactions":{"isUnlimitedEntitlement":false,
        "entitlementRequests":300,"usedRequests":75,"remainingPercentage":75}}});
    runtime
        .finish_account(Ok(Snapshot {
            authentication: authentication.clone(),
            quota: Ok(account::parse(&identity, &quota, "fixture", now_ms()).unwrap()),
            shared: false,
        }))
        .unwrap();
    assert_eq!(
        runtime.snapshot().unwrap()["accountAuth"]["login"],
        "fixture"
    );
    assert!(runtime
        .finish_account(Ok(Snapshot {
            authentication,
            quota: Err("Quota temporarily unavailable.".into()),
            shared: false,
        }))
        .is_err());
    assert_eq!(
        runtime.snapshot().unwrap()["accountAuth"]["status"],
        "signedIn"
    );
    assert_eq!(
        runtime.account.as_ref().unwrap().quotas[0].remaining_percentage,
        75.0
    );
    assert!(runtime
        .finish_account(Ok(Snapshot {
            authentication: Authentication::SignedIn {
                login: "other".into(),
                plan: None
            },
            quota: Err("Quota temporarily unavailable.".into()),
            shared: false,
        }))
        .is_err());
    assert!(runtime.account.is_none());
    assert_eq!(runtime.snapshot().unwrap()["accountAuth"]["login"], "other");
    assert!(runtime
        .finish_account(Ok(Snapshot {
            authentication: Authentication::SignedOut,
            quota: Err("Sign in.".into()),
            shared: true,
        }))
        .is_err());
    assert_eq!(runtime.snapshot().unwrap()["accountShared"], true);
    assert_eq!(
        runtime.snapshot().unwrap()["accountAuth"]["status"],
        "signedOut"
    );
    assert!(runtime.account.is_none());
    assert!(runtime
        .finish_account(Err("Transport unavailable.".into()))
        .is_err());
    assert_eq!(
        runtime.snapshot().unwrap()["accountAuth"]["status"],
        "unknown"
    );
}

#[test]
fn copilot_cli_candidates_cover_path_and_winget_locations_in_order() {
    let f = Fixture::new();
    let bin = f.root.join("bin");
    let local = f.root.join("local");
    let package = local
        .join("Microsoft")
        .join("WinGet")
        .join("Packages")
        .join("GitHub.Copilot_Microsoft.Winget.Source_fixture");
    fs::create_dir_all(&bin).unwrap();
    fs::create_dir_all(&package).unwrap();
    fs::create_dir_all(
        local
            .join("Microsoft")
            .join("WinGet")
            .join("Packages")
            .join("Other.App"),
    )
    .unwrap();
    let path = std::env::join_paths([bin.clone(), bin.clone()]).unwrap();
    let found = tokenotch_platform::account::candidates(Some(path), Some(local.clone()));
    assert_eq!(
        found,
        vec![
            bin.join("copilot.exe"),
            local
                .join("Microsoft")
                .join("WinGet")
                .join("Links")
                .join("copilot.exe"),
            package.join("copilot.exe"),
            local.join("Programs").join("copilot").join("copilot.exe"),
        ]
    );
    assert!(
        tokenotch_platform::account::candidates(None, Some(PathBuf::from("relative"))).is_empty()
    );
}

#[test]
fn connecting_a_client_resumes_paused_history_once() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.connections.cli_home = f.root.join("client");
    let paused = Preferences {
        history: false,
        ..runtime.preferences.clone()
    };
    runtime.preferences(paused).unwrap();
    assert!(runtime.enable_history_for_connection().unwrap());
    assert!(runtime.preferences.history);
    assert!(runtime.archive.is_some());
    assert!(!runtime.enable_history_for_connection().unwrap());
    assert!(runtime.history("2026-09-01", "2026-09-02").is_ok());
    let saved: Preferences = f.store.load("preferences.json").unwrap().unwrap();
    assert!(saved.history);
}

#[test]
fn vscode_launchers_prefer_stable_before_insiders_and_skip_relative_roots() {
    use tokenotch_platform::vscode::{candidates, Edition};
    let f = Fixture::new();
    let local = f.root.join("local");
    let found = candidates(None, Some(local.clone()), Some(PathBuf::from("relative")));
    assert_eq!(
        found,
        vec![
            (
                Edition::Stable,
                local
                    .join("Programs")
                    .join("Microsoft VS Code")
                    .join("bin")
                    .join("code.cmd")
            ),
            (
                Edition::Insiders,
                local
                    .join("Programs")
                    .join("Microsoft VS Code Insiders")
                    .join("bin")
                    .join("code-insiders.cmd")
            ),
        ]
    );
    assert_eq!(Edition::Insiders.link(), "vscodeInsidersSetup");
}

#[test]
fn account_configuration_changes_clear_cached_identity_and_wait_for_active_requests() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.connections.cli_home = f.root.join("client");
    runtime.account_auth = tokenotch_platform::account::Authentication::SignedOut;
    let mut preferences = runtime.preferences.clone();
    preferences.account_enabled = true;
    runtime.account_busy = true;
    assert!(runtime.preferences(preferences.clone()).is_err());
    runtime.account_busy = false;
    runtime.preferences(preferences).unwrap();
    assert_eq!(
        runtime.snapshot().unwrap()["accountAuth"]["status"],
        "unknown"
    );
}

#[test]
fn cli_start_after_prompt_preserves_work_and_usage_keeps_model_attribution() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.connections.cli_home = f.root.join("client");
    f.store.write("cli.registration", b"registration").unwrap();
    let at = now_ms() - 100.0;
    for (hook, timestamp) in [("userPromptSubmitted", at), ("sessionStart", at + 73.0)] {
        runtime
            .accept(Envelope {
                registration: "registration".into(),
                event: event(hook, timestamp),
            })
            .unwrap();
    }
    let snapshot = runtime.snapshot().unwrap();
    assert_eq!(snapshot["sessions"][0]["working"], true);
    assert_eq!(snapshot["sessions"][0]["observedAt"], at);
    assert!(snapshot["samples"].as_array().unwrap().is_empty());
    runtime
        .accept(Envelope {
            registration: "registration".into(),
            event: event("usage", now_ms()),
        })
        .unwrap();
    let snapshot = runtime.snapshot().unwrap();
    assert_eq!(snapshot["sessions"][0]["working"], true);
    assert_eq!(snapshot["samples"][0]["source"], "cli");
    assert_eq!(snapshot["samples"][0]["tokens"]["model"], "fixture-model");
    assert_eq!(snapshot["samples"][0]["tokens"]["input"], 60);
    assert_eq!(snapshot["samples"][0]["tokens"]["output"], 20);
}

#[test]
fn archive_survives_restart_and_deduplicates_separately_from_live_data() {
    let f = Fixture::new();
    let at = now_ms();
    let usage = event("usage", at);
    let prefs = Preferences {
        history: true,
        timelines: true,
        ..Default::default()
    };
    {
        let mut archive = Archive::open(&f.store).unwrap();
        archive
            .checkpoint(true, &[hook::UsageSource::Cli], at, false)
            .unwrap();
        assert!(archive.record(&usage, &prefs, false).unwrap());
        assert!(!archive.record(&usage, &prefs, false).unwrap());
        let day = archive.today(at).unwrap();
        let saved = archive.history(&day, &day).unwrap();
        assert_eq!(saved.days[0].usage.input, 60);
        assert_eq!(saved.days[0].usage.cache_input, 30);
        assert_eq!(saved.days[0].usage.cache_write, 10);
        assert_eq!(saved.days[0].usage.calls, 1);
        let timeline = archive.timeline(None).unwrap();
        assert_ne!(timeline[0].session, usage.session);
        assert_ne!(
            timeline[0].event.tokens.as_ref().unwrap().call_id,
            usage.tokens.as_ref().unwrap().call_id
        );
    }
    let mut archive = Archive::open(&f.store).unwrap();
    assert!(!archive.record(&usage, &prefs, false).unwrap());
    archive.delete(true).unwrap();
    let day = archive.today(at).unwrap();
    assert_eq!(archive.history(&day, &day).unwrap().days[0].usage.calls, 1);
    assert!(archive.timeline(None).unwrap().is_empty());
    archive.delete(false).unwrap();
    assert!(archive.history(&day, &day).unwrap().days.is_empty());
    let raw = fs::read(f.root.join("usage.sqlite")).unwrap();
    assert!(!raw
        .windows(b"NEVER SAVE THIS CONTENT".len())
        .any(|v| v == b"NEVER SAVE THIS CONTENT"));
}

#[test]
fn paused_history_no_backfill_and_imports_never_create_timelines() {
    let f = Fixture::new();
    let mut archive = Archive::open(&f.store).unwrap();
    let usage = event("usage", now_ms());
    assert!(!archive
        .record(&usage, &Preferences::default(), false)
        .unwrap());
    assert!(archive
        .record(
            &usage,
            &Preferences {
                history: true,
                timelines: true,
                ..Default::default()
            },
            true
        )
        .unwrap());
    assert!(archive.timeline(None).unwrap().is_empty());
}

#[test]
fn notice_consent_starts_fresh_and_restart_never_restores_work() {
    let f = Fixture::new();
    let at = now_ms();
    let mut attention = Attention::open(&f.store, false).unwrap();
    attention
        .observe(
            &event("agentStop", at),
            &Preferences::default(),
            &f.store,
            at,
        )
        .unwrap();
    assert_eq!(attention.notices.len(), 1);
    attention.remember(&f.store, true).unwrap();
    assert!(Attention::open(&f.store, true).unwrap().notices.is_empty());
    let prefs = Preferences {
        remember_notices: true,
        ..Default::default()
    };
    let next = event("agentStop", at + 1.0);
    attention
        .observe(&next, &prefs, &f.store, at + 1.0)
        .unwrap();
    let restored = Attention::open(&f.store, true).unwrap();
    assert!(restored.notices.values().next().unwrap().restored);
    let mut active = event("activity", at + 2.0);
    active.kind = EventKind::Idle;
    attention
        .observe(&active, &prefs, &f.store, at + 2.0)
        .unwrap();
    assert!(!attention.notices.values().next().unwrap().resolved);
}

#[test]
fn quota_rejects_unknown_fields_and_distinguishes_unlimited() {
    use tokenotch_platform::account::parse;
    let identity = json!({"isAuthenticated":true,"login":"fixture"});
    let quota = json!({"quotaSnapshots":{"premium_interactions":{
        "isUnlimitedEntitlement":true,"entitlementRequests":-1,"usedRequests":2,"remainingPercentage":100}}});
    assert!(parse(&identity, &quota, "fixture", 0.0).unwrap().quotas[0].is_unlimited_entitlement);
    assert!(parse(
        &identity,
        &json!({"quotaSnapshots":{"premium_interactions":{"usedRequests":0}}}),
        "fixture",
        0.0
    )
    .is_err());
}

#[test]
fn broker_is_allowlisted_bounded_and_consumes_once() {
    use tokenotch_platform::broker::execute;
    let f = Fixture::new();
    let request = json!({"version":1,"nonce":"fixture"});
    f.store.save("vscode-setup-request.json", &request).unwrap();
    let value = execute(
        &f.store,
        br#"{"action":"read","name":"vscode-setup-request.json"}"#,
    )
    .unwrap();
    assert!(execute(&f.store, br#"{"action":"read","name":"account"}"#).is_err());
    assert!(execute(
        &f.store,
        br#"{"action":"write","name":"preferences.json","value":{}}"#
    )
    .is_err());
    let consume =
        serde_json::to_vec(&json!({"action":"consume","digest":value["digest"]})).unwrap();
    execute(&f.store, &consume).unwrap();
    assert!(execute(&f.store, &consume).is_err());
}

#[cfg(windows)]
#[test]
fn private_file_reads_reject_hard_links() {
    let f = Fixture::new();
    f.store.write("original", b"synthetic").unwrap();
    fs::hard_link(f.root.join("original"), f.root.join("linked")).unwrap();
    assert!(f.store.read("linked", 128).is_err());
}

#[test]
fn notification_receipts_prevent_replay_after_restart_without_remembering_notices() {
    use tokenotch_platform::notifications::Notifications;
    let f = Fixture::new();
    let at = now_ms();
    let prefs = Preferences {
        notifications: true,
        notify_stopped: true,
        ..Default::default()
    };
    let stop = event("agentStop", at);
    let mut attention = Attention::open(&f.store, false).unwrap();
    let notice = attention.observe(&stop, &prefs, &f.store, at).unwrap();
    let mut notifications = Notifications::open(&f.store, at).unwrap();
    assert!(notifications
        .observe(&stop, notice.as_ref(), &prefs, &f.store, at)
        .unwrap()
        .is_some());
    drop(attention);
    let mut attention = Attention::open(&f.store, false).unwrap();
    assert!(attention.notices.is_empty());
    let notice = attention.observe(&stop, &prefs, &f.store, at).unwrap();
    let mut notifications = Notifications::open(&f.store, at).unwrap();
    assert!(notifications
        .observe(&stop, notice.as_ref(), &prefs, &f.store, at)
        .unwrap()
        .is_none());
    assert!(!f.root.join("notices.json").exists());
}

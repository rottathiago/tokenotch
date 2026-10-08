use chrono::NaiveDate;
use rusqlite::{params, Connection};
use serde_json::json;
use std::{fs, path::PathBuf};
use tokenotch_core::hook::{self, Source, UsageSource};
use tokenotch_platform::{
    archive::{Aggregate, Archive, History},
    calendar,
    preferences::Preferences,
    runtime::Runtime,
    storage::{random_id, Store},
    transport::now_ms,
};

struct Fixture {
    root: PathBuf,
    store: Store,
}
impl Fixture {
    fn new(zone: &str) -> Self {
        let root =
            std::env::temp_dir().join(format!("tokenotch-coverage-{}", random_id().unwrap()));
        let store = Store::open(root.clone()).unwrap();
        let db = Connection::open(store.prepare_file("usage.sqlite").unwrap()).unwrap();
        db.execute_batch("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            .unwrap();
        db.execute("INSERT INTO metadata VALUES ('zone',?1)", [zone])
            .unwrap();
        Self { root, store }
    }
    fn archive(&self) -> Archive {
        Archive::open(&self.store).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}
fn at(value: &str) -> f64 {
    chrono::DateTime::parse_from_rfc3339(value)
        .unwrap()
        .timestamp_millis() as f64
}
fn prefs() -> Preferences {
    Preferences {
        history: true,
        ..Default::default()
    }
}
fn event(time: f64, id: &str, source: UsageSource) -> hook::Observation {
    let mut event = hook::normalize(&serde_json::to_vec(&json!({
        "sessionId":"coverage-fixture", "timestamp":time, "eventId":id, "usageContract":1,
        "inputTokens":100, "outputTokens":20, "cacheReadTokens":30, "cacheReadTokensReported":true,
        "cacheWriteTokens":10, "cacheWriteTokensReported":true, "model":"fixture-model"
    })).unwrap(), Source::Cli, "usage", time).unwrap().unwrap();
    if source != UsageSource::Cli {
        event.version = 4;
        event.source = Source::Vscode;
        event.metric_source = Some(source);
    }
    event
}
fn seconds(history: &History, source: &str) -> f64 {
    history
        .coverage
        .iter()
        .filter(|row| row.source == source)
        .map(|row| row.recording_seconds)
        .sum()
}
fn tick(archive: &mut Archive, sources: &[UsageSource], time: f64) {
    archive.checkpoint(true, sources, time, false).unwrap();
}

#[test]
fn coverage_is_source_opportunity_not_calls_and_all_is_a_union() {
    let f = Fixture::new("UTC");
    let mut archive = f.archive();
    let start = at("2026-09-30T12:00:00Z");
    tick(&mut archive, &[UsageSource::Cli], start);
    tick(&mut archive, &[UsageSource::Cli], start + 60_000.0);
    tick(
        &mut archive,
        &[UsageSource::Cli, UsageSource::VscodeLocal],
        start + 60_000.0,
    );
    tick(
        &mut archive,
        &[UsageSource::Cli, UsageSource::VscodeLocal],
        start + 120_000.0,
    );
    let history = archive.history("2026-09-30", "2026-09-30").unwrap();
    assert!(history.days.is_empty());
    assert_eq!(seconds(&history, "cli"), 120.0);
    assert_eq!(seconds(&history, "vscodeLocal"), 60.0);
    assert_eq!(seconds(&history, "vscodeCopilot"), 0.0);
    assert_eq!(seconds(&history, "all"), 120.0);
    assert_eq!(
        history
            .hourly_coverage
            .iter()
            .find(|r| r.source == "all")
            .unwrap()
            .recording_seconds,
        120.0
    );
}

#[test]
fn restart_pause_clock_reversal_and_sleep_never_fill_unobserved_time() {
    let f = Fixture::new("UTC");
    let mut archive = f.archive();
    let start = at("2026-09-30T12:00:00Z");
    let cli = [UsageSource::Cli];
    tick(&mut archive, &cli, start);
    tick(&mut archive, &cli, start + 60_000.0);
    drop(archive);
    let mut archive = f.archive();
    archive
        .checkpoint(true, &cli, start + 120_000.0, true)
        .unwrap();
    tick(&mut archive, &cli, start + 180_000.0);
    archive
        .checkpoint(false, &[], start + 180_000.0, false)
        .unwrap();
    tick(&mut archive, &cli, start + 240_000.0);
    tick(&mut archive, &cli, start + 300_000.0);
    tick(&mut archive, &cli, start + 3_600_000.0);
    tick(&mut archive, &cli, start + 120_000.0);
    tick(&mut archive, &cli, start + 180_000.0);
    let history = archive.history("2026-09-30", "2026-09-30").unwrap();
    assert_eq!(
        seconds(&history, "all"),
        180.0,
        "repeated wall-clock intervals must not double count"
    );
    assert!(history
        .source_gaps
        .iter()
        .any(|g| g.source == "cli" && g.start <= start + 60_000.0 && g.end >= start + 3_600_000.0));
}

#[test]
fn imports_duplicates_delayed_events_and_deletion_do_not_backfill_coverage() {
    let f = Fixture::new("UTC");
    let mut archive = f.archive();
    let start = at("2026-09-30T12:00:00Z");
    tick(&mut archive, &[UsageSource::Cli], start);
    tick(&mut archive, &[UsageSource::Cli], start + 60_000.0);
    assert!(!archive
        .record(
            &event(start - 1.0, "too-early", UsageSource::Cli),
            &prefs(),
            false
        )
        .unwrap());
    let delayed = event(start + 1.0, "delayed", UsageSource::Cli);
    assert!(archive.record(&delayed, &prefs(), false).unwrap());
    assert!(!archive.record(&delayed, &prefs(), false).unwrap());
    assert!(archive
        .record(
            &event(start - 1000.0, "import", UsageSource::VscodeLocal),
            &prefs(),
            true
        )
        .unwrap());
    let history = archive.history("2026-09-30", "2026-09-30").unwrap();
    assert_eq!(seconds(&history, "all"), 60.0);
    assert_eq!(seconds(&history, "vscodeLocal"), 0.0);
    assert_eq!(history.days.iter().map(|r| r.usage.calls).sum::<u64>(), 2);
    assert!(history
        .source_gaps
        .iter()
        .any(|g| g.source == "vscodeLocal" && g.start == start - 1000.0));
    assert!(archive.timeline(None).unwrap().is_empty());
    archive.delete(false).unwrap();
    tick(&mut archive, &[UsageSource::Cli], start + 120_000.0);
    assert!(!archive.record(&delayed, &prefs(), false).unwrap());
    let history = archive.history("2026-09-30", "2026-09-30").unwrap();
    assert!(history.days.is_empty());
    assert_eq!(seconds(&history, "all"), 0.0);
    assert_eq!(history.started_at, Some(start + 120_000.0));
}

#[test]
fn reporting_calendar_preserves_dst_midnight_and_seven_day_retention() {
    for (zone, day, count, hours) in [
        ("America/New_York", "2026-03-08", 23, 23.0),
        ("America/New_York", "2026-11-01", 25, 25.0),
        ("Australia/Lord_Howe", "2026-10-04", 24, 23.5),
        ("Australia/Lord_Howe", "2026-04-05", 25, 24.5),
        ("Asia/Kathmandu", "2026-09-30", 24, 24.0),
    ] {
        let zone = zone.parse().unwrap();
        let interval =
            calendar::day(NaiveDate::parse_from_str(day, "%Y-%m-%d").unwrap(), zone).unwrap();
        let buckets = calendar::hours(&interval, zone).unwrap();
        assert_eq!(buckets.len(), count, "{zone} {day}");
        assert_eq!((interval.end - interval.start) / 3_600_000.0, hours);
        for bucket in &buckets {
            let middle = calendar::hour((bucket.start + bucket.end) / 2.0, zone).unwrap();
            assert_eq!(middle.start, bucket.start);
            assert_eq!(middle.end, bucket.end);
        }
    }
    let f = Fixture::new("America/New_York");
    let mut archive = f.archive();
    let midnight = at("2026-11-01T00:00:00-04:00");
    tick(&mut archive, &[UsageSource::Cli], midnight - 30_000.0);
    tick(&mut archive, &[UsageSource::Cli], midnight + 30_000.0);
    let history = archive.history("2026-10-31", "2026-11-01").unwrap();
    assert_eq!(
        history
            .coverage
            .iter()
            .filter(|r| r.source == "all")
            .map(|r| r.recording_seconds)
            .collect::<Vec<_>>(),
        vec![30.0, 30.0]
    );
    for (id, time) in [("old", midnight - 30_000.0), ("keep", midnight + 1.0)] {
        archive
            .record(&event(time, id, UsageSource::Cli), &prefs(), true)
            .unwrap();
    }
    archive.prune(7, at("2026-11-07T23:59:00-05:00")).unwrap();
    let history = archive.history("2026-10-31", "2026-11-07").unwrap();
    assert_eq!(history.hours.len(), 1);
    assert!(history
        .hourly_coverage
        .iter()
        .all(|r| r.bucket.starts_with("2026-11-01")));
    assert_eq!(history.days.len(), 2);
    assert_eq!(seconds(&history, "all"), 60.0);
    assert_eq!(history.time_zone, "America/New_York");
}

#[test]
fn schema_one_migration_keeps_numbers_without_inventing_coverage() {
    let f = Fixture::new("UTC");
    let start = at("2026-09-30T12:00:00Z");
    {
        let db = Connection::open(f.store.path("usage.sqlite").unwrap()).unwrap();
        db.execute_batch("CREATE TABLE daily (day TEXT,source TEXT,model TEXT,usage TEXT,PRIMARY KEY(day,source,model));
            INSERT INTO metadata VALUES ('schema','1'),('recording','true');").unwrap();
        for key in ["started", "checkpoint"] {
            db.execute(
                "INSERT INTO metadata VALUES (?1,?2)",
                params![key, start.to_string()],
            )
            .unwrap();
        }
        let usage = Aggregate {
            calls: 1,
            input: 100,
            ..Default::default()
        };
        db.execute(
            "INSERT INTO daily VALUES ('2026-09-30','cli','legacy',?1)",
            [serde_json::to_string(&usage).unwrap()],
        )
        .unwrap();
    }
    let mut archive = f.archive();
    tick(&mut archive, &[UsageSource::Cli], start + 60_000.0);
    let history = archive.history("2026-09-30", "2026-09-30").unwrap();
    assert_eq!(history.days[0].usage.input, 100);
    assert_eq!(history.coverage_began, Some(start + 60_000.0));
    assert!(history.coverage.is_empty());
    assert!(archive
        .record(
            &event(start + 60_000.0, "new", UsageSource::Cli),
            &prefs(),
            false
        )
        .unwrap());
    tick(&mut archive, &[UsageSource::Cli], start + 120_000.0);
    assert_eq!(
        seconds(&archive.history("2026-09-30", "2026-09-30").unwrap(), "all"),
        60.0
    );
}

#[test]
fn runtime_opportunity_requires_a_ready_consented_receiver_not_observed_calls() {
    let f = Fixture::new("UTC");
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.preferences(prefs()).unwrap();
    let start = now_ms();
    runtime.checkpoint(start, false).unwrap();
    runtime.checkpoint(start + 30_000.0, false).unwrap();
    let day = runtime.archive.as_ref().unwrap().today(start).unwrap();
    assert_eq!(
        seconds(
            &runtime
                .archive
                .as_ref()
                .unwrap()
                .history(&day, &day)
                .unwrap(),
            "all"
        ),
        0.0
    );
    f.store.write("cli.registration", b"synthetic").unwrap();
    runtime.pipe_running = true;
    runtime.checkpoint(start + 30_000.0, false).unwrap();
    runtime.checkpoint(start + 60_000.0, false).unwrap();
    let day = runtime.archive.as_ref().unwrap().today(start).unwrap();
    let history = runtime
        .archive
        .as_ref()
        .unwrap()
        .history(&day, &day)
        .unwrap();
    assert_eq!(seconds(&history, "cli"), 30.0);
    assert!(runtime.tokens.samples().next().is_none());
}

#[test]
fn saved_totals_survive_live_capacity_and_model_overflow() {
    let f = Fixture::new("UTC");
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.preferences(prefs()).unwrap();
    let start = now_ms();
    for i in 0..4097 {
        let mut usage = event(start, &format!("call-{i}"), UsageSource::Cli);
        usage.tokens.as_mut().unwrap().model = Some(format!("model-{}", i % 102));
        runtime.observe(&usage, false).unwrap();
    }
    let snapshot = runtime.snapshot().unwrap();
    assert_eq!(snapshot["samples"].as_array().unwrap().len(), 4096);
    assert_eq!(snapshot["partial"], true);
    let rows = snapshot["today"]["days"].as_array().unwrap();
    assert_eq!(
        rows.iter()
            .map(|r| r["usage"]["calls"].as_u64().unwrap())
            .sum::<u64>(),
        4097
    );
    assert_eq!(
        rows.iter()
            .map(|r| r["usage"]["input"].as_u64().unwrap())
            .sum::<u64>(),
        4097 * 60
    );
    assert!(rows
        .iter()
        .any(|r| r["model"] == "Other models (capacity limit)"));
    assert_eq!(snapshot["today"]["hours"][0]["usage"]["calls"], 4097);
}

#[test]
fn storage_failure_pauses_recording_and_preserves_saved_data() {
    let f = Fixture::new("UTC");
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.preferences(prefs()).unwrap();
    let db = Connection::open(f.store.path("usage.sqlite").unwrap()).unwrap();
    db.execute_batch("CREATE TRIGGER fail_checkpoint BEFORE INSERT ON metadata BEGIN SELECT RAISE(FAIL,'fixture'); END;").unwrap();
    assert!(runtime.checkpoint(now_ms(), false).is_err());
    assert!(!runtime.preferences.history);
    assert!(
        !f.store
            .load::<Preferences>("preferences.json")
            .unwrap()
            .unwrap()
            .history
    );
    assert!(runtime.warning.as_ref().unwrap().contains("preserved"));
}

#[test]
fn legacy_partial_dst_hours_migrate_without_losing_tokens() {
    for (old, expected) in [
        ("2026-10-04T02:00:00+11:00", "2026-10-04T02:30:00+11:00"),
        ("2026-04-05T01:00:00+10:30", "2026-04-05T01:30:00+10:30"),
    ] {
        let f = Fixture::new("Australia/Lord_Howe");
        {
            let db = Connection::open(f.store.path("usage.sqlite").unwrap()).unwrap();
            db.execute_batch(
                "CREATE TABLE hourly (hour TEXT,source TEXT,usage TEXT,PRIMARY KEY(hour,source));
                INSERT INTO metadata VALUES ('schema','1');",
            )
            .unwrap();
            db.execute(
                "INSERT INTO hourly VALUES (?1,'cli',?2)",
                params![
                    old,
                    serde_json::to_string(&Aggregate {
                        input: 100,
                        calls: 1,
                        ..Default::default()
                    })
                    .unwrap()
                ],
            )
            .unwrap();
        }
        let archive = f.archive();
        let history = archive.history(&old[..10], &old[..10]).unwrap();
        assert_eq!(history.hours[0].hour, expected);
        assert_eq!(history.hours[0].usage.input, 100);
        assert!(history.hourly_coverage.is_empty());
    }
}

#[test]
fn vscode_opportunity_requires_approval_and_does_not_require_delivery() {
    let f = Fixture::new("UTC");
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime
        .preferences(Preferences {
            vscode_metrics: true,
            ..prefs()
        })
        .unwrap();
    runtime.receiver_running = true;
    let start = now_ms();
    runtime.checkpoint(start, false).unwrap();
    runtime.checkpoint(start + 10_000.0, false).unwrap();
    f.store
        .save("vscode-approved.json", &json!({"metrics":true}))
        .unwrap();
    f.store
        .save(
            "vscode-settings.receipt.json",
            &json!({"version":1,"settings":{},"owner":{"fixture":true}}),
        )
        .unwrap();
    runtime.checkpoint(start + 10_000.0, false).unwrap();
    runtime.checkpoint(start + 20_000.0, false).unwrap();
    let day = runtime.archive.as_ref().unwrap().today(start).unwrap();
    let history = runtime
        .archive
        .as_ref()
        .unwrap()
        .history(&day, &day)
        .unwrap();
    for source in ["vscodeLocal", "vscodeCopilot", "all"] {
        assert_eq!(seconds(&history, source), 10.0);
    }
    assert!(history.days.is_empty());
}

#[test]
fn source_handoffs_and_backward_clocks_after_pruning_do_not_double_count() {
    let f = Fixture::new("UTC");
    let mut archive = f.archive();
    let start = at("2026-09-20T12:00:00Z");
    tick(&mut archive, &[UsageSource::Cli], start);
    tick(&mut archive, &[UsageSource::Cli], start + 60_000.0);
    tick(&mut archive, &[UsageSource::VscodeLocal], start + 120_000.0);
    assert_eq!(
        seconds(&archive.history("2026-09-20", "2026-09-20").unwrap(), "all"),
        60.0
    );
    tick(&mut archive, &[UsageSource::VscodeLocal], start + 180_000.0);
    archive.prune(7, at("2026-09-30T00:00:00Z")).unwrap();
    archive
        .checkpoint(true, &[UsageSource::Cli], start, true)
        .unwrap();
    tick(&mut archive, &[UsageSource::Cli], start + 60_000.0);
    let history = archive.history("2026-09-20", "2026-09-20").unwrap();
    assert_eq!(seconds(&history, "all"), 120.0);
    assert_eq!(seconds(&history, "cli"), 60.0);
}

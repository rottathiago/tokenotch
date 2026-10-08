use chrono::NaiveDate;
use rusqlite::{params, Connection};
use serde_json::json;
use std::{fs, path::PathBuf};
use tokenotch_core::hook::{self, Source};
use tokenotch_platform::{
    archive::{Aggregate, Archive},
    navigation::{DetailInbox, DetailKind, DetailRequest},
    preferences::Preferences,
    storage::{random_id, Store},
    transport::now_ms,
};

struct Fixture {
    root: PathBuf,
    store: Store,
}
impl Fixture {
    fn new() -> Self {
        let root =
            std::env::temp_dir().join(format!("tokenotch-navigation-{}", random_id().unwrap()));
        let store = Store::open(root.clone()).unwrap();
        Self { root, store }
    }
    fn db(&self) -> Connection {
        Connection::open(self.store.path("usage.sqlite").unwrap()).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}
fn event(now: f64) -> hook::Observation {
    hook::normalize(&serde_json::to_vec(&json!({"sessionId":"navigation-fixture","timestamp":now,"eventId":"call",
        "usageContract":1,"inputTokens":100,"outputTokens":20,"model":"fixture","durationMs":12,"timeToFirstTokenMs":3})).unwrap(),
        Source::Cli,"usage",now).unwrap().unwrap()
}

#[test]
fn limited_history_keeps_full_denominators_and_can_select_a_model_beyond_the_limit() {
    let f = Fixture::new();
    let archive = Archive::open(&f.store).unwrap();
    let mut db = f.db();
    let tx = db.transaction().unwrap();
    let usage = serde_json::to_string(&Aggregate {
        input: 1,
        calls: 1,
        ..Default::default()
    })
    .unwrap();
    {
        let mut statement = tx
            .prepare("INSERT INTO daily VALUES (?1,'cli',?2,?3)")
            .unwrap();
        for i in 0..21000 {
            let day =
                NaiveDate::from_ymd_opt(2026, 1, 1).unwrap() + chrono::Duration::days(i / 100);
            statement
                .execute(params![
                    day.to_string(),
                    format!("model-{}", i % 100),
                    usage
                ])
                .unwrap();
        }
        for name in ["", "Other models (capacity limit)", "tail-model"] {
            statement
                .execute(params!["2026-09-30", name, usage])
                .unwrap();
        }
    }
    tx.commit().unwrap();
    let history = archive.history("2026-01-01", "2026-09-30").unwrap();
    assert!(history.truncated);
    assert_eq!(history.days.len(), 20000);
    assert_eq!(history.row_count, 21003);
    assert_eq!(
        history
            .totals
            .iter()
            .map(|row| row.usage.calls)
            .sum::<u64>(),
        21003
    );
    let selected = archive
        .history_filtered("2026-01-01", "2026-09-30", Some("tail-model"))
        .unwrap();
    assert!(!selected.truncated);
    assert_eq!(selected.days.len(), 1);
    assert_eq!(selected.days[0].model.as_deref(), Some("tail-model"));
    assert_eq!(
        selected
            .totals
            .iter()
            .map(|row| row.usage.calls)
            .sum::<u64>(),
        21003
    );
    let unknown = archive
        .history_filtered("2026-01-01", "2026-09-30", Some(""))
        .unwrap();
    assert_eq!(unknown.days[0].model, None);
    let missing = archive
        .history_filtered("2026-01-01", "2026-09-30", Some("not-present"))
        .unwrap();
    assert!(missing.days.is_empty());
    assert_eq!(
        missing
            .totals
            .iter()
            .map(|row| row.usage.calls)
            .sum::<u64>(),
        21003
    );
}

#[test]
fn timelines_browse_every_retained_session_and_expose_session_pruning_and_expiry() {
    let f = Fixture::new();
    let archive = Archive::open(&f.store).unwrap();
    let now = now_ms();
    let mut usage = event(now);
    let session = archive.timeline_session(Source::Cli, &usage.session);
    usage.session = session.clone();
    let data = serde_json::to_string(&usage).unwrap();
    let mut db = f.db();
    let tx = db.transaction().unwrap();
    {
        let mut insert = tx
            .prepare("INSERT INTO timeline VALUES (?1,?2,'cli',?3,?4)")
            .unwrap();
        for i in 0..2101 {
            insert
                .execute(params![
                    format!("call-{i}"),
                    session,
                    now - 3000.0 + f64::from(i),
                    data
                ])
                .unwrap();
        }
        for i in 0..205 {
            insert
                .execute(params![
                    format!("session-{i}"),
                    hook::digest(&i.to_string()),
                    now - 10000.0,
                    data
                ])
                .unwrap();
        }
    }
    tx.commit().unwrap();
    let list = archive.timeline_sessions(7, now).unwrap();
    assert_eq!(list.sessions.len(), 206);
    assert!(list.status.pruned);
    let summary = list
        .sessions
        .iter()
        .find(|row| row.session == session)
        .unwrap();
    assert_eq!(summary.count, 2000);
    assert!(summary.truncated);
    let detail = archive.timeline_detail(&session, 7, now).unwrap();
    assert_eq!(detail.events.len(), 2000);
    assert!(detail.truncated);
    assert!(detail
        .events
        .windows(2)
        .all(|pair| pair[0].timestamp <= pair[1].timestamp));
    assert_eq!(
        detail.events[0].event.tokens.as_ref().unwrap().duration_ms,
        Some(12.0)
    );
    assert!(archive
        .timeline_detail(&session, 1, now + 86_400_001.0)
        .err()
        .unwrap()
        .contains("expired"));
}

#[test]
fn repeated_activity_polls_do_not_evict_session_work_from_the_timeline() {
    let f = Fixture::new();
    let mut archive = Archive::open(&f.store).unwrap();
    let now = now_ms();
    let prefs = Preferences {
        timelines: true,
        ..Default::default()
    };
    let activity = |at: f64, active: bool| {
        hook::normalize(
            &serde_json::to_vec(
                &json!({"sessionId":"navigation-fixture","timestamp":at,"active":active}),
            )
            .unwrap(),
            Source::Cli,
            "activity",
            at,
        )
        .unwrap()
        .unwrap()
    };
    let usage = event(now - 10_000.0);
    archive.record(&usage, &prefs, false).unwrap();
    for (i, active) in [true, true, false, false, false, true, false]
        .into_iter()
        .enumerate()
    {
        archive
            .record(
                &activity(now - 9_000.0 + i as f64 * 1000.0, active),
                &prefs,
                false,
            )
            .unwrap();
    }
    let session = archive.timeline_session(Source::Cli, &usage.session);
    let kinds: Vec<_> = archive
        .timeline_detail(&session, 7, now)
        .unwrap()
        .events
        .iter()
        .map(|row| row.event.kind)
        .collect();
    assert_eq!(
        kinds,
        [
            hook::EventKind::Usage,
            hook::EventKind::Active,
            hook::EventKind::Idle,
            hook::EventKind::Active,
            hook::EventKind::Idle
        ]
    );
}

#[test]
fn timeline_coverage_and_deletion_are_independent_of_usage_history() {
    let f = Fixture::new();
    let mut archive = Archive::open(&f.store).unwrap();
    let now = now_ms();
    let usage = event(now);
    let prefs = Preferences {
        timelines: true,
        ..Default::default()
    };
    archive
        .timeline_checkpoint(true, &[Source::Cli], now, false)
        .unwrap();
    archive.record(&usage, &prefs, false).unwrap();
    archive
        .timeline_checkpoint(false, &[], now + 1000.0, false)
        .unwrap();
    let list = archive.timeline_sessions(7, now + 1000.0).unwrap();
    assert!(list.status.interrupted);
    assert!(!list.status.recording);
    let history_generation = archive.history_generation();
    let timeline_generation = archive.timeline_generation();
    let session = archive.timeline_session(Source::Cli, &usage.session);
    assert_eq!(list.sessions[0].session, session);
    assert_ne!(session, usage.session);
    archive.delete(false).unwrap();
    assert_eq!(archive.timeline_generation(), timeline_generation);
    assert_ne!(archive.history_generation(), history_generation);
    assert!(archive.timeline_detail(&session, 7, now).is_ok());
    archive.delete(true).unwrap();
    assert_ne!(archive.timeline_generation(), timeline_generation);
    assert!(archive.timeline_detail(&session, 7, now).is_err());
    let status = archive.timeline_sessions(7, now).unwrap().status;
    assert!(!status.pruned);
    assert!(!status.interrupted);
}

#[test]
fn unlinked_vscode_usage_has_no_timeline_and_schema_two_coverage_is_unknown() {
    let f = Fixture::new();
    let mut archive = Archive::open(&f.store).unwrap();
    let now = now_ms();
    let mut usage = event(now);
    usage.version = 4;
    usage.source = Source::Vscode;
    usage.metric_source = Some(hook::UsageSource::VscodeLocal);
    usage.metric_session_reported = Some(false);
    let prefs = Preferences {
        timelines: true,
        ..Default::default()
    };
    archive.record(&usage, &prefs, false).unwrap();
    assert!(archive
        .timeline_sessions(7, now)
        .unwrap()
        .sessions
        .is_empty());
    usage.metric_session_reported = Some(true);
    archive.record(&usage, &prefs, false).unwrap();
    drop(archive);
    f.db()
        .execute("UPDATE metadata SET value='2' WHERE key='schema'", [])
        .unwrap();
    let archive = Archive::open(&f.store).unwrap();
    let list = archive.timeline_sessions(7, now).unwrap();
    assert_eq!(list.sessions.len(), 1);
    assert!(list.status.legacy);
}

fn request(value: u32) -> DetailRequest {
    DetailRequest {
        kind: DetailKind::History,
        captured_at: 1.0,
        archive_id: Some("generation".into()),
        data: json!({"value":value}),
    }
}
#[test]
fn captured_navigation_is_bounded_consumed_once_and_rejects_cleared_or_expired_targets() {
    let mut inbox = DetailInbox::default();
    request(1).validate(Some("generation")).unwrap();
    assert!(request(1).validate(Some("cleared")).is_err());
    assert!(request(1).validate(None).is_err());
    inbox.put(request(1), 0.0);
    inbox.put(request(2), 1.0);
    assert_eq!(inbox.take(2.0).unwrap().unwrap().data["value"], 2);
    assert!(inbox.take(3.0).unwrap().is_none());
    inbox.put(request(3), 0.0);
    assert!(inbox.take(600_000.0).is_err());
    let mut large = request(4);
    large.data = json!({"tooLarge":"x".repeat(4 * 1_048_576)});
    assert!(large.validate(Some("generation")).is_err());
}

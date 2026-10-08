use chrono::DateTime;
use serde_json::json;
use std::{collections::BTreeMap, fs, path::PathBuf};
use tokenotch_core::hook::{self, Source};
use tokenotch_platform::{
    attention::Attention,
    desktop::{deliver_channels, CardState, Channel},
    notifications::{parse_health, Alert, Category, Delivery, HealthLedger, Notifications, Target},
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
    fn new() -> Self {
        let root =
            std::env::temp_dir().join(format!("tokenotch-notifications-{}", random_id().unwrap()));
        let store = Store::open(root.clone()).unwrap();
        Self { root, store }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}
fn prefs() -> Preferences {
    Preferences {
        notifications: true,
        notify_context: true,
        notify_incidents: true,
        notify_recovery: true,
        notify_requests: true,
        service_health: true,
        sound: true,
        expand_card: true,
        ..Default::default()
    }
}
fn context(value: u64, at: f64, limit: u64) -> hook::Observation {
    hook::normalize(
        &serde_json::to_vec(
            &json!({"sessionId":"private-fixture","timestamp":at,"eventId":format!("context-{at}"),
        "currentTokens":value,"tokenLimit":limit}),
        )
        .unwrap(),
        Source::Cli,
        "context",
        at,
    )
    .unwrap()
    .unwrap()
}
fn stop(at: f64) -> hook::Observation {
    hook::normalize(
        &serde_json::to_vec(
            &json!({"sessionId":"private-fixture","timestamp":at,"stopReason":"end_turn"}),
        )
        .unwrap(),
        Source::Cli,
        "agentStop",
        at,
    )
    .unwrap()
    .unwrap()
}
fn feed(policy: &mut Notifications, f: &Fixture, value: u64, at: f64) -> bool {
    policy
        .observe(&context(value, at, 100), None, &prefs(), &f.store, at)
        .unwrap()
        .is_some()
}
fn incidents(id: &str, status: &str, affected: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({"components":[{"id":"copilot","name":"Copilot"},{"id":"git","name":"Git Operations"}],
        "incidents":[{"id":id,"status":status,"name":"DO NOT RETAIN THIS","components":[{"id":affected}]}]})).unwrap()
}

#[test]
fn context_crossings_match_hysteresis_exact_cooldown_and_stale_baselines() {
    let f = Fixture::new();
    let mut policy = Notifications::open(&f.store, 0.0).unwrap();
    assert!(!feed(&mut policy, &f, 90, 0.0));
    assert!(!feed(&mut policy, &f, 69, 1000.0));
    assert!(feed(&mut policy, &f, 80, 2000.0));
    assert!(!feed(&mut policy, &f, 95, 3000.0));
    assert!(!feed(&mut policy, &f, 79, 4000.0));
    assert!(!feed(&mut policy, &f, 80, 5000.0));
    assert!(!feed(&mut policy, &f, 69, 6000.0));
    assert!(!feed(&mut policy, &f, 80, 7000.0));
    assert!(!feed(&mut policy, &f, 69, 400000.0));
    assert!(!feed(&mut policy, &f, 80, 401000.0));
    assert!(!feed(&mut policy, &f, 69, 601000.0));
    assert!(
        feed(&mut policy, &f, 80, 602000.0),
        "exactly ten minutes after the first warning"
    );
    assert!(!feed(&mut policy, &f, 70, 602001.0));
    assert!(
        !feed(&mut policy, &f, 80, 602002.0),
        "70% does not rearm a high-context episode"
    );
    let text = fs::read_to_string(f.root.join("notification-receipts.json")).unwrap();
    assert!(!text.contains("private-fixture"));
    assert!(!text.contains(&context(80, 602000.0, 100).session));
}

#[test]
fn invalidation_staleness_ordering_and_denominator_changes_require_new_baselines() {
    let f = Fixture::new();
    let mut policy = Notifications::open(&f.store, 0.0).unwrap();
    assert!(!feed(&mut policy, &f, 50, 1000.0));
    let invalid = hook::normalize(
        &serde_json::to_vec(
            &json!({"sessionId":"private-fixture","timestamp":2000,"eventId":"reset"}),
        )
        .unwrap(),
        Source::Cli,
        "contextInvalidated",
        2000.0,
    )
    .unwrap()
    .unwrap();
    assert!(policy
        .observe(&invalid, None, &prefs(), &f.store, 2000.0)
        .unwrap()
        .is_none());
    assert!(!feed(&mut policy, &f, 30, 1500.0));
    assert!(!feed(&mut policy, &f, 90, 3000.0));
    assert!(policy
        .observe(&context(30, 4000.0, 50), None, &prefs(), &f.store, 4000.0)
        .unwrap()
        .is_none());
    assert!(
        policy
            .observe(&context(40, 5000.0, 50), None, &prefs(), &f.store, 305001.0)
            .unwrap()
            .is_none(),
        "stale received reading cannot warn"
    );
    assert!(
        !feed(&mut policy, &f, 90, 306000.0),
        "first fresh reading after stale evidence is a baseline"
    );
    assert!(
        !feed(&mut policy, &f, 30, 305000.0),
        "out-of-order low reading cannot rearm"
    );
    assert!(!feed(&mut policy, &f, 95, 307000.0));
    policy.reset_context();
    assert!(!feed(&mut policy, &f, 95, 308000.0));
}

#[test]
fn context_cooldown_survives_restart_without_restoring_a_crossing_baseline() {
    let f = Fixture::new();
    let mut policy = Notifications::open(&f.store, 0.0).unwrap();
    assert!(!feed(&mut policy, &f, 50, 0.0));
    assert!(feed(&mut policy, &f, 80, 1000.0));
    let mut policy = Notifications::open(&f.store, 2000.0).unwrap();
    assert!(!feed(&mut policy, &f, 90, 2000.0));
    assert!(!feed(&mut policy, &f, 69, 3000.0));
    assert!(!feed(&mut policy, &f, 80, 4000.0));
    assert!(!feed(&mut policy, &f, 69, 600000.0));
    assert!(feed(&mut policy, &f, 80, 601000.0));
}

#[test]
fn muted_disabled_snoozed_and_channel_less_events_are_persistently_consumed() {
    for mode in 0..6 {
        let f = Fixture::new();
        let at = 1000.0;
        let mut preferences = prefs();
        match mode {
            0 => preferences.notifications = false,
            1 => preferences.notify_stopped = false,
            2 => preferences.mute_notifications = true,
            3 => preferences.snoozed_until = 2000.0,
            4 => {
                preferences.quiet_hours = true;
                preferences.quiet_start = 0;
                preferences.quiet_end = 0;
            }
            _ => {
                preferences.desktop_banner = false;
                preferences.sound = false;
                preferences.expand_card = false;
            }
        }
        let event = stop(at);
        let mut attention = Attention::open(&f.store, false).unwrap();
        let notice = attention
            .observe(&event, &preferences, &f.store, at)
            .unwrap();
        let mut policy = Notifications::open(&f.store, 0.0).unwrap();
        assert!(policy
            .observe(&event, notice.as_ref(), &preferences, &f.store, at)
            .unwrap()
            .is_none());
        let mut policy = Notifications::open(&f.store, 0.0).unwrap();
        assert!(policy
            .observe(&event, notice.as_ref(), &prefs(), &f.store, at + 2000.0)
            .unwrap()
            .is_none());
        assert!(f.root.join("notification-receipts.json").is_file());
        assert!(!f.root.join("notices.json").exists());
    }
}

#[test]
fn old_receipts_and_preferences_migrate_without_new_optins_or_replayed_events() {
    let f = Fixture::new();
    let at = 1000.0;
    let event = stop(at);
    let key = "a".repeat(64);
    let id = hook::digest(&format!("{key}:Cli:{}:stopped:{at}", event.session));
    f.store
        .save(
            "notification-receipts.json",
            &json!({"key":key,"consumed":{id:at}}),
        )
        .unwrap();
    let mut attention = Attention::open(&f.store, false).unwrap();
    let notice = attention.observe(&event, &prefs(), &f.store, at).unwrap();
    let mut policy = Notifications::open(&f.store, 0.0).unwrap();
    assert!(policy
        .observe(&event, notice.as_ref(), &prefs(), &f.store, at)
        .unwrap()
        .is_none());
    let preferences: Preferences =
        serde_json::from_value(json!({"notifications":true,"sound":true,"notifyRequests":true}))
            .unwrap();
    assert!(preferences.notifications && preferences.sound && preferences.notify_requests);
    assert!(
        !preferences.notify_context
            && !preferences.notify_incidents
            && !preferences.notify_recovery
            && !preferences.mute_notifications
    );
    f.store
        .save(
            "notification-receipts.json",
            &json!({"key":"bad","consumed":{}}),
        )
        .unwrap();
    assert!(Notifications::open(&f.store, at).is_err());
}

#[test]
fn quiet_hours_use_observation_clock_with_dst_and_boundary_semantics() {
    let mut preferences = prefs();
    preferences.quiet_hours = true;
    let zone: chrono_tz::Tz = "America/New_York".parse().unwrap();
    for value in [
        "2026-11-01T05:30:00Z",
        "2026-11-01T06:30:00Z",
        "2026-03-08T07:30:00Z",
        "2026-11-02T03:00:00Z",
    ] {
        assert!(!preferences.allows_at(
            DateTime::parse_from_rfc3339(value)
                .unwrap()
                .with_timezone(&zone)
        ));
    }
    assert!(preferences.allows_at(
        DateTime::parse_from_rfc3339("2026-11-01T13:00:00Z")
            .unwrap()
            .with_timezone(&zone)
    ));
    preferences.quiet_start = 9 * 60;
    preferences.quiet_end = 17 * 60;
    assert!(!preferences.allows_at(
        DateTime::parse_from_rfc3339("2026-11-01T14:00:00Z")
            .unwrap()
            .with_timezone(&zone)
    ));
    assert!(preferences.allows_at(
        DateTime::parse_from_rfc3339("2026-11-01T22:00:00Z")
            .unwrap()
            .with_timezone(&zone)
    ));
    preferences.quiet_end = preferences.quiet_start;
    assert!(!preferences.allows_at(
        DateTime::parse_from_rfc3339("2026-11-01T22:00:00Z")
            .unwrap()
            .with_timezone(&zone)
    ));
}

#[test]
fn health_requires_copilot_incident_records_and_explicit_resolution() {
    let mut ledger = HealthLedger::default();
    assert!(ledger.observe(&BTreeMap::new()).unwrap().1.is_empty());
    let other = parse_health(&incidents("other", "investigating", "git")).unwrap();
    assert!(ledger.observe(&other).unwrap().1.is_empty());
    let active = parse_health(&incidents("one", "investigating", "copilot")).unwrap();
    assert_eq!(ledger.observe(&active).unwrap().1.len(), 1);
    assert!(ledger.observe(&active).unwrap().1.is_empty());
    assert!(ledger.observe(&BTreeMap::new()).unwrap().1.is_empty());
    assert_eq!(
        ledger.active_count(),
        1,
        "feed omission cannot resolve a known incident"
    );
    let resolved = parse_health(&incidents("one", "resolved", "copilot")).unwrap();
    assert_eq!(
        ledger.observe(&resolved).unwrap().1,
        vec![(hook::digest("one"), true)]
    );
    assert!(ledger.observe(&resolved).unwrap().1.is_empty());
    assert!(parse_health(b"{}").is_err());
    assert!(parse_health(&incidents("one", "unknown", "copilot")).is_err());
    assert!(parse_health(&vec![b' '; 262145]).is_err());
    let status_only = json!({"components":[{"id":"copilot","name":"Copilot","status":"major_outage"}],"incidents":[]});
    assert!(
        parse_health(&serde_json::to_vec(&status_only).unwrap())
            .unwrap()
            .is_empty(),
        "component/ring status is not an incident record"
    );
}

fn health(runtime: &mut Runtime, incidents: BTreeMap<String, bool>, now: f64) {
    let generation = runtime.begin_health().unwrap();
    runtime
        .finish_health(generation, Ok(incidents), now)
        .unwrap();
}
#[test]
fn health_failures_restart_and_consent_changes_do_not_replay_missed_alerts() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.preferences(prefs()).unwrap();
    let now = now_ms() + 10.0;
    health(&mut runtime, BTreeMap::new(), now);
    health(
        &mut runtime,
        parse_health(&incidents("one", "investigating", "copilot")).unwrap(),
        now + 1.0,
    );
    assert_eq!(
        runtime.notifications.pop().unwrap().alert.category,
        Category::Incident
    );
    let generation = runtime.begin_health().unwrap();
    assert!(runtime
        .finish_health(generation, Err("offline".into()), now + 2.0)
        .is_err());
    assert_eq!(runtime.health_ledger.active_count(), 1);
    assert!(runtime
        .health_error
        .as_ref()
        .unwrap()
        .contains("not evidence"));
    health(&mut runtime, BTreeMap::new(), now + 3.0);
    assert!(runtime.notifications.is_empty());
    drop(runtime);
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    let now = now_ms() + 10.0;
    health(
        &mut runtime,
        parse_health(&incidents("one", "resolved", "copilot")).unwrap(),
        now,
    );
    assert!(
        runtime.notifications.is_empty(),
        "first valid feed after restart is a baseline, not missed recovery"
    );
    health(
        &mut runtime,
        parse_health(&incidents("two", "investigating", "copilot")).unwrap(),
        now + 1.0,
    );
    assert_eq!(
        runtime.notifications.pop().unwrap().alert.category,
        Category::Incident
    );
    let old = runtime.begin_health().unwrap();
    let mut preferences = prefs();
    preferences.service_health = false;
    runtime.preferences(preferences).unwrap();
    runtime.preferences(prefs()).unwrap();
    let current = runtime.begin_health().unwrap();
    runtime
        .finish_health(old, Err("old request".into()), now + 2.0)
        .unwrap();
    assert!(runtime.health_busy);
    runtime
        .finish_health(current, Ok(BTreeMap::new()), now + 3.0)
        .unwrap();
    assert!(!runtime.health_busy && runtime.health_error.is_none());
}

#[test]
fn service_muting_is_durable_and_no_quotas_or_usage_counts_create_alerts() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    let mut preferences = prefs();
    preferences.mute_notifications = true;
    runtime.preferences(preferences).unwrap();
    let now = now_ms() + 10.0;
    health(&mut runtime, BTreeMap::new(), now);
    health(
        &mut runtime,
        parse_health(&incidents("one", "investigating", "copilot")).unwrap(),
        now + 1.0,
    );
    assert!(runtime.notifications.is_empty());
    runtime.preferences(prefs()).unwrap();
    health(
        &mut runtime,
        parse_health(&incidents("one", "investigating", "copilot")).unwrap(),
        now + 2.0,
    );
    assert!(runtime.notifications.is_empty());
    health(
        &mut runtime,
        parse_health(&incidents("one", "resolved", "copilot")).unwrap(),
        now + 3.0,
    );
    assert_eq!(
        runtime.notifications.pop().unwrap().alert.category,
        Category::Recovery
    );
    for (login, reset, remaining) in [
        ("one", "2026-10", 100),
        ("one", "2026-10", 25),
        ("one", "2026-10", 10),
        ("two", "2026-11", 0),
    ] {
        runtime.account = Some(tokenotch_platform::account::parse(&json!({"isAuthenticated":true,"login":login}),
            &json!({"quotaSnapshots":{"premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":100,"usedRequests":100-remaining,"remainingPercentage":remaining,"resetDate":reset}}}),"fixture",now).unwrap());
        runtime.snapshot().unwrap();
        assert!(runtime.notifications.is_empty());
    }
    let usage = hook::normalize(
        &serde_json::to_vec(
            &json!({"sessionId":"usage","timestamp":now,"eventId":"large-call",
        "usageContract":1,"inputTokens":1000000,"outputTokens":50000}),
        )
        .unwrap(),
        Source::Cli,
        "usage",
        now,
    )
    .unwrap()
    .unwrap();
    runtime.observe(&usage, false).unwrap();
    assert!(
        runtime.notifications.is_empty(),
        "token volume cannot manufacture a quota or billing alert"
    );
    drop(runtime);
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    let now = now_ms() + 10.0;
    health(&mut runtime, BTreeMap::new(), now);
    health(
        &mut runtime,
        parse_health(&incidents("one", "investigating", "copilot")).unwrap(),
        now + 1.0,
    );
    health(
        &mut runtime,
        parse_health(&incidents("one", "resolved", "copilot")).unwrap(),
        now + 2.0,
    );
    assert!(
        runtime.notifications.is_empty(),
        "consumed incident/recovery IDs survive restart"
    );
}

#[test]
fn notification_storage_failure_does_not_disable_independent_archives() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime
        .preferences(Preferences {
            history: true,
            timelines: true,
            ..prefs()
        })
        .unwrap();
    let now = now_ms() + 10.0;
    runtime.observe(&context(50, now, 100), false).unwrap();
    fs::create_dir(f.root.join("notification-receipts.json")).unwrap();
    assert!(runtime
        .observe(&context(80, now + 1.0, 100), false)
        .is_err());
    assert!(runtime.notifications.is_empty());
    assert!(runtime.notification_error.is_some());
    assert!(runtime.preferences.history && runtime.preferences.timelines);
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
}

#[test]
fn queued_delivery_is_masked_by_later_preferences_and_superseded_context() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.preferences(prefs()).unwrap();
    let now = now_ms() + 10.0;
    runtime.observe(&context(50, now, 100), false).unwrap();
    runtime
        .observe(&context(80, now + 1.0, 100), false)
        .unwrap();
    let pending = runtime.notifications[0].clone();
    assert_eq!(
        runtime.notification_delivery(&pending, pending.queued_at - 1.0),
        Delivery::default()
    );
    assert_eq!(
        runtime.notification_delivery(&pending, pending.queued_at),
        Delivery {
            desktop: true,
            sound: true,
            card: true
        }
    );
    runtime
        .observe(&context(60, now + 3.0, 100), false)
        .unwrap();
    assert_eq!(
        runtime.notification_delivery(&pending, pending.queued_at + 1.0),
        Delivery::default()
    );
    let mut preferences = prefs();
    preferences.mute_notifications = true;
    runtime.preferences(preferences).unwrap();
    runtime.preferences(prefs()).unwrap();
    assert!(
        runtime.notifications.is_empty(),
        "muting then immediately unmuting must not release old queued alerts"
    );
    assert_eq!(
        pending.delivery_now(&prefs(), pending.queued_at + 60000.0),
        Delivery::default()
    );
}

#[test]
fn failed_receipt_storage_blocks_delivery_and_notice_dismissal_is_not_resolution() {
    let f = Fixture::new();
    let mut policy = Notifications::open(&f.store, 0.0).unwrap();
    fs::create_dir(f.root.join("notification-receipts.json")).unwrap();
    assert!(policy.test(&prefs(), &f.store, 1000.0).is_err());
    fs::remove_dir(f.root.join("notification-receipts.json")).unwrap();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.preferences(prefs()).unwrap();
    let now = now_ms();
    let request = hook::normalize(
        &serde_json::to_vec(&json!({"sessionId":"request","timestamp":now,
        "hook_event_name":"Notification","notification_type":"elicitation_dialog"}))
        .unwrap(),
        Source::Cli,
        "notification",
        now,
    )
    .unwrap()
    .unwrap();
    runtime.observe(&request, false).unwrap();
    let pending = runtime.notifications.pop().unwrap();
    runtime
        .validate_notification_target(&pending.alert.target)
        .unwrap();
    let Target::Notice { id } = pending.alert.target else {
        panic!("expected request target");
    };
    assert!(!runtime.attention.notices.values().next().unwrap().viewed);
    runtime
        .attention
        .acknowledge(&id, true, &runtime.store, false)
        .unwrap();
    let notice = runtime.attention.notices.values().next().unwrap();
    assert!(notice.viewed && notice.dismissed && !notice.resolved);
    let receipts = fs::read(f.root.join("notification-receipts.json")).unwrap();
    runtime.clear("notices").unwrap();
    assert!(runtime
        .validate_notification_target(&Target::Notice { id })
        .is_err());
    assert_eq!(
        fs::read(f.root.join("notification-receipts.json")).unwrap(),
        receipts
    );
}

fn session_event(
    session: &str,
    hook_name: &str,
    at: f64,
    extra: serde_json::Value,
) -> hook::Observation {
    let mut value = json!({"sessionId":session,"timestamp":at});
    value
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    hook::normalize(
        &serde_json::to_vec(&value).unwrap(),
        Source::Cli,
        hook_name,
        at,
    )
    .unwrap()
    .unwrap()
}
fn usage(session: &str, call: &str, at: f64) -> hook::Observation {
    session_event(
        session,
        "usage",
        at,
        json!({"eventId":call,"usageContract":1,"inputTokens":10,
        "outputTokens":2,"model":"fixture-model"}),
    )
}

#[test]
fn a_model_call_after_a_notice_resolves_it_and_withdraws_its_pending_alert() {
    let f = Fixture::new();
    let mut runtime = Runtime::open(f.store.clone()).unwrap();
    runtime.preferences(prefs()).unwrap();
    let now = now_ms() - 10_000.0;
    let approval =
        json!({"hook_event_name":"Notification","notification_type":"permission_prompt"});
    let input = json!({"hook_event_name":"Notification","notification_type":"elicitation_dialog"});
    let cases = [
        ("approval", "notification", approval, "approvalRequested"),
        ("input", "notification", input, "inputRequested"),
        (
            "failure",
            "errorOccurred",
            json!({"recoverable":false}),
            "error",
        ),
        (
            "stop",
            "agentStop",
            json!({"stopReason":"end_turn"}),
            "stopped",
        ),
    ];
    for (session, hook_name, extra, kind) in cases {
        runtime
            .observe(&session_event(session, hook_name, now, extra), false)
            .unwrap();
        // The call that led to the request was observed before it; it must not resolve it.
        runtime
            .observe(
                &usage(session, &format!("{session}-before"), now - 1.0),
                false,
            )
            .unwrap();
        let notice = runtime
            .attention
            .notices
            .values()
            .find(|notice| notice.kind == kind)
            .unwrap()
            .clone();
        assert!(!notice.resolved, "{kind} resolved by an earlier call");
        runtime
            .observe(
                &usage(session, &format!("{session}-after"), now + 1.0),
                false,
            )
            .unwrap();
        let notice = runtime
            .attention
            .notices
            .values()
            .find(|candidate| candidate.id == notice.id)
            .unwrap();
        assert!(notice.resolved, "{kind} not resolved by a later model call");
    }
    for pending in &runtime.notifications {
        assert_eq!(
            runtime.notification_delivery(pending, now + 2.0),
            Delivery::default(),
            "a resolved notice must not still deliver"
        );
    }
}

fn alert() -> Alert {
    Alert {
        id: "fixture".into(),
        category: Category::Context,
        title: "Context".into(),
        body: "Observed".into(),
        target: Target::Usage,
        observed_at: 0.0,
        context: None,
        incident: None,
    }
}
#[test]
fn independent_channels_and_per_display_timers_do_not_replay_hidden_cards() {
    for mask in 0..8 {
        let delivery = Delivery {
            desktop: mask & 1 != 0,
            sound: mask & 2 != 0,
            card: mask & 4 != 0,
        };
        let mut calls = Vec::new();
        let result = deliver_channels(delivery, 0.0, |channel| {
            calls.push(channel);
            if channel == Channel::Desktop {
                Err("Windows banner permission denied".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(calls.contains(&Channel::Desktop), delivery.desktop);
        assert_eq!(calls.contains(&Channel::Sound), delivery.sound);
        assert_eq!(calls.contains(&Channel::Card), delivery.card);
        if delivery.desktop {
            assert!(result.desktop.unwrap().contains("denied"));
        }
        if delivery.sound {
            assert_eq!(result.sound.as_deref(), Some("Sound played"));
        }
    }
    let mut first = CardState::default();
    let mut second = CardState::default();
    first.reveal(alert(), 1000.0);
    second.reveal(alert(), 1200.0);
    assert!(first.automatic(3999.0));
    assert!(!first.expanded(4000.0));
    assert!(
        second.expanded(4000.0),
        "each display receives the full interval"
    );
    second.set_manual(true, false);
    assert!(
        second.expanded(5000.0),
        "a deliberately pinned card survives alert expiry"
    );
    first.reveal(alert(), 6000.0);
    first.pinned = true;
    first.set_manual(true, false);
    assert!(first.dismiss_hidden());
    assert!(
        !first.expanded(6001.0) && !first.open(6001.0, false) && !first.pinned,
        "hidden/fullscreen alerts are discarded, not queued for later"
    );
    assert!(first.alert(6001.0).is_none());
}

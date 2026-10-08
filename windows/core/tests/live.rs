use serde_json::{json, Value};
use tokenotch_core::{
    hook::{digest, normalize, Source, UsageSource},
    live::{ActivityState, TokenLedger, Totals},
};

const NOW: f64 = 1_700_000_000_000.0;

fn event(hook: &str, at: f64, fields: Value) -> tokenotch_core::hook::Observation {
    let mut payload = json!({"sessionId": "one", "timestamp": at});
    payload
        .as_object_mut()
        .unwrap()
        .extend(fields.as_object().unwrap().clone());
    normalize(
        &serde_json::to_vec(&payload).unwrap(),
        Source::Cli,
        hook,
        at,
    )
    .unwrap()
    .unwrap()
}

#[test]
fn activity_ordering_freshness_and_work_start_match_mac_behavior() {
    let mut state = ActivityState::default();
    let active = event("activity", NOW, json!({"active": true}));
    assert!(state.accept(&active, NOW).unwrap());
    assert!(!state.accept(&active, NOW).unwrap());
    let refresh = event("activity", NOW + 660_000.0, json!({"active": true}));
    state.accept(&refresh, refresh.timestamp_unix_ms).unwrap();
    let session = state.sessions().next().unwrap();
    assert_eq!(session.work_started_at_unix_ms, Some(NOW));
    assert!(session.is_working(NOW + 750_000.0));
    assert!(!session.is_working(NOW + 750_001.0));
    let stop = event(
        "agentStop",
        refresh.timestamp_unix_ms,
        json!({"stopReason":"end_turn"}),
    );
    assert!(state.accept(&stop, stop.timestamp_unix_ms).unwrap());
    assert!(!state.accept(&refresh, refresh.timestamp_unix_ms).unwrap());
    assert_eq!(
        state.sessions().next().unwrap().label(NOW + 800_000.0),
        "Execution stopped"
    );
}

#[test]
fn late_cli_start_preserves_fresh_work_without_refreshing_it() {
    for (hook, fields, freshness) in [
        ("userPromptSubmitted", json!({}), 300_000.0),
        ("activity", json!({"active":true}), 90_000.0),
    ] {
        let mut state = ActivityState::default();
        let working = event(hook, NOW, fields);
        state.accept(&working, NOW).unwrap();
        for delay in [73.0, freshness] {
            let started = event("sessionStart", NOW + delay, json!({}));
            assert!(!state.accept(&started, NOW + delay).unwrap());
            let session = state.sessions().next().unwrap();
            assert!(session.is_working(NOW + delay));
            assert_eq!(session.kind, working.kind);
            assert_eq!(session.observed_at_unix_ms, NOW);
            assert_eq!(session.work_started_at_unix_ms, Some(NOW));
        }
        let resumed = event("sessionStart", NOW + freshness + 1.0, json!({}));
        assert!(state.accept(&resumed, resumed.timestamp_unix_ms).unwrap());
        assert!(!state
            .sessions()
            .next()
            .unwrap()
            .is_working(resumed.timestamp_unix_ms));
    }
}

#[test]
fn idle_does_not_erase_terminal_error_and_new_work_can_supersede_it() {
    let mut state = ActivityState::default();
    let failed = event("sessionEnd", NOW, json!({"reason":"error"}));
    state.accept(&failed, NOW).unwrap();
    assert!(!state
        .accept(
            &event("activity", NOW + 1.0, json!({"active":false})),
            NOW + 1.0
        )
        .unwrap());
    assert!(state
        .accept(
            &event("activity", NOW + 2.0, json!({"active":true})),
            NOW + 2.0
        )
        .unwrap());
    assert_eq!(
        state.sessions().next().unwrap().work_started_at_unix_ms,
        Some(NOW + 2.0)
    );
}

#[test]
fn usage_does_not_change_activity_and_duplicate_calls_are_not_counted() {
    let usage = event(
        "usage",
        NOW,
        json!({
            "eventId":"call", "usageContract":1,"inputTokens":100,"outputTokens":20,
            "cacheReadTokens":30,"cacheWriteTokens":10,"cacheReadTokensReported":true,"cacheWriteTokensReported":true
        }),
    );
    assert!(ActivityState::default().accept(&usage, NOW).is_err());
    let mut ledger = TokenLedger::default();
    assert!(ledger.observe(&usage, NOW, false).unwrap());
    assert!(!ledger.observe(&usage, NOW, false).unwrap());
    let total = ledger.totals(None).unwrap();
    assert_eq!(
        (
            total.input,
            total.output,
            total.cache_input,
            total.cache_write,
            total.calls
        ),
        (60, 20, 30, 10, 1)
    );
    assert_eq!(total.view().total, "120");
    assert!(ledger.totals(Some(UsageSource::VscodeLocal)).is_none());
}

#[test]
fn context_invalidation_blocks_old_readings_without_erasing_usage() {
    let mut ledger = TokenLedger::default();
    ledger
        .observe(
            &event(
                "usage",
                NOW,
                json!({"eventId":"call", "usageContract":1,"inputTokens":5,"outputTokens":1}),
            ),
            NOW,
            false,
        )
        .unwrap();
    ledger
        .observe(
            &event("context", NOW, json!({"currentTokens":90,"tokenLimit":100})),
            NOW,
            false,
        )
        .unwrap();
    ledger
        .observe(
            &event("contextInvalidated", NOW + 1.0, json!({"eventId":"reset"})),
            NOW + 1.0,
            false,
        )
        .unwrap();
    assert!(!ledger
        .observe(
            &event(
                "context",
                NOW + 1.0,
                json!({"currentTokens":99,"tokenLimit":100})
            ),
            NOW + 1.0,
            false
        )
        .unwrap());
    assert!(ledger.context(&digest("one")).unwrap().context.is_none());
    assert_eq!(ledger.totals(None).unwrap().view().total, "6");
    ledger
        .observe(
            &event(
                "context",
                NOW + 2.0,
                json!({"currentTokens":0,"tokenLimit":200}),
            ),
            NOW + 2.0,
            false,
        )
        .unwrap();
    let context = ledger.context(&digest("one")).unwrap();
    assert_eq!(context.context.as_ref().unwrap().current_tokens, 0);
    assert!(!context.is_stale(NOW + 300_002.0));
    assert!(context.is_stale(NOW + 300_003.0));
}

#[test]
fn capacity_and_expiry_are_bounded_and_partial_is_explicit() {
    let mut ledger = TokenLedger::default();
    for index in 0..4097 {
        let now = NOW + f64::from(index);
        ledger.observe(&event("usage", now, json!({"eventId":format!("call-{index}"), "usageContract":1,"inputTokens":1,"outputTokens":1})), now, false).unwrap();
    }
    assert_eq!(ledger.sample_count(), 4096);
    assert_eq!(ledger.last_discarded_at_unix_ms, Some(NOW));
    assert_eq!(ledger.totals(None).unwrap().calls, 4096);
    for index in 0..101 {
        let now = NOW + f64::from(index);
        ledger
            .observe(
                &event(
                    "contextInvalidated",
                    now,
                    json!({"sessionId":format!("session-{index}"),"eventId":"reset"}),
                ),
                now,
                false,
            )
            .unwrap();
    }
    assert_eq!(ledger.context_count(), 100);
    ledger.expire(NOW + 86_404_097.0).unwrap();
    assert_eq!(ledger.sample_count(), 0);
    assert_eq!(ledger.context_count(), 0);
    assert!(ledger.last_discarded_at_unix_ms.is_none());
    assert!(ledger.totals(None).is_none());
}

#[test]
fn cache_coverage_and_wide_totals_remain_exact() {
    let mut ledger = TokenLedger::default();
    for (index, reported) in [
        (0, json!({})),
        (1, json!({"cacheReadTokensReported":false})),
        (
            2,
            json!({"cacheReadTokens":0,"cacheReadTokensReported":true}),
        ),
    ] {
        let mut payload = json!({"eventId":format!("call-{index}"),"usageContract":1,"inputTokens":0,"outputTokens":0});
        payload
            .as_object_mut()
            .unwrap()
            .extend(reported.as_object().unwrap().clone());
        ledger
            .observe(&event("usage", NOW, payload), NOW, false)
            .unwrap();
    }
    let totals = ledger.totals(None).unwrap();
    assert_eq!(
        (
            totals.calls,
            totals.cache_reported_calls,
            totals.cache_unreported_calls
        ),
        (3, 1, 1)
    );
    let wide = Totals {
        input: 9_007_199_254_740_993,
        output: 1,
        ..Default::default()
    };
    assert_eq!(wide.view().total, "9007199254740994");
    assert_eq!(wide.view().input, "9007199254740993");
}

#[test]
fn disconnection_clears_only_the_selected_source_and_bad_clocks_fail() {
    let mut state = ActivityState::default();
    state
        .accept(&event("sessionStart", NOW, json!({})), NOW)
        .unwrap();
    state.remove(Source::Cli);
    assert_eq!(state.sessions().count(), 0);
    assert!(state.expire(f64::NAN).is_err());
    let mut ledger = TokenLedger::default();
    ledger
        .observe(
            &event("context", NOW, json!({"currentTokens":10,"tokenLimit":100})),
            NOW,
            false,
        )
        .unwrap();
    ledger.remove(UsageSource::VscodeLocal);
    assert_eq!(ledger.context_count(), 1);
    ledger.remove(UsageSource::Cli);
    assert_eq!(ledger.context_count(), 0);
    assert!(ledger.between(f64::NAN, NOW, None).is_err());
}

#[test]
fn shared_swift_rust_state_contracts() {
    let corpus: Value =
        serde_json::from_str(include_str!("../../../contracts/fixtures/live-state.json")).unwrap();
    assert_eq!(corpus["version"], 1);
    let base = corpus["baseUnixMs"].as_f64().unwrap();
    for fixture in corpus["cases"].as_array().unwrap() {
        let mut activity = ActivityState::default();
        let mut ledger = TokenLedger::default();
        for step in fixture["steps"].as_array().unwrap() {
            let timestamp = base + step["atMs"].as_f64().unwrap();
            let event = event(
                step["hook"].as_str().unwrap(),
                timestamp,
                step["fields"].clone(),
            );
            if event.kind.lifecycle_order().is_some() {
                activity.accept(&event, timestamp).unwrap();
            } else {
                ledger.observe(&event, timestamp, false).unwrap();
            }
        }
        let now = base + fixture["inspectAtMs"].as_f64().unwrap();
        activity.expire(now).unwrap();
        ledger.expire(now).unwrap();
        let totals = ledger.totals(None).map(|v| v.view());
        let actual = json!({
            "sessionCount": activity.sessions().count(),
            "workingCount": activity.sessions().filter(|v| v.is_working(now)).count(),
            "label": activity.sessions().next().map(|v| v.label(now)),
            "total": totals.as_ref().map(|v| &v.total),
            "calls": totals.as_ref().map(|v| &v.calls),
            "contextCurrent": ledger.context(&digest("one")).and_then(|v| v.context.as_ref()).map(|v| v.current_tokens),
        });
        assert_eq!(actual, fixture["expected"], "{}", fixture["name"]);
    }
}

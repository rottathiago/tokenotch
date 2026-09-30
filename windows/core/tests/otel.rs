use serde_json::{json, Value};
use tokenotch_core::{
    hook::UsageSource,
    live::TokenLedger,
    otel::{decode, Error, BODY_LIMIT},
};

const NOW: f64 = 1_700_000_000_000.0;

fn payload(service: &str) -> Value {
    json!({"resourceSpans":[{
        "resource":{"attributes":[{"key":"service.name","value":{"stringValue":service}}]},
        "scopeSpans":[{"spans":[{
            "traceId":"11111111111111111111111111111111","spanId":"2222222222222222",
            "startTimeUnixNano":"1699999999000000000","endTimeUnixNano":"1700000000000000000",
            "attributes":[
                {"key":"gen_ai.operation.name","value":{"stringValue":"chat"}},
                {"key":"gen_ai.provider.name","value":{"stringValue":"github"}},
                {"key":"gen_ai.response.model","value":{"stringValue":"model-1"}},
                {"key":"gen_ai.usage.input_tokens","value":{"intValue":"100"}},
                {"key":"gen_ai.usage.output_tokens","value":{"intValue":"20"}},
                {"key":"gen_ai.usage.cache_read.input_tokens","value":{"intValue":"30"}},
                {"key":"gen_ai.usage.cache_creation.input_tokens","value":{"intValue":"10"}},
                {"key":"prompt","value":{"stringValue":"CONTENT-MUST-NOT-SURVIVE"}}
            ]
        }]}]
    }]})
}

fn attributes(payload: &mut Value) -> &mut Vec<Value> {
    payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["attributes"]
        .as_array_mut()
        .unwrap()
}

#[test]
fn source_routing_disjoint_accounting_and_unlinked_identity() {
    let batch = decode(
        &serde_json::to_vec(&payload("copilot-chat")).unwrap(),
        UsageSource::VscodeLocal,
        NOW,
    )
    .unwrap();
    assert_eq!(
        (
            batch.events.len(),
            batch.filtered,
            batch.rejected,
            batch.unlinked
        ),
        (1, 0, 0, 1)
    );
    let event = &batch.events[0];
    let tokens = event.tokens.as_ref().unwrap();
    assert_eq!(
        (
            tokens.input,
            tokens.output,
            tokens.cache_input,
            tokens.cache_write
        ),
        (60, 20, 30, 10)
    );
    assert_eq!(event.version, 4);
    assert!(!serde_json::to_string(event)
        .unwrap()
        .contains("CONTENT-MUST-NOT-SURVIVE"));
    let mut ledger = TokenLedger::default();
    assert!(ledger.observe(event, NOW + 180_000.0, true).unwrap());
    assert!(!ledger.observe(event, NOW + 180_000.0, true).unwrap());
    assert!(ledger.totals(Some(UsageSource::Cli)).is_none());
    assert_eq!(
        ledger
            .totals(Some(UsageSource::VscodeLocal))
            .unwrap()
            .view()
            .total,
        "120"
    );
    let terminal = decode(
        &serde_json::to_vec(&payload("github-copilot")).unwrap(),
        UsageSource::VscodeLocal,
        NOW,
    )
    .unwrap();
    assert_eq!(terminal.filtered, 1);
    assert!(terminal.events.is_empty());
    let agent_host = decode(
        &serde_json::to_vec(&payload("github-copilot")).unwrap(),
        UsageSource::VscodeCopilot,
        NOW,
    )
    .unwrap();
    assert_eq!(agent_host.events.len(), 1);
    assert_ne!(agent_host.events[0].session, event.session);
}

#[test]
fn malformed_counts_duplicates_and_wrong_service_are_rejected() {
    for value in [
        json!({"stringValue":"100"}),
        json!({"intValue":true}),
        json!({"doubleValue":0.5}),
        json!({"intValue":"1000000001"}),
    ] {
        let mut fixture = payload("copilot-chat");
        attributes(&mut fixture)[3]["value"] = value;
        let batch = decode(
            &serde_json::to_vec(&fixture).unwrap(),
            UsageSource::VscodeLocal,
            NOW,
        )
        .unwrap();
        assert_eq!(batch.rejected, 1);
        assert!(batch.events.is_empty());
    }
    let mut fixture = payload("copilot-chat");
    let duplicate = attributes(&mut fixture)[3].clone();
    attributes(&mut fixture).push(duplicate);
    assert_eq!(
        decode(
            &serde_json::to_vec(&fixture).unwrap(),
            UsageSource::VscodeLocal,
            NOW
        )
        .unwrap()
        .rejected,
        1
    );
    assert_eq!(
        decode(
            &serde_json::to_vec(&payload("other-service")).unwrap(),
            UsageSource::VscodeLocal,
            NOW
        )
        .unwrap()
        .rejected,
        1
    );
}

#[test]
fn parent_spans_are_filtered_and_conversation_link_is_only_reported_data() {
    let mut fixture = payload("copilot-chat");
    attributes(&mut fixture)[0]["value"]["stringValue"] = json!("invoke_agent");
    assert_eq!(
        decode(
            &serde_json::to_vec(&fixture).unwrap(),
            UsageSource::VscodeLocal,
            NOW
        )
        .unwrap()
        .filtered,
        1
    );
    attributes(&mut fixture)[0]["value"]["stringValue"] = json!("chat");
    attributes(&mut fixture).push(
        json!({"key":"gen_ai.conversation.id","value":{"stringValue":"synthetic-conversation"}}),
    );
    let batch = decode(
        &serde_json::to_vec(&fixture).unwrap(),
        UsageSource::VscodeLocal,
        NOW,
    )
    .unwrap();
    assert_eq!(batch.unlinked, 0);
    assert_eq!(batch.events[0].metric_session_reported, Some(true));
    assert!(!serde_json::to_string(&batch)
        .unwrap()
        .contains("synthetic-conversation"));
}

#[test]
fn receiver_limits_and_stale_calls_fail_without_fabricated_totals() {
    assert!(matches!(
        decode(&vec![b' '; BODY_LIMIT + 1], UsageSource::VscodeLocal, NOW),
        Err(Error::Capacity)
    ));
    assert!(decode(b"{}", UsageSource::VscodeLocal, NOW).is_err());
    let batch = decode(
        &serde_json::to_vec(&payload("copilot-chat")).unwrap(),
        UsageSource::VscodeLocal,
        NOW + 86_400_000.0,
    )
    .unwrap();
    assert_eq!(batch.rejected, 1);
    assert!(batch.events.is_empty());
}

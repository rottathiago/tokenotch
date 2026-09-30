use serde_json::Value;
use tokenotch_core::hook::{digest, normalize, Error, Source, INPUT_LIMIT};

fn contains_expected(actual: &Value, expected: &Value, name: &str) {
    if let Some(fields) = expected.as_object() {
        for (key, value) in fields {
            contains_expected(&actual[key], value, name);
        }
    } else if actual.is_number() && expected.is_number() {
        assert_eq!(actual.as_f64(), expected.as_f64(), "{name}");
    } else {
        assert_eq!(actual, expected, "{name}");
    }
}

#[test]
fn shared_swift_rust_hook_contracts() {
    let corpus: Value =
        serde_json::from_str(include_str!("../../../contracts/fixtures/hooks.json")).unwrap();
    assert_eq!(corpus["version"], 1);
    let now = corpus["nowUnixMs"].as_f64().unwrap();
    for fixture in corpus["cases"].as_array().unwrap() {
        let name = fixture["name"].as_str().unwrap();
        assert_eq!(
            ["expected", "error", "filtered"]
                .iter()
                .filter(|key| fixture.get(**key).is_some())
                .count(),
            1,
            "{name}: exactly one outcome is required"
        );
        let source: Source = serde_json::from_value(fixture["source"].clone()).unwrap();
        let input = serde_json::to_vec(&fixture["payload"]).unwrap();
        let result = normalize(&input, source, fixture["hook"].as_str().unwrap(), now);
        if let Some(error) = fixture["error"].as_str() {
            assert_eq!(
                result,
                Err(match error {
                    "metricUpgrade" => Error::MetricUpgrade,
                    "invalidEvent" => Error::InvalidEvent,
                    _ => panic!("{name}: unknown fixture error"),
                }),
                "{name}"
            );
        } else if fixture["filtered"] == true {
            assert_eq!(result.unwrap(), None, "{name}");
        } else {
            let event = result.unwrap().expect(name);
            assert_eq!(event.session, digest("synthetic-session"), "{name}");
            if let Some(tokens) = &event.tokens {
                assert_eq!(
                    tokens.call_id,
                    digest(&format!(
                        "synthetic-session:{}",
                        fixture["payload"]["eventId"].as_str().unwrap()
                    ))
                );
            }
            let value = serde_json::to_value(event).unwrap();
            contains_expected(&value, &fixture["expected"], name);
            let encoded = value.to_string();
            assert!(!encoded.contains("CONTENT-MUST-NOT-SURVIVE"), "{name}");
            assert!(!encoded.contains("synthetic-session"), "{name}");
        }
    }
}

#[test]
fn oversized_and_non_object_input_is_rejected() {
    for input in [
        vec![b' '; INPUT_LIMIT + 1],
        b"[]".to_vec(),
        b"null".to_vec(),
    ] {
        assert_eq!(
            normalize(&input, Source::Cli, "sessionStart", 0.0),
            Err(Error::InvalidEvent)
        );
    }
}

#[test]
fn event_ids_follow_swift_character_bounds_not_utf8_byte_length() {
    let mut payload = serde_json::json!({
        "sessionId": "synthetic-session", "timestamp": 1700000000000_u64,
        "eventId": "\u{00e9}".repeat(512), "currentTokens": 10, "tokenLimit": 100
    });
    assert!(normalize(
        &serde_json::to_vec(&payload).unwrap(),
        Source::Cli,
        "context",
        1700000000000.0
    )
    .is_ok());
    payload["eventId"] = Value::String("\u{00e9}".repeat(513));
    assert_eq!(
        normalize(
            &serde_json::to_vec(&payload).unwrap(),
            Source::Cli,
            "context",
            1700000000000.0
        ),
        Err(Error::InvalidEvent)
    );
}

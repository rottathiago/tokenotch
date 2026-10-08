use serde_json::json;
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
use tokenotch_platform::{
    receiver,
    runtime::Runtime,
    storage::{random_id, Store},
    transport::now_ms,
};

fn payload(at: f64) -> Vec<u8> {
    serde_json::to_vec(&json!({"resourceSpans":[{
        "resource":{"attributes":[{"key":"service.name","value":{"stringValue":"copilot-chat"}}]},
        "scopeSpans":[{"spans":[{
            "traceId":"11111111111111111111111111111111","spanId":"2222222222222222",
            "startTimeUnixNano":format!("{:.0}",(at-1000.0)*1_000_000.0),
            "endTimeUnixNano":format!("{:.0}",at*1_000_000.0),
            "attributes":[
                {"key":"gen_ai.operation.name","value":{"stringValue":"chat"}},
                {"key":"gen_ai.provider.name","value":{"stringValue":"github"}},
                {"key":"gen_ai.response.model","value":{"stringValue":"fixture-model"}},
                {"key":"gen_ai.usage.input_tokens","value":{"intValue":"100"}},
                {"key":"gen_ai.usage.output_tokens","value":{"intValue":"20"}},
                {"key":"prompt","value":{"stringValue":"DO NOT PERSIST RAW TELEMETRY"}}
            ]
        }]}]
    }]}))
    .unwrap()
}

#[tokio::test]
async fn authenticated_loopback_fixed_and_chunked_delivery_and_revocation() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let root = std::env::temp_dir().join(format!("tokenotch-receiver-{}", random_id().unwrap()));
    let store = Store::open(root.clone()).unwrap();
    let mut runtime = Runtime::open(store).unwrap();
    runtime.connections.cli_home = root.join("unused-cli");
    let mut prefs = runtime.preferences.clone();
    prefs.vscode_metrics = true;
    runtime.preferences(prefs).unwrap();
    let shared = Arc::new(Mutex::new(runtime));
    let port = receiver::start(shared.clone()).await.unwrap();
    let token = shared.lock().unwrap().receiver.token.clone();
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
        .unwrap();
    let body = payload(now_ms());
    let invalid = client
        .post(format!("http://127.0.0.1:{port}/invalid/vscodeLocal"))
        .header("content-type", "application/json")
        .body(body.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(invalid.status().as_u16(), 400);
    assert_eq!(shared.lock().unwrap().tokens.sample_count(), 0);
    let url = format!("http://127.0.0.1:{port}/{token}/vscodeLocal/v1/traces");
    assert_eq!(
        client
            .post(&url)
            .header("content-type", "application/json")
            .body(body.clone())
            .send()
            .await
            .unwrap()
            .status()
            .as_u16(),
        200
    );
    assert_eq!(shared.lock().unwrap().tokens.sample_count(), 1);
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap();
    stream.write_all(format!("POST /{token}/vscodeLocal HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n",body.len()).as_bytes()).await.unwrap();
    stream.write_all(&body).await.unwrap();
    stream.write_all(b"\r\n0\r\n\r\n").await.unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).await.unwrap();
    assert!(response.starts_with("HTTP/1.1 200"));
    assert_eq!(shared.lock().unwrap().tokens.sample_count(), 1);
    assert!(shared.lock().unwrap().activity.sessions().next().is_none());
    {
        let mut state = shared.lock().unwrap();
        let mut prefs = state.preferences.clone();
        prefs.vscode_metrics = false;
        state.preferences(prefs).unwrap();
        assert_ne!(state.receiver.token, token);
    }
    for _ in 0..50 {
        if !shared.lock().unwrap().receiver_running {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!shared.lock().unwrap().receiver_running);
    drop(shared);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn historical_json_preview_is_content_stripped_and_fingerprinted() {
    use tokenotch_platform::import::preview;
    let root = std::env::temp_dir().join(format!("tokenotch-import-{}", random_id().unwrap()));
    let store = Store::open(root.clone()).unwrap();
    let path = store.path("synthetic.json").unwrap();
    std::fs::write(&path, payload(now_ms() - 30.0 * 86_400_000.0)).unwrap();
    let imported = preview(path.clone()).unwrap();
    assert_eq!(imported.events.len(), 1);
    assert!(!serde_json::to_string(&imported.events)
        .unwrap()
        .contains("DO NOT PERSIST"));
    imported.verify().unwrap();
    std::fs::write(path, b"changed").unwrap();
    assert!(imported.verify().is_err());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn completed_span_jsonl_preserves_reported_origin_and_rejects_transcripts() {
    let root =
        std::env::temp_dir().join(format!("tokenotch-jsonl-import-{}", random_id().unwrap()));
    let store = Store::open(root.clone()).unwrap();
    let file = store.path("export.jsonl").unwrap();
    let record = json!({
        "name":"completed","events":[],"status":{"code":0},
        "_spanContext":{"traceId":"11111111111111111111111111111111","spanId":"2222222222222222"},
        "startTime":[1700000000,0],"endTime":[1700000001,0],
        "resource":{"_rawAttributes":[["service.name","copilot-chat"]],"_asyncAttributesPending":false},
        "attributes":{"gen_ai.operation.name":"chat","gen_ai.provider.name":"github",
            "gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":20,
            "prompt":"SYNTHETIC CONTENT MUST NOT SURVIVE"}
    });
    std::fs::write(&file, serde_json::to_vec(&record).unwrap()).unwrap();
    let imported = tokenotch_platform::import::preview(file.clone()).unwrap();
    assert_eq!(imported.events.len(), 1);
    assert_eq!(
        imported.events[0].usage_source(),
        tokenotch_core::hook::UsageSource::VscodeLocal
    );
    std::fs::write(
        &file,
        br#"{"role":"user","content":"not a telemetry export"}"#,
    )
    .unwrap();
    assert!(tokenotch_platform::import::preview(file).is_err());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn imports_require_agent_host_provenance_for_github_copilot_in_every_json_format() {
    let root = std::env::temp_dir().join(format!("tokenotch-provenance-{}", random_id().unwrap()));
    let store = Store::open(root.clone()).unwrap();
    let path = store.path("export.json").unwrap();
    for namespace in [None, Some("copilot.cli"), Some("vscode.agent-host")] {
        let mut attrs = json!({"service.name": "github-copilot"});
        let mut wire = json!([{"key":"service.name","value":{"stringValue":"github-copilot"}}]);
        if let Some(namespace) = namespace {
            attrs["service.namespace"] = json!(namespace);
            wire.as_array_mut()
                .unwrap()
                .push(json!({"key":"service.namespace","value":{"stringValue":namespace}}));
        }
        let mut otlp: serde_json::Value = serde_json::from_slice(&payload(now_ms())).unwrap();
        otlp["resourceSpans"][0]["resource"]["attributes"] = wire;
        let mut sdk = json!({
            "name":"completed","events":[],"status":{"code":0},
            "_spanContext":{"traceId":"11111111111111111111111111111111","spanId":"2222222222222222"},
            "startTime":[1700000000,0],"endTime":[1700000001,0],
            "resource":{"attributes":attrs},
            "attributes":{"gen_ai.operation.name":"chat","gen_ai.provider.name":"github",
                "gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":20}
        });
        let mut records = vec![otlp, sdk.clone()];
        let raw: Vec<_> = attrs
            .as_object()
            .unwrap()
            .iter()
            .map(|(key, value)| json!([key, value]))
            .collect();
        sdk.as_object_mut().unwrap().remove("resource");
        sdk["_resource"] = json!({"_rawAttributes":raw,"_asyncAttributesPending":false});
        records.push(sdk.clone());
        sdk.as_object_mut().unwrap().remove("_spanContext");
        sdk.as_object_mut().unwrap().remove("_resource");
        sdk["traceId"] = json!("11111111111111111111111111111111");
        sdk["spanId"] = json!("2222222222222222");
        sdk["startTime"] = json!(1700000000000_u64);
        sdk["endTime"] = json!(1700000001000_u64);
        sdk["attributes"]
            .as_object_mut()
            .unwrap()
            .extend(attrs.as_object().unwrap().clone());
        records.push(sdk);
        for record in records {
            std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
            let result = tokenotch_platform::import::preview(path.clone());
            if namespace == Some("vscode.agent-host") {
                let imported = result.unwrap();
                assert_eq!(imported.events.len(), 1);
                assert_eq!(
                    imported.events[0].usage_source(),
                    tokenotch_core::hook::UsageSource::VscodeCopilot
                );
                assert_eq!(imported.events[0].tokens.as_ref().unwrap().input, 100);
            } else {
                assert!(result.err().unwrap().contains("No source was inferred"));
            }
        }
    }
    std::fs::remove_dir_all(root).unwrap();
}

use serde_json::{json, Value};
use std::io::{BufRead, Read, Write};

fn main() {
    assert!(std::env::var_os("GITHUB_TOKEN").is_none());
    assert!(std::env::var_os("COPILOT_GITHUB_TOKEN").is_none());
    assert!(std::env::var_os("OTEL_EXPORTER_OTLP_ENDPOINT").is_none());
    assert!(std::env::var_os("COPILOT_HOME").is_some());
    if std::env::args().any(|value| value == "login") {
        return;
    }
    let mut stdin = std::io::stdin().lock();
    loop {
        let mut header = String::new();
        if stdin.read_line(&mut header).unwrap() == 0 {
            return;
        }
        let length: usize = header
            .strip_prefix("Content-Length: ")
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let mut separator = String::new();
        stdin.read_line(&mut separator).unwrap();
        assert_eq!(separator, "\r\n");
        let mut bytes = vec![0; length];
        stdin.read_exact(&mut bytes).unwrap();
        let request: Value = serde_json::from_slice(&bytes).unwrap();
        let mode = std::fs::read_to_string(
            std::path::PathBuf::from(std::env::var_os("COPILOT_HOME").unwrap())
                .join("fixture-mode"),
        )
        .unwrap_or_else(|error| {
            assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
            String::new()
        });
        let result = match request["method"].as_str().unwrap() {
            "status.get" => json!({"version":"fixture","protocolVersion":3}),
            "auth.getStatus" => {
                if mode == "signedOut" {
                    json!({"isAuthenticated":false})
                } else {
                    json!({"isAuthenticated":true,"login":if mode=="otherAccount" {"other-user"} else {"synthetic-user"},"copilotPlan":"fixture"})
                }
            }
            "account.getQuota" => {
                json!({"quotaSnapshots":{"premium_interactions":{"isUnlimitedEntitlement":false,
                "entitlementRequests":300,"usedRequests":75,"remainingPercentage":75,"resetDate":"2099-01-01T00:00:00Z"}}})
            }
            _ => panic!("An account-only client must never create a session or inference request."),
        };
        let response = serde_json::to_vec(
            &if request["method"] == "account.getQuota" && ["quotaDenied","otherAccount"].contains(&mode.as_str()) {
                json!({"jsonrpc":"2.0","id":request["id"],"error":{"code":-32000,"message":"synthetic denied"}})
            } else {
                json!({"jsonrpc":"2.0","id":request["id"],"result":result})
            }
        ).unwrap();
        let mut stdout = std::io::stdout().lock();
        write!(stdout, "Content-Length: {}\r\n\r\n", response.len()).unwrap();
        stdout.write_all(&response).unwrap();
        stdout.flush().unwrap();
    }
}

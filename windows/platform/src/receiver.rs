use crate::{runtime::Shared, storage::Result, transport::now_ms};
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokenotch_core::{hook::UsageSource, otel};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::Semaphore,
    time::timeout,
};

pub async fn start(shared: Shared) -> Result<u16> {
    let requested = {
        let state = shared
            .lock()
            .map_err(|_| "Collection state is unavailable.")?;
        if !state.preferences.vscode_metrics {
            return Err("VS Code usage collection is off.".into());
        }
        if state.receiver_running {
            return Ok(state.receiver.port);
        }
        state.receiver.port
    };
    let listener = TcpListener::bind(("127.0.0.1",requested)).await
        .map_err(|_|"The private telemetry port is unavailable. Close the conflicting listener or repair VS Code setup.")?;
    let port = listener
        .local_addr()
        .map_err(|_| "Telemetry address unavailable.")?
        .port();
    {
        let mut state = shared
            .lock()
            .map_err(|_| "Collection state is unavailable.")?;
        state.receiver.port = port;
        state.store.save("receiver.json", &state.receiver)?;
        state.receiver_running = true;
        if let Err(message) = state.checkpoint(now_ms(), false) {
            state.receiver_running = false;
            return Err(message);
        }
    }
    tokio::spawn(async move {
        let slots = Arc::new(Semaphore::new(8));
        loop {
            let enabled = shared.lock().is_ok_and(|s| s.preferences.vscode_metrics);
            if !enabled {
                break;
            }
            match timeout(Duration::from_secs(1), listener.accept()).await {
                Err(_) => continue,
                Ok(Err(_)) => {
                    crate::runtime::warn(&shared, "The telemetry listener stopped unexpectedly.");
                    break;
                }
                Ok(Ok((mut stream, _))) => {
                    let Ok(permit) = slots.clone().try_acquire_owned() else {
                        let _ = stream.write_all(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                        crate::runtime::collection_gap(
                            &shared,
                            &[UsageSource::VscodeLocal, UsageSource::VscodeCopilot],
                            "Telemetry receiver capacity exceeded; some calls may be missing.",
                        );
                        continue;
                    };
                    let state = shared.clone();
                    tokio::spawn(async move {
                        let _permit = permit;
                        let result =
                            timeout(Duration::from_secs(5), handle(&mut stream, &state)).await;
                        let (status, message) = match result {
                            Ok(Ok(())) => ("200 OK", None),
                            Ok(Err(message)) => ("400 Bad Request", Some(message)),
                            Err(_) => (
                                "408 Request Timeout",
                                Some("Telemetry request exceeded its deadline.".into()),
                            ),
                        };
                        if let Some(message) = message {
                            crate::runtime::warn(&state, &message);
                        }
                        let _ = timeout(
                            Duration::from_secs(1),
                            stream.write_all(
                                format!(
                            "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                                .as_bytes(),
                            ),
                        )
                        .await;
                    });
                }
            }
        }
        if let Ok(mut state) = shared.lock() {
            state.receiver_running = false;
            if let Err(message) = state.checkpoint(now_ms(), true) {
                state.warning = Some(message);
            }
        }
    });
    Ok(port)
}

async fn line(stream: &mut TcpStream, max: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    loop {
        bytes.push(
            stream
                .read_u8()
                .await
                .map_err(|_| "Incomplete telemetry request.")?,
        );
        if bytes.ends_with(b"\r\n") {
            bytes.truncate(bytes.len() - 2);
            return Ok(bytes);
        }
        if bytes.len() > max {
            return Err("Telemetry header exceeds its size limit.".into());
        }
    }
}

pub async fn body(stream: &mut TcpStream, headers: &BTreeMap<String, String>) -> Result<Vec<u8>> {
    if headers.contains_key("content-encoding") {
        return Err("Compressed telemetry is unsupported; use uncompressed HTTP/JSON.".into());
    }
    match (
        headers.get("content-length"),
        headers.get("transfer-encoding"),
    ) {
        (Some(length), None) => {
            let length = length
                .parse::<usize>()
                .ok()
                .filter(|v| *v <= otel::BODY_LIMIT)
                .ok_or("Telemetry body exceeds its size limit.")?;
            let mut bytes = vec![0; length];
            stream
                .read_exact(&mut bytes)
                .await
                .map_err(|_| "Incomplete telemetry body.")?;
            Ok(bytes)
        }
        (None, Some(encoding)) if encoding.eq_ignore_ascii_case("chunked") => {
            let mut bytes = Vec::new();
            for _ in 0..65_536 {
                let size_line = line(stream, 128).await?;
                let text =
                    std::str::from_utf8(&size_line).map_err(|_| "Invalid telemetry chunk.")?;
                let length =
                    usize::from_str_radix(text.split(';').next().ok_or("Missing chunk size.")?, 16)
                        .map_err(|_| "Invalid telemetry chunk size.")?;
                if length == 0 {
                    if !line(stream, 1024).await?.is_empty() {
                        return Err("Telemetry trailers are unsupported.".into());
                    }
                    return Ok(bytes);
                }
                if length > otel::BODY_LIMIT.saturating_sub(bytes.len()) {
                    return Err("Telemetry body exceeds its size limit.".into());
                }
                let start = bytes.len();
                bytes.resize(start + length, 0);
                stream
                    .read_exact(&mut bytes[start..])
                    .await
                    .map_err(|_| "Incomplete telemetry chunk.")?;
                if !line(stream, 2).await?.is_empty() {
                    return Err("Invalid telemetry chunk ending.".into());
                }
            }
            Err("Too many telemetry chunks.".into())
        }
        _ => Err("Unsupported telemetry HTTP framing.".into()),
    }
}

async fn handle(stream: &mut TcpStream, shared: &Shared) -> Result<()> {
    let request =
        String::from_utf8(line(stream, 4096).await?).map_err(|_| "Invalid telemetry request.")?;
    let parts: Vec<_> = request.split(' ').collect();
    if parts.len() != 3 || parts[0] != "POST" || parts[2] != "HTTP/1.1" {
        return Err("Unsupported telemetry HTTP request.".into());
    }
    let mut headers = BTreeMap::new();
    let mut length = request.len();
    loop {
        let value = line(stream, 16_384).await?;
        length += value.len() + 2;
        if length > 16_384 {
            return Err("Telemetry headers exceed their size limit.".into());
        }
        if value.is_empty() {
            break;
        }
        let text = std::str::from_utf8(&value).map_err(|_| "Invalid telemetry header.")?;
        let (key, value) = text.split_once(':').ok_or("Invalid telemetry header.")?;
        if headers
            .insert(key.to_ascii_lowercase(), value.trim().to_owned())
            .is_some()
        {
            return Err("Duplicate telemetry headers are unsupported.".into());
        }
    }
    if !headers
        .get("content-type")
        .is_some_and(|value| value.split(';').next() == Some("application/json"))
    {
        return Err("Telemetry must use HTTP/JSON.".into());
    }
    // Consume bounded framing before responding, so Windows does not reset a socket
    // with an unread request body and discard the HTTP status.
    let bytes = body(stream, &headers).await?;
    let source = {
        let state = shared
            .lock()
            .map_err(|_| "Collection state is unavailable.")?;
        if !state.preferences.vscode_metrics {
            return Err("Telemetry collection is off.".into());
        }
        let prefix = format!("/{}/", state.receiver.token);
        let route = parts[1]
            .strip_prefix(&prefix)
            .ok_or("Telemetry authentication failed. Repair VS Code setup.")?;
        if [
            "vscodeLocal/v1/metrics",
            "vscodeCopilot/v1/metrics",
            "vscodeLocal/v1/logs",
            "vscodeCopilot/v1/logs",
        ]
        .contains(&route)
        {
            return Ok(());
        }
        match route {
            "vscodeLocal" | "vscodeLocal/v1/traces" => UsageSource::VscodeLocal,
            "vscodeCopilot" | "vscodeCopilot/v1/traces" => UsageSource::VscodeCopilot,
            _ => return Err("Unsupported telemetry route.".into()),
        }
    };
    let root: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| "Invalid telemetry JSON.")?;
    if root.get("resourceMetrics").is_some() || root.get("resourceLogs").is_some() {
        return Ok(());
    }
    let batch = otel::decode(&bytes, source, now_ms()).map_err(|error| error.to_string())?;
    let mut state = shared
        .lock()
        .map_err(|_| "Collection state is unavailable.")?;
    if !state.preferences.vscode_metrics {
        return Err("Telemetry collection is off.".into());
    }
    for event in &batch.events {
        state.observe(event, true)?;
    }
    if batch.rejected > 0 {
        state.coverage_gap(&[source], now_ms())?;
        state.warning = Some("Some telemetry spans were unsupported; usage is partial.".into());
    } else if !batch.events.is_empty() {
        state.warning = None;
    }
    Ok(())
}

use crate::storage::{random_id, Result, Store};
use serde_json::{json, Value};
use std::{fs::OpenOptions, io::Write};
use tokenotch_core::hook::digest;

const FILES: &[&str] = &[
    "vscode-setup-request.json",
    "vscode-settings.receipt.json",
    "vscode-setup-result.json",
];

pub fn execute(store: &Store, bytes: &[u8]) -> Result<Value> {
    if bytes.len() > 65_536 {
        return Err("Private store request is too large.".into());
    }
    let request: Value =
        serde_json::from_slice(bytes).map_err(|_| "Invalid private store request.")?;
    let name = request["name"].as_str().unwrap_or("");
    match request["action"].as_str() {
        Some("check") => {
            store.check()?;
            Ok(json!(true))
        }
        Some("read") if FILES.contains(&name) => {
            let Some(bytes) = store.read(name, 16_384)? else {
                return Ok(Value::Null);
            };
            let info = std::fs::metadata(store.path(name)?)
                .map_err(|_| "Private store metadata unavailable.")?;
            let text = String::from_utf8(bytes).map_err(|_| "Private store data is invalid.")?;
            let mtime = info
                .modified()
                .map_err(|_| "Private store metadata unavailable.")?
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| "Private store timestamp invalid.")?
                .as_millis();
            Ok(json!({"text": text, "stat": {"mtimeMs": mtime as u64}, "digest": digest(&text)}))
        }
        Some("write") if FILES[1..].contains(&name) => {
            let value = request.get("value").ok_or("Missing private store value.")?;
            let encoded =
                serde_json::to_vec(value).map_err(|_| "Private store value is invalid.")?;
            if encoded.len() > 16_384 {
                return Err("Private store value is too large.".into());
            }
            store.write(name, &encoded)?;
            Ok(json!(true))
        }
        Some("lock") => {
            let token = random_id()?;
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(store.path("vscode-setup.lock")?)
                .map_err(|_| {
                    "Another setup is running, or a stale setup lock requires recovery."
                })?;
            file.write_all(token.as_bytes())
                .and_then(|_| file.sync_all())
                .map_err(|_| "Setup lock could not be saved.")?;
            Ok(json!(token))
        }
        Some("unlock") => {
            let token = request["token"]
                .as_str()
                .ok_or("Missing setup lock token.")?;
            if store.read("vscode-setup.lock", 128)?.as_deref() != Some(token.as_bytes()) {
                return Err("Setup lock changed.".into());
            }
            store.remove("vscode-setup.lock")?;
            Ok(json!(true))
        }
        Some("consume") => {
            let current = store
                .read(FILES[0], 16_384)?
                .ok_or("Setup request is no longer available.")?;
            let text = String::from_utf8(current).map_err(|_| "Invalid setup request.")?;
            if request["digest"].as_str() != Some(&digest(&text)) {
                return Err("Setup request changed during approval.".into());
            }
            store.remove(FILES[0])?;
            Ok(json!(true))
        }
        _ => Err("Unsupported private store operation.".into()),
    }
}

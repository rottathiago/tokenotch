use crate::{
    archive::Aggregate,
    storage::{no_links, Result},
    transport::now_ms,
};
use serde::Serialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::Read,
    path::{Path, PathBuf},
};
use tokenotch_core::{
    hook::{Observation, UsageSource},
    otel,
};

const LIMIT: usize = 64 * 1_048_576;
pub struct Preview {
    pub path: PathBuf,
    pub fingerprint: String,
    pub events: Vec<Observation>,
    pub filtered: usize,
    pub rejected: usize,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub fingerprint: String,
    pub calls: usize,
    pub filtered: usize,
    pub rejected: usize,
    pub first_observed: Option<f64>,
    pub last_observed: Option<f64>,
    pub usage: Aggregate,
}
impl Preview {
    pub fn summary(&self) -> Summary {
        let mut usage = Aggregate::default();
        for event in &self.events {
            if let Some(tokens) = &event.tokens {
                usage.add(tokens);
            }
        }
        Summary {
            fingerprint: self.fingerprint.clone(),
            calls: self.events.len(),
            filtered: self.filtered,
            rejected: self.rejected,
            first_observed: self
                .events
                .iter()
                .map(|e| e.timestamp_unix_ms)
                .min_by(f64::total_cmp),
            last_observed: self
                .events
                .iter()
                .map(|e| e.timestamp_unix_ms)
                .max_by(f64::total_cmp),
            usage,
        }
    }
    pub fn verify(&self) -> Result<()> {
        if snapshot(&self.path)?.fingerprint != self.fingerprint {
            return Err("The selected export changed. Preview it again before importing.".into());
        }
        Ok(())
    }
}
struct ExportSnapshot {
    main: Vec<u8>,
    wal: Option<Vec<u8>>,
    shm: Option<Vec<u8>>,
    fingerprint: String,
}
fn snapshot(path: &Path) -> Result<ExportSnapshot> {
    let main = read(path)?;
    let mut hash = Sha256::new();
    hash.update((main.len() as u64).to_le_bytes());
    hash.update(&main);
    let mut length = main.len();
    let mut sidecars = Vec::new();
    for suffix in ["-wal", "-shm"] {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        let path = PathBuf::from(name);
        let value = if main.starts_with(b"SQLite format 3\0") && path.exists() {
            Some(read(&path)?)
        } else {
            None
        };
        hash.update([u8::from(value.is_some())]);
        if let Some(bytes) = &value {
            length += bytes.len();
            if length > LIMIT {
                return Err("SQLite export and sidecars exceed 64 MiB combined.".into());
            }
            hash.update((bytes.len() as u64).to_le_bytes());
            hash.update(bytes);
        }
        sidecars.push(value);
    }
    let shm = sidecars.pop().ok_or("Export snapshot failed.")?;
    let wal = sidecars.pop().ok_or("Export snapshot failed.")?;
    Ok(ExportSnapshot {
        main,
        wal,
        shm,
        fingerprint: format!("{:x}", hash.finalize()),
    })
}
fn read(path: &Path) -> Result<Vec<u8>> {
    if !path.is_absolute() {
        return Err("Select an absolute export file path.".into());
    }
    no_links(path)?;
    let file = File::open(path).map_err(|_| "The selected export could not be opened.")?;
    let info = file
        .metadata()
        .map_err(|_| "Export metadata could not be read.")?;
    if !info.is_file() || info.len() > LIMIT as u64 {
        return Err("Exports must be regular files no larger than 64 MiB.".into());
    }
    let mut bytes = Vec::new();
    file.take(LIMIT as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Export could not be read.")?;
    if bytes.len() > LIMIT {
        return Err("The export exceeds 64 MiB.".into());
    }
    Ok(bytes)
}
pub fn preview(path: PathBuf) -> Result<Preview> {
    let snapshot = snapshot(&path)?;
    let bytes = snapshot.main;
    let mut result = Preview {
        path,
        fingerprint: snapshot.fingerprint,
        events: Vec::new(),
        filtered: 0,
        rejected: 0,
    };
    let mut examined = 0usize;
    if bytes.starts_with(b"SQLite format 3\0") {
        let image =
            crate::sqlite_import::image(bytes, snapshot.wal.as_deref(), snapshot.shm.as_deref())?;
        crate::sqlite_import::records(&image, |record| {
            read_record(&mut result, record, &mut examined)
        })?;
        return Ok(result);
    }
    if let Ok(root) = serde_json::from_slice::<Value>(&bytes) {
        if let Some(resources) = root["resourceSpans"].as_array() {
            for resource in resources {
                let attrs = &resource["resource"]["attributes"];
                for scope in resource["scopeSpans"]
                    .as_array()
                    .ok_or("Unsupported OTLP export structure.")?
                {
                    for span in scope["spans"].as_array().ok_or("Unsupported OTLP spans.")? {
                        collect(&mut result, span.clone(), attrs.clone(), &mut examined)?;
                    }
                }
            }
            return Ok(result);
        }
    }
    for line in bytes
        .split(|b| *b == b'\n')
        .filter(|line| line.iter().any(|b| !b.is_ascii_whitespace()))
    {
        if line.len() > otel::BODY_LIMIT {
            return Err("An export record exceeds 4 MiB.".into());
        }
        let record: Value =
            serde_json::from_slice(line).map_err(|_| "Unsupported completed-span JSONL export.")?;
        read_record(&mut result, record, &mut examined)?;
    }
    Ok(result)
}
fn read_record(result: &mut Preview, record: Value, examined: &mut usize) -> Result<()> {
    if !record["name"].is_string()
        || !record["events"].is_array()
        || !record["status"]["code"].is_number()
    {
        return Err("Only supported completed-span exports can be imported; transcript and log files are unsupported.".into());
    }
    let attributes = record["attributes"]
        .as_object()
        .ok_or("Missing span attributes.")?;
    let context = record
        .get("_spanContext")
        .or_else(|| record.get("spanContext"));
    let (trace, span, start, end, resource) = if let Some(context) = context {
        let resource = record
            .get("resource")
            .or_else(|| record.get("_resource"))
            .ok_or("Missing producer provenance.")?;
        let attrs = if let Some(values) = resource["attributes"].as_object() {
            values.clone()
        } else {
            if resource["_asyncAttributesPending"] == true {
                return Err("Incomplete producer provenance.".into());
            }
            let pairs = resource["_rawAttributes"]
                .as_array()
                .filter(|v| v.len() <= 512)
                .ok_or("Unsupported producer provenance.")?;
            let mut values = Map::new();
            for pair in pairs {
                let key = pair[0].as_str().ok_or("Invalid resource attribute.")?;
                if !pair[1].is_null() {
                    values.entry(key).or_insert_with(|| pair[1].clone());
                }
            }
            values
        };
        (
            context["traceId"].clone(),
            context["spanId"].clone(),
            nanos(&record["startTime"], true)?,
            nanos(&record["endTime"], true)?,
            wire(&attrs, true)?,
        )
    } else {
        (
            record["traceId"].clone(),
            record["spanId"].clone(),
            nanos(&record["startTime"], false)?,
            nanos(&record["endTime"], false)?,
            wire(attributes, true)?,
        )
    };
    collect(
        result,
        json!({"traceId":trace,"spanId":span,"startTimeUnixNano":start,"endTimeUnixNano":end,
            "attributes":wire(attributes,false)?}),
        resource,
        examined,
    )?;
    Ok(())
}
fn collect(result: &mut Preview, span: Value, resource: Value, examined: &mut usize) -> Result<()> {
    *examined += 1;
    if *examined > 100_000 {
        return Err("Export exceeds 100,000 spans.".into());
    }
    let service = resource
        .as_array()
        .and_then(|attrs| attrs.iter().find(|a| a["key"] == "service.name"))
        .and_then(|a| a["value"]["stringValue"].as_str());
    let namespace = resource
        .as_array()
        .and_then(|attrs| attrs.iter().find(|a| a["key"] == "service.namespace"))
        .and_then(|a| a["value"]["stringValue"].as_str());
    let source =
        match service {
            Some("copilot-chat") => UsageSource::VscodeLocal,
            Some("github-copilot") if namespace == Some("vscode.agent-host") => {
                UsageSource::VscodeCopilot
            }
            _ => return Err(
                "Export does not establish a supported Copilot producer. No source was inferred."
                    .into(),
            ),
        };
    let bytes=serde_json::to_vec(&json!({"resourceSpans":[{"resource":{"attributes":resource},"scopeSpans":[{"spans":[span]}]}]}))
        .map_err(|_|"Export record encoding failed.")?;
    let batch = otel::decode_historical(&bytes, source, now_ms()).map_err(|e| e.to_string())?;
    result.filtered += batch.filtered;
    result.rejected += batch.rejected;
    result.events.extend(batch.events);
    Ok(())
}
fn wire(values: &Map<String, Value>, resource: bool) -> Result<Value> {
    if values.len() > 512 {
        return Err("Too many export attributes.".into());
    }
    let keys = if resource {
        &["service.name", "service.namespace"][..]
    } else {
        &[
            "gen_ai.operation.name",
            "gen_ai.provider.name",
            "gen_ai.agent.name",
            "gen_ai.conversation.id",
            "gen_ai.request.model",
            "gen_ai.response.model",
            "gen_ai.usage.input_tokens",
            "gen_ai.usage.output_tokens",
            "gen_ai.usage.cache_read.input_tokens",
            "gen_ai.usage.cache_creation.input_tokens",
            "copilot_chat.time_to_first_token",
        ][..]
    };
    let mut result = Vec::new();
    for key in keys {
        if let Some(value) = values.get(*key) {
            let encoded = if value.is_string() {
                json!({"stringValue":value})
            } else if value.is_number() {
                json!({"doubleValue":value})
            } else {
                return Err("Unsupported export attribute type.".into());
            };
            result.push(json!({"key":key,"value":encoded}));
        }
    }
    Ok(json!(result))
}
fn nanos(value: &Value, hrtime: bool) -> Result<String> {
    if hrtime {
        let pair = value
            .as_array()
            .filter(|v| v.len() == 2)
            .ok_or("Unsupported span timestamp.")?;
        let seconds = pair[0].as_u64().ok_or("Invalid span timestamp.")?;
        let nanos = pair[1]
            .as_u64()
            .filter(|v| *v < 1_000_000_000)
            .ok_or("Invalid span timestamp.")?;
        Ok(seconds
            .checked_mul(1_000_000_000)
            .and_then(|v| v.checked_add(nanos))
            .ok_or("Span timestamp overflow.")?
            .to_string())
    } else {
        let ms = value
            .as_f64()
            .filter(|v| v.is_finite() && *v > 0.0 && *v < u64::MAX as f64 / 1_000_000.0)
            .ok_or("Invalid span timestamp.")?;
        Ok(((ms * 1_000_000.0).floor() as u64).to_string())
    }
}

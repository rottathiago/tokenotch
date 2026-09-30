use crate::hook::{digest, EventKind, Observation, Source, Tokens, UsageSource};
use serde::Serialize;
use serde_json::{Map, Value};
use std::{collections::BTreeMap, fmt};

pub const BODY_LIMIT: usize = 4 * 1_048_576;
pub const SPAN_LIMIT: usize = 2048;
const ATTRIBUTES: &[&str] = &[
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
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Unsupported,
    Capacity,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Invalid => "Invalid telemetry observation.",
            Self::Unsupported => "Unsupported telemetry source or envelope.",
            Self::Capacity => "Telemetry capacity exceeded.",
        })
    }
}
impl std::error::Error for Error {}

#[derive(Debug, Default, Serialize)]
pub struct Batch {
    pub events: Vec<Observation>,
    pub filtered: usize,
    pub rejected: usize,
    pub unlinked: usize,
}

fn attributes<'a>(
    raw: Option<&'a Value>,
    keys: &[&str],
) -> Result<BTreeMap<&'a str, &'a Value>, Error> {
    let entries = raw.and_then(Value::as_array).ok_or(Error::Invalid)?;
    if entries.len() > 512 {
        return Err(Error::Invalid);
    }
    let mut result = BTreeMap::new();
    for entry in entries {
        let key = entry
            .get("key")
            .and_then(Value::as_str)
            .ok_or(Error::Invalid)?;
        if !keys.contains(&key) {
            continue;
        }
        if result.contains_key(key) {
            return Err(Error::Invalid);
        }
        let values = entry
            .get("value")
            .and_then(Value::as_object)
            .filter(|v| v.len() == 1)
            .ok_or(Error::Invalid)?;
        if (key.starts_with("gen_ai.usage.") || key == "copilot_chat.time_to_first_token")
            && values.contains_key("stringValue")
        {
            return Err(Error::Invalid);
        }
        let value = if let Some(value) = values.get("stringValue") {
            if !value.is_string() {
                return Err(Error::Invalid);
            }
            value
        } else {
            values
                .get("intValue")
                .or_else(|| values.get("doubleValue"))
                .ok_or(Error::Invalid)?
        };
        result.insert(key, value);
    }
    Ok(result)
}

fn count(value: &Value) -> Result<u64, Error> {
    if let Some(text) = value.as_str() {
        if text.is_empty() || text.len() > 10 || !text.bytes().all(|c| c.is_ascii_digit()) {
            return Err(Error::Invalid);
        }
        return text
            .parse::<u64>()
            .ok()
            .filter(|v| *v <= 1_000_000_000)
            .ok_or(Error::Invalid);
    }
    value
        .as_f64()
        .filter(|v| v.is_finite() && v.fract() == 0.0 && (0.0..=1_000_000_000.0).contains(v))
        .map(|v| v as u64)
        .ok_or(Error::Invalid)
}

fn nanos(value: Option<&Value>) -> Result<f64, Error> {
    let text = value.and_then(Value::as_str).ok_or(Error::Invalid)?;
    if text.is_empty() || text.len() > 20 || !text.bytes().all(|c| c.is_ascii_digit()) {
        return Err(Error::Invalid);
    }
    let nanos = text
        .parse::<u64>()
        .ok()
        .filter(|v| *v > 0)
        .ok_or(Error::Invalid)?;
    Ok(nanos as f64 / 1_000_000.0)
}

fn hex(value: Option<&Value>, length: usize) -> Result<&str, Error> {
    value
        .and_then(Value::as_str)
        .filter(|text| {
            text.len() == length
                && text.bytes().any(|c| c != b'0')
                && text
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        })
        .ok_or(Error::Invalid)
}

fn normalize(
    span: &Map<String, Value>,
    attrs: &BTreeMap<&str, &Value>,
    source: UsageSource,
    now: f64,
) -> Result<Observation, Error> {
    let trace = hex(span.get("traceId"), 32)?;
    let span_id = hex(span.get("spanId"), 16)?;
    let start = nanos(span.get("startTimeUnixNano"))?;
    let end = nanos(span.get("endTimeUnixNano"))?;
    if start > end
        || end - start > 86_400_000.0
        || end > now + 30_000.0
        || end <= now - 86_400_000.0
    {
        return Err(Error::Invalid);
    }
    let input = count(
        attrs
            .get("gen_ai.usage.input_tokens")
            .ok_or(Error::Invalid)?,
    )?;
    let output = count(
        attrs
            .get("gen_ai.usage.output_tokens")
            .ok_or(Error::Invalid)?,
    )?;
    let read = attrs
        .get("gen_ai.usage.cache_read.input_tokens")
        .map(|v| count(v))
        .transpose()?;
    let write = attrs
        .get("gen_ai.usage.cache_creation.input_tokens")
        .map(|v| count(v))
        .transpose()?;
    if read.unwrap_or(0) + write.unwrap_or(0) > input {
        return Err(Error::Invalid);
    }
    let model = attrs
        .get("gen_ai.response.model")
        .or_else(|| attrs.get("gen_ai.request.model"))
        .map(|v| v.as_str().map(str::to_owned).ok_or(Error::Invalid))
        .transpose()?;
    let conversation = attrs.get("gen_ai.conversation.id").and_then(|v| v.as_str());
    if conversation.is_some_and(|v| v.is_empty() || v.len() > 512) {
        return Err(Error::Invalid);
    }
    let first = attrs
        .get("copilot_chat.time_to_first_token")
        .map(|v| {
            let number = if let Some(text) = v.as_str() {
                text.parse::<i64>()
                    .map(|v| v as f64)
                    .map_err(|_| Error::Invalid)?
            } else {
                v.as_f64().ok_or(Error::Invalid)?
            };
            if !number.is_finite() || !(0.0..=86_400_000.0).contains(&number) {
                return Err(Error::Invalid);
            }
            Ok(number)
        })
        .transpose()?;
    let unlinked = format!("unlinked:{trace}:{span_id}");
    let event = Observation {
        version: 4,
        source: Source::Vscode,
        kind: EventKind::Usage,
        timestamp_unix_ms: end,
        session: digest(&format!(
            "otel:{}:{}",
            source.wire_name(),
            conversation.unwrap_or(&unlinked)
        )),
        tokens: Some(Tokens {
            call_id: digest(&format!("otel:{}:{trace}:{span_id}", source.wire_name())),
            accounting_version: 1,
            input: input - read.unwrap_or(0) - write.unwrap_or(0),
            output,
            cache_input: read.unwrap_or(0),
            cache_write: write.unwrap_or(0),
            cache_input_reported: Some(read.is_some()),
            cache_write_reported: Some(write.is_some()),
            model,
            duration_ms: Some(end - start),
            time_to_first_token_ms: first,
        }),
        context: None,
        compaction: None,
        metric_id: None,
        metric_source: Some(source),
        metric_session_reported: Some(conversation.is_some()),
    };
    event.validate(now, true).map_err(|_| Error::Invalid)?;
    Ok(event)
}

pub fn decode(input: &[u8], source: UsageSource, now_unix_ms: f64) -> Result<Batch, Error> {
    if input.len() > BODY_LIMIT || source == UsageSource::Cli {
        return Err(Error::Capacity);
    }
    if !now_unix_ms.is_finite() {
        return Err(Error::Invalid);
    }
    let root: Value = serde_json::from_slice(input).map_err(|_| Error::Invalid)?;
    let resources = root
        .get("resourceSpans")
        .and_then(Value::as_array)
        .filter(|values| values.len() <= SPAN_LIMIT)
        .ok_or(Error::Unsupported)?;
    let mut result = Batch::default();
    let mut count = 0;
    for resource in resources {
        let resource_attrs = attributes(
            resource.get("resource").and_then(|v| v.get("attributes")),
            &["service.name", "service.namespace"],
        )?;
        let service = resource_attrs.get("service.name").and_then(|v| v.as_str());
        let scopes = resource
            .get("scopeSpans")
            .and_then(Value::as_array)
            .filter(|v| v.len() <= SPAN_LIMIT)
            .ok_or(Error::Invalid)?;
        for scope in scopes {
            let spans = scope
                .get("spans")
                .and_then(Value::as_array)
                .ok_or(Error::Invalid)?;
            count += spans.len();
            if count > SPAN_LIMIT {
                return Err(Error::Capacity);
            }
            for span in spans {
                let attrs = match attributes(span.get("attributes"), ATTRIBUTES) {
                    Ok(value) => value,
                    Err(_) => {
                        result.rejected += 1;
                        continue;
                    }
                };
                if attrs.get("gen_ai.operation.name").and_then(|v| v.as_str()) != Some("chat")
                    || source == UsageSource::VscodeLocal && service == Some("github-copilot")
                {
                    result.filtered += 1;
                    continue;
                }
                if !matches!(
                    (source, service),
                    (UsageSource::VscodeLocal, Some("copilot-chat"))
                        | (UsageSource::VscodeCopilot, Some("github-copilot"))
                ) {
                    result.rejected += 1;
                    continue;
                }
                if attrs.get("gen_ai.provider.name").and_then(|v| v.as_str()) != Some("github")
                    || attrs
                        .get("gen_ai.agent.name")
                        .and_then(|v| v.as_str())
                        .is_some_and(|agent| {
                            !["copilot", "GitHub Copilot Chat", "copilotcli"].contains(&agent)
                        })
                {
                    result.filtered += 1;
                    continue;
                }
                match span
                    .as_object()
                    .ok_or(Error::Invalid)
                    .and_then(|span| normalize(span, &attrs, source, now_unix_ms))
                {
                    Ok(event) => {
                        if event.metric_session_reported == Some(false) {
                            result.unlinked += 1;
                        }
                        result.events.push(event);
                    }
                    Err(_) => result.rejected += 1,
                }
            }
        }
    }
    Ok(result)
}

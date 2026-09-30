use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::fmt;
use time::{format_description::well_known::Rfc3339, OffsetDateTime};
use unicode_segmentation::UnicodeSegmentation;

pub const INPUT_LIMIT: usize = 65_536;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Cli,
    Vscode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UsageSource {
    Cli,
    VscodeLocal,
    VscodeCopilot,
}

impl UsageSource {
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Cli => "cli",
            Self::VscodeLocal => "vscodeLocal",
            Self::VscodeCopilot => "vscodeCopilot",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EventKind {
    Started,
    Working,
    Stopped,
    Ended,
    Failed,
    Cancelled,
    Usage,
    Context,
    ContextInvalidated,
    Compaction,
    Active,
    Idle,
    InputRequested,
    ApprovalRequested,
    UnrecoverableError,
}

impl EventKind {
    pub fn lifecycle_order(self) -> Option<u8> {
        match self {
            Self::Started => Some(0),
            Self::Working | Self::Active => Some(1),
            Self::Idle => Some(2),
            Self::Stopped => Some(3),
            Self::Ended => Some(4),
            Self::Cancelled => Some(5),
            Self::Failed => Some(6),
            _ => None,
        }
    }

    pub fn reports_work(self) -> bool {
        matches!(self, Self::Working | Self::Active)
    }

    pub fn is_attention(self) -> bool {
        matches!(
            self,
            Self::InputRequested | Self::ApprovalRequested | Self::UnrecoverableError
        )
    }
}

impl TryFrom<&str> for EventKind {
    type Error = Error;
    fn try_from(value: &str) -> Result<Self, Error> {
        match value {
            "started" => Ok(Self::Started),
            "working" => Ok(Self::Working),
            "stopped" => Ok(Self::Stopped),
            "ended" => Ok(Self::Ended),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            "usage" => Ok(Self::Usage),
            "context" => Ok(Self::Context),
            "contextInvalidated" => Ok(Self::ContextInvalidated),
            "compaction" => Ok(Self::Compaction),
            "active" => Ok(Self::Active),
            "idle" => Ok(Self::Idle),
            "inputRequested" => Ok(Self::InputRequested),
            "approvalRequested" => Ok(Self::ApprovalRequested),
            "unrecoverableError" => Ok(Self::UnrecoverableError),
            _ => Err(Error::InvalidEvent),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    InvalidEvent,
    MetricUpgrade,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidEvent => "Unsupported, missing, oversized or expired hook fields.",
            Self::MetricUpgrade => "The token integration needs updating.",
        })
    }
}

impl std::error::Error for Error {}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Observation {
    pub version: u8,
    pub source: Source,
    pub session: String,
    pub kind: EventKind,
    pub timestamp_unix_ms: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<Tokens>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<Context>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compaction: Option<Compaction>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metric_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metric_source: Option<UsageSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metric_session_reported: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Tokens {
    pub call_id: String,
    pub accounting_version: u8,
    pub input: u64,
    pub output: u64,
    pub cache_input: u64,
    pub cache_write: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_input_reported: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_write_reported: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_to_first_token_ms: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Context {
    pub current_tokens: u64,
    pub token_limit: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Compaction {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub success: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub before: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub after: Option<u64>,
}

fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

impl Observation {
    pub fn usage_source(&self) -> UsageSource {
        self.metric_source.unwrap_or(UsageSource::Cli)
    }

    pub fn validate(&self, now_unix_ms: f64, allowing_delayed_metrics: bool) -> Result<(), Error> {
        self.validate_payload()?;
        let age_limit = if allowing_delayed_metrics && self.metric_source.is_some() {
            86_400_000.0
        } else {
            120_000.0
        };
        if !now_unix_ms.is_finite()
            || self.timestamp_unix_ms > now_unix_ms + 30_000.0
            || self.timestamp_unix_ms < now_unix_ms - age_limit
            || allowing_delayed_metrics
                && self.metric_source.is_some()
                && self.timestamp_unix_ms == now_unix_ms - age_limit
        {
            return Err(Error::InvalidEvent);
        }
        Ok(())
    }

    pub fn validate_payload(&self) -> Result<(), Error> {
        if !(1..=4).contains(&self.version)
            || !valid_hash(&self.session)
            || !self.timestamp_unix_ms.is_finite()
            || (self.version == 4) != self.metric_source.is_some()
            || self.metric_source.is_none() && self.metric_session_reported.is_some()
            || self.metric_source.is_some()
                && (self.source != Source::Vscode
                    || self.kind != EventKind::Usage
                    || self.metric_source == Some(UsageSource::Cli))
            || (self.version == 3) != self.kind.is_attention()
            || self.kind.is_attention() && self.source != Source::Cli
            || self.metric_id.as_ref().is_some_and(|id| !valid_hash(id))
        {
            return Err(Error::InvalidEvent);
        }
        match self.kind {
            EventKind::Usage => {
                if self.source != Source::Cli && self.metric_source.is_none()
                    || self.context.is_some()
                    || self.compaction.is_some()
                {
                    return Err(Error::InvalidEvent);
                }
                self.tokens
                    .as_ref()
                    .ok_or(Error::InvalidEvent)?
                    .validate()?;
            }
            EventKind::Context => {
                let value = self.context.as_ref().ok_or(Error::InvalidEvent)?;
                if self.source != Source::Cli
                    || self.tokens.is_some()
                    || self.compaction.is_some()
                    || value.current_tokens > 1_000_000_000
                    || !(1..=1_000_000_000).contains(&value.token_limit)
                {
                    return Err(Error::InvalidEvent);
                }
            }
            EventKind::ContextInvalidated => {
                if self.version != 2
                    || self.source != Source::Cli
                    || self.metric_id.is_none()
                    || self.tokens.is_some()
                    || self.context.is_some()
                    || self.compaction.is_some()
                {
                    return Err(Error::InvalidEvent);
                }
            }
            EventKind::Compaction => {
                let value = self.compaction.as_ref().ok_or(Error::InvalidEvent)?;
                if self.version != 2
                    || self.source != Source::Cli
                    || self.metric_id.is_none()
                    || self.tokens.is_some()
                    || self.context.is_some()
                    || value.success.is_none() && (value.before.is_some() || value.after.is_some())
                    || [value.before, value.after]
                        .into_iter()
                        .flatten()
                        .any(|v| v > 1_000_000_000)
                {
                    return Err(Error::InvalidEvent);
                }
            }
            _ => {
                if self.tokens.is_some()
                    || self.context.is_some()
                    || self.compaction.is_some()
                    || self.metric_id.is_some()
                    || matches!(self.kind, EventKind::Active | EventKind::Idle)
                        && (self.version != 2 || self.source != Source::Cli)
                {
                    return Err(Error::InvalidEvent);
                }
            }
        }
        Ok(())
    }
}

impl Tokens {
    pub fn validate(&self) -> Result<(), Error> {
        if self.accounting_version != 1 {
            return Err(Error::MetricUpgrade);
        }
        if !valid_hash(&self.call_id)
            || [self.input, self.output, self.cache_input, self.cache_write]
                .into_iter()
                .any(|value| value > 1_000_000_000)
            || self.cache_input_reported == Some(false) && self.cache_input != 0
            || self.cache_write_reported == Some(false) && self.cache_write != 0
            || [self.duration_ms, self.time_to_first_token_ms]
                .into_iter()
                .flatten()
                .any(|value| !value.is_finite() || !(0.0..=86_400_000.0).contains(&value))
            || self.model.as_ref().is_some_and(|model| {
                model.is_empty()
                    || model.len() > 128
                    || !model
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || b"-._:/".contains(&c))
            })
        {
            return Err(Error::InvalidEvent);
        }
        Ok(())
    }
}

pub fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

fn text<'a>(fields: &'a Map<String, Value>, name: &str, limit: usize) -> Result<&'a str, Error> {
    fields
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= limit)
        .ok_or(Error::InvalidEvent)
}

fn number(value: &Value, maximum: f64) -> Result<f64, Error> {
    value
        .as_f64()
        .filter(|value| value.is_finite() && (0.0..=maximum).contains(value))
        .ok_or(Error::InvalidEvent)
}

fn event_id(fields: &Map<String, Value>) -> Result<&str, Error> {
    let value = text(fields, "eventId", INPUT_LIMIT)?;
    if value.graphemes(true).count() > 512 {
        return Err(Error::InvalidEvent);
    }
    Ok(value)
}

fn count(value: &Value) -> Result<u64, Error> {
    let number = number(value, 1_000_000_000.0)?;
    if number.fract() != 0.0 {
        return Err(Error::InvalidEvent);
    }
    Ok(number as u64)
}

fn required_count(fields: &Map<String, Value>, name: &str) -> Result<u64, Error> {
    count(fields.get(name).ok_or(Error::InvalidEvent)?)
}

fn optional_count(fields: &Map<String, Value>, name: &str) -> Result<Option<u64>, Error> {
    fields.get(name).map(count).transpose()
}

fn flag(value: &Value) -> Result<bool, Error> {
    value.as_bool().ok_or(Error::InvalidEvent)
}

fn reported(fields: &Map<String, Value>, name: &str) -> Result<Option<bool>, Error> {
    let value = fields
        .get(&format!("{name}Reported"))
        .map(flag)
        .transpose()?;
    if value.is_some_and(|reported| reported != fields.contains_key(name)) {
        return Err(Error::InvalidEvent);
    }
    Ok(value)
}

pub fn normalize(
    input: &[u8],
    source: Source,
    hook: &str,
    now_unix_ms: f64,
) -> Result<Option<Observation>, Error> {
    if input.len() > INPUT_LIMIT || !now_unix_ms.is_finite() {
        return Err(Error::InvalidEvent);
    }
    let fields: Map<String, Value> =
        serde_json::from_slice(input).map_err(|_| Error::InvalidEvent)?;
    if source == Source::Cli
        && !fields.contains_key("sessionId")
        && fields.get("session_id").is_some_and(Value::is_string)
        && fields.get("timestamp").is_some_and(Value::is_string)
    {
        let local = match hook {
            "sessionStart" => Some("SessionStart"),
            "userPromptSubmitted" => Some("UserPromptSubmit"),
            "agentStop" => Some("Stop"),
            _ => None,
        };
        if local.is_some() && fields.get("hook_event_name").and_then(Value::as_str) == local {
            return Ok(None);
        }
    }
    let session = text(
        &fields,
        if source == Source::Cli {
            "sessionId"
        } else {
            "session_id"
        },
        512,
    )?;
    let timestamp_unix_ms = if source == Source::Cli {
        fields
            .get("timestamp")
            .and_then(Value::as_f64)
            .filter(|value| value.is_finite())
            .ok_or(Error::InvalidEvent)?
    } else {
        OffsetDateTime::parse(text(&fields, "timestamp", 128)?, &Rfc3339)
            .map_err(|_| Error::InvalidEvent)?
            .unix_timestamp_nanos() as f64
            / 1_000_000.0
    };
    if timestamp_unix_ms < now_unix_ms - 120_000.0 || timestamp_unix_ms > now_unix_ms + 30_000.0 {
        return Err(Error::InvalidEvent);
    }
    let mut event = Observation {
        version: 1,
        source,
        session: digest(session),
        kind: EventKind::Started,
        timestamp_unix_ms,
        tokens: None,
        context: None,
        compaction: None,
        metric_id: None,
        metric_source: None,
        metric_session_reported: None,
    };
    if source == Source::Vscode {
        if text(&fields, "hook_event_name", 128)? != hook {
            return Err(Error::InvalidEvent);
        }
        event.kind = match hook {
            "SessionStart" => "started",
            "UserPromptSubmit" => "working",
            "Stop" => "stopped",
            _ => return Err(Error::InvalidEvent),
        }
        .try_into()?;
        event.validate(now_unix_ms, false)?;
        return Ok(Some(event));
    }
    event.kind = match hook {
        "sessionStart" => "started",
        "userPromptSubmitted" => "working",
        "agentStop" if fields.get("stopReason").and_then(Value::as_str) == Some("end_turn") => {
            "stopped"
        }
        "sessionEnd" => match text(&fields, "reason", 128)? {
            "error" => "failed",
            "abort" => "cancelled",
            "complete" | "user_exit" | "timeout" => "ended",
            _ => return Err(Error::InvalidEvent),
        },
        "activity" => {
            event.version = 2;
            if flag(fields.get("active").ok_or(Error::InvalidEvent)?)? {
                "active"
            } else {
                "idle"
            }
        }
        "notification" => {
            if text(&fields, "hook_event_name", 128)? != "Notification" {
                return Err(Error::InvalidEvent);
            }
            event.version = 3;
            match text(&fields, "notification_type", 128)? {
                "elicitation_dialog" => "inputRequested",
                "permission_prompt" => "approvalRequested",
                _ => return Ok(None),
            }
        }
        "errorOccurred" => {
            if flag(fields.get("recoverable").ok_or(Error::InvalidEvent)?)? {
                return Ok(None);
            }
            event.version = 3;
            "unrecoverableError"
        }
        "usage" => {
            if fields.get("usageContract").and_then(Value::as_f64) != Some(1.0) {
                return Err(Error::MetricUpgrade);
            }
            let call = event_id(&fields)?;
            let input = required_count(&fields, "inputTokens")?;
            let read = optional_count(&fields, "cacheReadTokens")?.unwrap_or(0);
            let write = optional_count(&fields, "cacheWriteTokens")?.unwrap_or(0);
            if read + write > input {
                return Err(Error::InvalidEvent);
            }
            let model = if fields.contains_key("model") {
                let value = text(&fields, "model", 128)?;
                if !value
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"-._:/".contains(&c))
                {
                    return Err(Error::InvalidEvent);
                }
                Some(value.to_owned())
            } else {
                None
            };
            event.tokens = Some(Tokens {
                call_id: digest(&format!("{session}:{call}")),
                accounting_version: 1,
                input: input - read - write,
                output: required_count(&fields, "outputTokens")?,
                cache_input: read,
                cache_write: write,
                cache_input_reported: reported(&fields, "cacheReadTokens")?,
                cache_write_reported: reported(&fields, "cacheWriteTokens")?,
                model,
                duration_ms: fields
                    .get("durationMs")
                    .map(|v| number(v, 86_400_000.0))
                    .transpose()?,
                time_to_first_token_ms: fields
                    .get("timeToFirstTokenMs")
                    .map(|v| number(v, 86_400_000.0))
                    .transpose()?,
            });
            "usage"
        }
        "context" | "contextInvalidated" => {
            if fields.contains_key("eventId") {
                event.metric_id =
                    Some(digest(&format!("{session}:context:{}", event_id(&fields)?)));
            }
            if hook == "contextInvalidated" {
                if event.metric_id.is_none()
                    || fields.contains_key("currentTokens")
                    || fields.contains_key("tokenLimit")
                {
                    return Err(Error::InvalidEvent);
                }
                event.version = 2;
                "contextInvalidated"
            } else {
                let token_limit = required_count(&fields, "tokenLimit")?;
                if token_limit == 0 {
                    return Err(Error::InvalidEvent);
                }
                event.context = Some(Context {
                    current_tokens: required_count(&fields, "currentTokens")?,
                    token_limit,
                });
                "context"
            }
        }
        "compaction" => {
            let success = match text(&fields, "phase", 128)? {
                "start" if !fields.contains_key("success") => None,
                "complete" => Some(flag(fields.get("success").ok_or(Error::InvalidEvent)?)?),
                _ => return Err(Error::InvalidEvent),
            };
            if success.is_none()
                && (fields.contains_key("beforeTokens") || fields.contains_key("afterTokens"))
            {
                return Err(Error::InvalidEvent);
            }
            event.version = 2;
            event.metric_id = Some(digest(&format!(
                "{session}:compaction:{}",
                event_id(&fields)?
            )));
            event.compaction = Some(Compaction {
                success,
                before: optional_count(&fields, "beforeTokens")?,
                after: optional_count(&fields, "afterTokens")?,
            });
            "compaction"
        }
        _ => return Err(Error::InvalidEvent),
    }
    .try_into()?;
    event.validate(now_unix_ms, false)?;
    Ok(Some(event))
}

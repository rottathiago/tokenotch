use crate::hook::{Context, Error, EventKind, Observation, Source, Tokens, UsageSource};
use serde::Serialize;
use std::collections::BTreeMap;

const DAY_MS: f64 = 86_400_000.0;
const SESSION_LIMIT: usize = 100;
const CALL_LIMIT: usize = 4096;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub source: Source,
    pub session: String,
    pub kind: EventKind,
    pub observed_at_unix_ms: f64,
    pub work_started_at_unix_ms: Option<f64>,
}

impl Session {
    pub fn is_fresh(&self, now: f64) -> bool {
        let limit = if matches!(self.kind, EventKind::Active | EventKind::Idle) {
            90_000.0
        } else {
            300_000.0
        };
        now.is_finite() && now - self.observed_at_unix_ms <= limit
    }

    pub fn is_working(&self, now: f64) -> bool {
        self.kind.reports_work() && self.is_fresh(now)
    }

    pub fn label(&self, now: f64) -> &'static str {
        if matches!(
            self.kind,
            EventKind::Started | EventKind::Working | EventKind::Active | EventKind::Idle
        ) && !self.is_fresh(now)
        {
            return "No recent activity updates";
        }
        match self.kind {
            EventKind::Started => "Session observed",
            EventKind::Working => "Working (last reported)",
            EventKind::Active => "Working (live)",
            EventKind::Idle => "Idle (live)",
            EventKind::Stopped => "Execution stopped",
            EventKind::Ended => "Session ended",
            EventKind::Failed => "Session ended with an error",
            EventKind::Cancelled => "Session cancelled",
            _ => "Activity unavailable",
        }
    }
}

#[derive(Default)]
pub struct ActivityState {
    sessions: BTreeMap<(Source, String), Session>,
}

impl ActivityState {
    pub fn sessions(&self) -> impl Iterator<Item = &Session> {
        self.sessions.values()
    }

    pub fn expire(&mut self, now: f64) -> Result<(), Error> {
        if !now.is_finite() {
            return Err(Error::InvalidEvent);
        }
        self.sessions
            .retain(|_, session| now - session.observed_at_unix_ms < DAY_MS);
        Ok(())
    }

    pub fn remove(&mut self, source: Source) {
        self.sessions.retain(|_, session| session.source != source);
    }

    pub fn accept(&mut self, event: &Observation, now: f64) -> Result<bool, Error> {
        event.validate(now, false)?;
        let order = event.kind.lifecycle_order().ok_or(Error::InvalidEvent)?;
        let key = (event.source, event.session.clone());
        let previous = self.sessions.get(&key);
        if let Some(previous) = previous {
            if previous.observed_at_unix_ms > event.timestamp_unix_ms
                || previous.observed_at_unix_ms == event.timestamp_unix_ms
                    && previous.kind.lifecycle_order().ok_or(Error::InvalidEvent)? >= order
                || event.kind == EventKind::Idle
                    && matches!(
                        previous.kind,
                        EventKind::Ended | EventKind::Cancelled | EventKind::Failed
                    )
            {
                return Ok(false);
            }
        }
        let work_started_at_unix_ms = if event.kind == EventKind::Working
            || event.kind == EventKind::Active
                && !previous.is_some_and(|value| value.kind.reports_work())
        {
            Some(event.timestamp_unix_ms)
        } else {
            previous.and_then(|value| value.work_started_at_unix_ms)
        };
        self.expire(now)?;
        self.sessions.insert(
            key,
            Session {
                source: event.source,
                session: event.session.clone(),
                kind: event.kind,
                observed_at_unix_ms: event.timestamp_unix_ms,
                work_started_at_unix_ms,
            },
        );
        if self.sessions.len() > SESSION_LIMIT {
            if let Some(oldest) = self
                .sessions
                .iter()
                .min_by(|a, b| a.1.observed_at_unix_ms.total_cmp(&b.1.observed_at_unix_ms))
                .map(|(key, _)| key.clone())
            {
                self.sessions.remove(&oldest);
            }
        }
        Ok(true)
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextReading {
    pub context: Option<Context>,
    pub observed_at_unix_ms: f64,
}

impl ContextReading {
    pub fn is_stale(&self, now: f64) -> bool {
        !now.is_finite() || now - self.observed_at_unix_ms > 300_000.0
    }
}

#[derive(Debug, Clone)]
struct Sample {
    session: String,
    source: UsageSource,
    date: f64,
    tokens: Tokens,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Totals {
    pub input: u64,
    pub output: u64,
    pub cache_input: u64,
    pub cache_write: u64,
    pub calls: u64,
    pub cache_reported_calls: u64,
    pub cache_unreported_calls: u64,
    pub write_reported_calls: u64,
    pub write_unreported_calls: u64,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TotalsView {
    pub total: String,
    pub input: String,
    pub output: String,
    pub cache_input: String,
    pub cache_write: String,
    pub calls: String,
    pub cache_reported_calls: String,
    pub cache_unreported_calls: String,
    pub write_reported_calls: String,
    pub write_unreported_calls: String,
}

impl Totals {
    pub fn view(&self) -> TotalsView {
        TotalsView {
            total: (u128::from(self.input)
                + u128::from(self.output)
                + u128::from(self.cache_input)
                + u128::from(self.cache_write))
            .to_string(),
            input: self.input.to_string(),
            output: self.output.to_string(),
            cache_input: self.cache_input.to_string(),
            cache_write: self.cache_write.to_string(),
            calls: self.calls.to_string(),
            cache_reported_calls: self.cache_reported_calls.to_string(),
            cache_unreported_calls: self.cache_unreported_calls.to_string(),
            write_reported_calls: self.write_reported_calls.to_string(),
            write_unreported_calls: self.write_unreported_calls.to_string(),
        }
    }

    fn add(&mut self, tokens: &Tokens) {
        // Each ledger has at most 4096 calls and each token category is capped at 1e9.
        self.input += tokens.input;
        self.output += tokens.output;
        self.cache_input += tokens.cache_input;
        self.cache_write += tokens.cache_write;
        self.calls += 1;
        self.cache_reported_calls += u64::from(tokens.cache_input_reported == Some(true));
        self.cache_unreported_calls += u64::from(tokens.cache_input_reported == Some(false));
        self.write_reported_calls += u64::from(tokens.cache_write_reported == Some(true));
        self.write_unreported_calls += u64::from(tokens.cache_write_reported == Some(false));
    }
}

#[derive(Default)]
pub struct TokenLedger {
    samples: BTreeMap<String, Sample>,
    contexts: BTreeMap<String, ContextReading>,
    pub last_discarded_at_unix_ms: Option<f64>,
}

impl TokenLedger {
    pub fn context(&self, session: &str) -> Option<&ContextReading> {
        self.contexts.get(session)
    }
    pub fn sample_count(&self) -> usize {
        self.samples.len()
    }
    pub fn context_count(&self) -> usize {
        self.contexts.len()
    }

    pub fn expire(&mut self, now: f64) -> Result<(), Error> {
        if !now.is_finite() {
            return Err(Error::InvalidEvent);
        }
        self.samples.retain(|_, value| now - value.date < DAY_MS);
        self.contexts
            .retain(|_, value| now - value.observed_at_unix_ms < DAY_MS);
        if self
            .last_discarded_at_unix_ms
            .is_some_and(|date| now - date >= DAY_MS)
        {
            self.last_discarded_at_unix_ms = None;
        }
        Ok(())
    }

    pub fn remove(&mut self, source: UsageSource) {
        self.samples.retain(|_, value| value.source != source);
        if source == UsageSource::Cli {
            self.contexts.clear();
        }
    }

    pub fn observe(
        &mut self,
        event: &Observation,
        now: f64,
        allowing_delayed_metrics: bool,
    ) -> Result<bool, Error> {
        event.validate(now, allowing_delayed_metrics)?;
        if !matches!(
            event.kind,
            EventKind::Usage | EventKind::Context | EventKind::ContextInvalidated
        ) {
            return Err(Error::InvalidEvent);
        }
        self.expire(now)?;
        if matches!(
            event.kind,
            EventKind::Context | EventKind::ContextInvalidated
        ) {
            if self
                .contexts
                .get(&event.session)
                .is_some_and(|value| value.observed_at_unix_ms >= event.timestamp_unix_ms)
            {
                return Ok(false);
            }
            self.contexts.insert(
                event.session.clone(),
                ContextReading {
                    context: event.context.clone(),
                    observed_at_unix_ms: event.timestamp_unix_ms,
                },
            );
            if self.contexts.len() > SESSION_LIMIT {
                if let Some(oldest) = self
                    .contexts
                    .iter()
                    .min_by(|a, b| a.1.observed_at_unix_ms.total_cmp(&b.1.observed_at_unix_ms))
                    .map(|(key, _)| key.clone())
                {
                    self.contexts.remove(&oldest);
                }
            }
            return Ok(true);
        }
        let tokens = event.tokens.as_ref().ok_or(Error::InvalidEvent)?;
        if self.samples.contains_key(&tokens.call_id) {
            return Ok(false);
        }
        self.samples.insert(
            tokens.call_id.clone(),
            Sample {
                session: event.session.clone(),
                source: event.usage_source(),
                date: event.timestamp_unix_ms,
                tokens: tokens.clone(),
            },
        );
        if self.samples.len() > CALL_LIMIT {
            if let Some((key, date)) = self
                .samples
                .iter()
                .min_by(|a, b| a.1.date.total_cmp(&b.1.date))
                .map(|(key, value)| (key.clone(), value.date))
            {
                self.last_discarded_at_unix_ms = Some(
                    self.last_discarded_at_unix_ms
                        .map_or(date, |previous| previous.max(date)),
                );
                self.samples.remove(&key);
            }
        }
        Ok(true)
    }

    pub fn totals(&self, source: Option<UsageSource>) -> Option<Totals> {
        Self::sum(
            self.samples
                .values()
                .filter(|value| source.is_none_or(|source| source == value.source)),
        )
    }

    pub fn between(
        &self,
        start_unix_ms: f64,
        end_unix_ms: f64,
        source: Option<UsageSource>,
    ) -> Result<Option<Totals>, Error> {
        if !start_unix_ms.is_finite() || !end_unix_ms.is_finite() || start_unix_ms > end_unix_ms {
            return Err(Error::InvalidEvent);
        }
        Ok(Self::sum(self.samples.values().filter(|value| {
            value.date >= start_unix_ms
                && value.date <= end_unix_ms
                && source.is_none_or(|source| source == value.source)
        })))
    }

    pub fn by_model(&self, source: Option<UsageSource>) -> BTreeMap<Option<String>, Totals> {
        let mut groups = BTreeMap::<Option<String>, Totals>::new();
        for sample in self
            .samples
            .values()
            .filter(|value| source.is_none_or(|source| source == value.source))
        {
            groups
                .entry(sample.tokens.model.clone())
                .or_default()
                .add(&sample.tokens);
        }
        groups
    }

    pub fn by_session(&self, source: UsageSource, session: &str) -> Option<Totals> {
        Self::sum(
            self.samples
                .values()
                .filter(|value| value.source == source && value.session == session),
        )
    }

    fn sum<'a>(values: impl Iterator<Item = &'a Sample>) -> Option<Totals> {
        let mut totals = Totals::default();
        for value in values {
            totals.add(&value.tokens);
        }
        (totals.calls > 0).then_some(totals)
    }
}

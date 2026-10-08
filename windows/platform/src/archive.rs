use crate::{
    calendar::{self, date, Interval},
    preferences::Preferences,
    storage::{random_id, Result, Store},
};
use chrono::{NaiveDate, Offset};
use chrono_tz::Tz;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use tokenotch_core::hook::{digest, EventKind, Observation, Tokens, UsageSource};

fn db_error(_: rusqlite::Error) -> String {
    "Local archive could not be read or written. Recording is paused; saved data was preserved."
        .into()
}

#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Aggregate {
    pub input: u64,
    pub output: u64,
    pub cache_input: u64,
    pub cache_write: u64,
    pub calls: u64,
    pub cache_reported_calls: u64,
    pub cache_unreported_calls: u64,
    pub write_reported_calls: u64,
    pub write_unreported_calls: u64,
    pub duration_ms: f64,
    pub duration_samples: u64,
    pub first_token_ms: f64,
    pub first_token_samples: u64,
}
impl Aggregate {
    pub fn combine(&mut self, other: &Self) -> Result<()> {
        macro_rules! add {
            ($($field:ident),+) => { $(self.$field = self.$field.checked_add(other.$field)
                .ok_or("Saved usage totals exceed the supported range.")?;)+ };
        }
        add!(
            input,
            output,
            cache_input,
            cache_write,
            calls,
            cache_reported_calls,
            cache_unreported_calls,
            write_reported_calls,
            write_unreported_calls,
            duration_samples,
            first_token_samples
        );
        self.duration_ms += other.duration_ms;
        self.first_token_ms += other.first_token_ms;
        if !self.duration_ms.is_finite() || !self.first_token_ms.is_finite() {
            return Err("Saved response-time totals exceed the supported range.".into());
        }
        Ok(())
    }

    pub fn add(&mut self, tokens: &Tokens) {
        self.input += tokens.input;
        self.output += tokens.output;
        self.cache_input += tokens.cache_input;
        self.cache_write += tokens.cache_write;
        self.calls += 1;
        self.cache_reported_calls += u64::from(tokens.cache_input_reported == Some(true));
        self.cache_unreported_calls += u64::from(tokens.cache_input_reported == Some(false));
        self.write_reported_calls += u64::from(tokens.cache_write_reported == Some(true));
        self.write_unreported_calls += u64::from(tokens.cache_write_reported == Some(false));
        if let Some(value) = tokens.duration_ms {
            self.duration_ms += value;
            self.duration_samples += 1;
        }
        if let Some(value) = tokens.time_to_first_token_ms {
            self.first_token_ms += value;
            self.first_token_samples += 1;
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRow {
    pub day: String,
    pub source: String,
    pub model: Option<String>,
    pub usage: Aggregate,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HourRow {
    pub hour: String,
    pub source: String,
    pub usage: Aggregate,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineRow {
    pub session: String,
    pub source: String,
    pub timestamp: f64,
    pub event: Observation,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct History {
    pub generation: String,
    pub captured_at: f64,
    pub model_filter: Option<String>,
    pub row_count: usize,
    pub totals: Vec<HistoryRow>,
    pub time_zone: String,
    pub started_at: Option<f64>,
    pub coverage_began: Option<f64>,
    pub calendar: Vec<ReportingDay>,
    pub coverage: Vec<CoverageRow>,
    pub hourly_coverage: Vec<CoverageRow>,
    pub source_gaps: Vec<CoverageGap>,
    pub days: Vec<HistoryRow>,
    pub hours: Vec<HourRow>,
    pub gaps: Vec<(f64, f64)>,
    pub compactions: Vec<(String, i64, i64)>,
    pub context_peaks: Vec<(String, f64)>,
    pub truncated: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineStatus {
    pub generation: String,
    pub captured_at: f64,
    pub retention_days: u32,
    pub cutoff: f64,
    pub recording: bool,
    pub interrupted: bool,
    pub pruned: bool,
    pub legacy: bool,
}
#[derive(Serialize)]
pub struct TimelineSession {
    pub session: String,
    pub sources: Vec<String>,
    pub first: f64,
    pub last: f64,
    pub count: i64,
    pub truncated: bool,
}
#[derive(Serialize)]
pub struct TimelineList {
    pub status: TimelineStatus,
    pub sessions: Vec<TimelineSession>,
}
#[derive(Serialize)]
pub struct TimelineDetail {
    pub status: TimelineStatus,
    pub session: String,
    pub truncated: bool,
    pub events: Vec<TimelineRow>,
}

#[derive(Serialize)]
pub struct ReportingDay {
    pub day: String,
    #[serde(flatten)]
    pub interval: Interval,
    pub hours: Vec<Interval>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoverageRow {
    pub bucket: String,
    pub source: String,
    pub recording_seconds: f64,
}
#[derive(Serialize)]
pub struct CoverageGap {
    pub source: String,
    pub start: f64,
    pub end: f64,
}

pub struct Archive {
    db: Connection,
    zone: Tz,
    history_key: String,
    timeline_key: String,
    revision: u64,
}

impl Archive {
    pub fn open(store: &Store) -> Result<Self> {
        for name in [
            "usage.sqlite",
            "usage.sqlite-journal",
            "usage.sqlite-wal",
            "usage.sqlite-shm",
        ] {
            let path = store.path(name)?;
            if path.exists() {
                #[cfg(windows)]
                crate::security::check_path(&path)?;
            }
        }
        let db = Connection::open(store.path("usage.sqlite")?).map_err(db_error)?;
        db.busy_timeout(std::time::Duration::from_secs(2))
            .map_err(db_error)?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS daily (day TEXT, source TEXT, model TEXT, usage TEXT NOT NULL, PRIMARY KEY(day,source,model));
            CREATE TABLE IF NOT EXISTS hourly (hour TEXT, source TEXT, usage TEXT NOT NULL, PRIMARY KEY(hour,source));
            CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, source TEXT, time REAL);
            CREATE TABLE IF NOT EXISTS timeline (id TEXT PRIMARY KEY, session TEXT, source TEXT, time REAL, event TEXT);
            CREATE INDEX IF NOT EXISTS timeline_time ON timeline(time);
            CREATE INDEX IF NOT EXISTS timeline_session_time ON timeline(session,time);
            CREATE TABLE IF NOT EXISTS gaps (start REAL, end REAL);
            CREATE TABLE IF NOT EXISTS context (day TEXT PRIMARY KEY, high REAL, successes INTEGER, failures INTEGER);").map_err(db_error)?;
        let schema: Option<String> = db
            .query_row("SELECT value FROM metadata WHERE key='schema'", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(db_error)?;
        if schema
            .as_deref()
            .is_some_and(|value| !["1", "2", "3"].contains(&value))
        {
            return Err("This archive requires a newer Tokenotch version.".into());
        }
        let zone_name = match meta(&db, "zone")? {
            Some(zone) => zone,
            None => iana_time_zone::get_timezone()
                .map_err(|_| "The reporting time zone is unavailable.")?,
        };
        let zone = zone_name
            .parse()
            .map_err(|_| "The saved reporting time zone is unsupported.")?;
        let tx = db.unchecked_transaction().map_err(db_error)?;
        tx.execute_batch("
            CREATE TABLE IF NOT EXISTS coverage (bucket TEXT, source TEXT, seconds REAL NOT NULL, PRIMARY KEY(bucket,source));
            CREATE TABLE IF NOT EXISTS hourly_coverage (bucket TEXT, source TEXT, seconds REAL NOT NULL, PRIMARY KEY(bucket,source));
            CREATE TABLE IF NOT EXISTS coverage_intervals (day TEXT, source TEXT, start REAL, end REAL);
            CREATE INDEX IF NOT EXISTS coverage_lookup ON coverage_intervals(day,source,start,end);
            CREATE TABLE IF NOT EXISTS source_gaps (source TEXT, start REAL, end REAL);
            CREATE INDEX IF NOT EXISTS gap_lookup ON source_gaps(source,start,end);
            CREATE TABLE IF NOT EXISTS timeline_flags (session TEXT PRIMARY KEY, truncated INTEGER NOT NULL);
            CREATE TRIGGER IF NOT EXISTS timeline_removal BEFORE DELETE ON timeline BEGIN
                INSERT OR REPLACE INTO timeline_flags VALUES (OLD.session,1);
                INSERT OR REPLACE INTO metadata VALUES ('timeline-pruned','true');
            END;").map_err(db_error)?;
        if schema.as_deref() == Some("1") {
            migrate_hours(&tx, zone)?;
        }
        if schema.as_deref().is_some_and(|value| value != "3") {
            tx.execute("INSERT OR IGNORE INTO metadata SELECT 'timeline-legacy','true' WHERE EXISTS(SELECT 1 FROM timeline)", []).map_err(db_error)?;
        }
        tx.execute("INSERT OR REPLACE INTO metadata VALUES ('schema','3')", [])
            .map_err(db_error)?;
        tx.commit().map_err(db_error)?;
        let history_key = meta(&db, "history-key")?.unwrap_or(random_id()?);
        let timeline_key = meta(&db, "timeline-key")?.unwrap_or(random_id()?);
        for (key, value) in [
            ("zone", zone_name.as_str()),
            ("history-key", &history_key),
            ("timeline-key", &timeline_key),
        ] {
            db.execute(
                "INSERT OR IGNORE INTO metadata VALUES (?1,?2)",
                params![key, value],
            )
            .map_err(db_error)?;
        }
        Ok(Self {
            db,
            zone,
            history_key,
            timeline_key,
            revision: 0,
        })
    }

    pub fn checkpoint(
        &mut self,
        recording: bool,
        sources: &[UsageSource],
        now: f64,
        discontinuity: bool,
    ) -> Result<()> {
        date(now)?;
        let previous = number_meta(&self.db, "checkpoint")?;
        let was_recording = meta(&self.db, "recording")?.as_deref() == Some("true");
        let previous_sources: Vec<UsageSource> = meta(&self.db, "coverage-sources")?
            .map(|v| {
                serde_json::from_str(&v)
                    .map_err(|_| "Saved coverage sources are invalid.".to_owned())
            })
            .transpose()?
            .unwrap_or_default();
        let started = number_meta(&self.db, "started")?;
        let since = number_meta(&self.db, "recording-since")?;
        let tx = self.db.transaction().map_err(db_error)?;
        if let Some(previous) = previous {
            let continuous = was_recording
                && recording
                && !discontinuity
                && (0.0..=65_000.0).contains(&(now - previous));
            for source in ["cli", "vscodeLocal", "vscodeCopilot", "all"] {
                let available = previous_sources.iter().any(|value| {
                    (source == "all" || value.wire_name() == source) && sources.contains(value)
                });
                if continuous && available {
                    let mut cursor = previous;
                    while cursor < now {
                        let end = calendar::hour(cursor, self.zone)?.end.min(now);
                        record_coverage(&tx, self.zone, source, cursor, end)?;
                        cursor = end;
                    }
                } else if started.is_some() {
                    record_gap(&tx, source, previous.min(now), previous.max(now))?;
                }
            }
        }
        if recording {
            tx.execute(
                "INSERT OR IGNORE INTO metadata VALUES ('started',?1)",
                [now.to_string()],
            )
            .map_err(db_error)?;
            tx.execute(
                "INSERT OR IGNORE INTO metadata VALUES ('coverage-began',?1)",
                [now.to_string()],
            )
            .map_err(db_error)?;
            if !was_recording || discontinuity || since.is_none() {
                tx.execute(
                    "INSERT OR REPLACE INTO metadata VALUES ('recording-since',?1)",
                    [now.to_string()],
                )
                .map_err(db_error)?;
            }
        }
        for (key, value) in [
            ("checkpoint", now.to_string()),
            ("recording", recording.to_string()),
            (
                "coverage-sources",
                serde_json::to_string(sources).map_err(|_| "Coverage encoding failed.")?,
            ),
        ] {
            tx.execute(
                "INSERT OR REPLACE INTO metadata VALUES (?1,?2)",
                params![key, value],
            )
            .map_err(db_error)?;
        }
        tx.commit().map_err(db_error)
    }

    pub fn timeline_checkpoint(
        &mut self,
        enabled: bool,
        sources: &[tokenotch_core::hook::Source],
        now: f64,
        discontinuity: bool,
    ) -> Result<()> {
        date(now)?;
        let previous = number_meta(&self.db, "timeline-checkpoint")?;
        let recording = enabled && !sources.is_empty();
        let old_sources = meta(&self.db, "timeline-sources")?;
        let sources =
            serde_json::to_string(sources).map_err(|_| "Timeline coverage encoding failed.")?;
        let was_recording = meta(&self.db, "timeline-recording")?.as_deref() == Some("true");
        let began = number_meta(&self.db, "timeline-began")?;
        let tx = self.db.transaction().map_err(db_error)?;
        if began.is_some()
            && (discontinuity
                || was_recording != recording
                || old_sources.as_ref() != Some(&sources)
                || previous.is_some_and(|previous| !(0.0..=65_000.0).contains(&(now - previous))))
        {
            tx.execute(
                "INSERT OR REPLACE INTO metadata VALUES ('timeline-interrupted','true')",
                [],
            )
            .map_err(db_error)?;
        }
        if enabled {
            tx.execute(
                "INSERT OR IGNORE INTO metadata VALUES ('timeline-began',?1)",
                [now.to_string()],
            )
            .map_err(db_error)?;
        }
        for (key, value) in [
            ("timeline-checkpoint", now.to_string()),
            ("timeline-recording", recording.to_string()),
            ("timeline-sources", sources),
        ] {
            tx.execute(
                "INSERT OR REPLACE INTO metadata VALUES (?1,?2)",
                params![key, value],
            )
            .map_err(db_error)?;
        }
        tx.commit().map_err(db_error)
    }

    pub fn history_generation(&self) -> String {
        digest(&format!("{}:navigation", self.history_key))
    }
    /// Changes whenever saved usage changes, so open History views know to reload.
    pub fn history_revision(&self) -> u64 {
        self.revision
    }
    pub fn timeline_generation(&self) -> String {
        digest(&format!("{}:navigation", self.timeline_key))
    }
    pub fn timeline_session(&self, source: tokenotch_core::hook::Source, session: &str) -> String {
        digest(&format!("{}:{source:?}:{session}", self.timeline_key))
    }
    pub fn mark_timeline_interruption(&self) -> Result<()> {
        self.db
            .execute(
                "INSERT OR REPLACE INTO metadata VALUES ('timeline-interrupted','true')",
                [],
            )
            .map_err(db_error)?;
        Ok(())
    }

    pub fn record(
        &mut self,
        event: &Observation,
        prefs: &Preferences,
        imported: bool,
    ) -> Result<bool> {
        self.record_batch(std::slice::from_ref(event), prefs, imported)
            .map(|count| count != 0)
    }

    pub fn record_batch(
        &mut self,
        events: &[Observation],
        prefs: &Preferences,
        imported: bool,
    ) -> Result<usize> {
        let tx = self.db.unchecked_transaction().map_err(db_error)?;
        let since = number_meta(&tx, "recording-since")?;
        let mut recorded = 0;
        for event in events {
            recorded += usize::from(self.record_in(&tx, event, prefs, imported, since)?);
        }
        tx.commit().map_err(db_error)?;
        self.revision = self.revision.wrapping_add(recorded as u64);
        Ok(recorded)
    }

    fn record_in(
        &self,
        tx: &rusqlite::Transaction<'_>,
        event: &Observation,
        prefs: &Preferences,
        imported: bool,
        since: Option<f64>,
    ) -> Result<bool> {
        event
            .validate_payload()
            .map_err(|error| error.to_string())?;
        let at = date(event.timestamp_unix_ms)?.with_timezone(&self.zone);
        let day = at.format("%Y-%m-%d").to_string();
        let hour = hour_key(
            calendar::hour(event.timestamp_unix_ms, self.zone)?.start,
            self.zone,
        )?;
        let source = if event.source == tokenotch_core::hook::Source::Vscode
            && event.metric_source.is_none()
        {
            "vscodeLocal"
        } else {
            event.usage_source().wire_name()
        };
        let identity = event
            .tokens
            .as_ref()
            .map(|v| v.call_id.clone())
            .or_else(|| event.metric_id.clone())
            .unwrap_or(format!("{:?}:{}", event.kind, event.timestamp_unix_ms));
        let identity = if event.tokens.is_some() {
            identity
        } else {
            format!("{}:{identity}", event.session)
        };
        let history_id = digest(&format!("{}:{source}:{identity}", self.history_key));
        let timeline_session = self.timeline_session(event.source, &event.session);
        let timeline_id = digest(&format!("{}:{source}:{identity}", self.timeline_key));
        let mut recorded = false;
        if prefs.history
            && (imported || since.is_some_and(|since| event.timestamp_unix_ms >= since))
            && (event.tokens.is_some() || event.context.is_some() || event.compaction.is_some())
        {
            let new = tx
                .execute(
                    "INSERT OR IGNORE INTO receipts VALUES (?1,?2,?3)",
                    params![history_id, source, event.timestamp_unix_ms],
                )
                .map_err(db_error)?
                > 0;
            if new {
                if imported {
                    for selected in [source, "all"] {
                        record_gap(
                            tx,
                            selected,
                            event.timestamp_unix_ms,
                            event.timestamp_unix_ms,
                        )?;
                    }
                }
                if let Some(tokens) = &event.tokens {
                    let requested_model = tokens.model.as_deref().unwrap_or("");
                    let known:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM daily WHERE day=?1 AND source=?2 AND model=?3)",params![day,source,requested_model],|r|r.get(0)).map_err(db_error)?;
                    let count: i64 = tx
                        .query_row(
                            "SELECT COUNT(*) FROM daily WHERE day=?1 AND source=?2",
                            params![day, source],
                            |r| r.get(0),
                        )
                        .map_err(db_error)?;
                    let model = if !known && !requested_model.is_empty() && count >= 100 {
                        "Other models (capacity limit)"
                    } else {
                        requested_model
                    };
                    let mut usage: Aggregate = match tx
                        .query_row(
                            "SELECT usage FROM daily WHERE day=?1 AND source=?2 AND model=?3",
                            params![day, source, model],
                            |r| r.get::<_, String>(0),
                        )
                        .optional()
                        .map_err(db_error)?
                    {
                        Some(value) => serde_json::from_str(&value)
                            .map_err(|_| "Saved daily usage is invalid.")?,
                        None => Aggregate::default(),
                    };
                    usage.add(tokens);
                    tx.execute(
                        "INSERT OR REPLACE INTO daily VALUES (?1,?2,?3,?4)",
                        params![
                            day,
                            source,
                            model,
                            serde_json::to_string(&usage)
                                .map_err(|_| "Daily usage encoding failed.")?
                        ],
                    )
                    .map_err(db_error)?;
                    let mut usage: Aggregate = match tx
                        .query_row(
                            "SELECT usage FROM hourly WHERE hour=?1 AND source=?2",
                            params![hour, source],
                            |r| r.get::<_, String>(0),
                        )
                        .optional()
                        .map_err(db_error)?
                    {
                        Some(value) => serde_json::from_str(&value)
                            .map_err(|_| "Saved hourly usage is invalid.")?,
                        None => Aggregate::default(),
                    };
                    usage.add(tokens);
                    tx.execute(
                        "INSERT OR REPLACE INTO hourly VALUES (?1,?2,?3)",
                        params![
                            hour,
                            source,
                            serde_json::to_string(&usage)
                                .map_err(|_| "Hourly usage encoding failed.")?
                        ],
                    )
                    .map_err(db_error)?;
                }
                if let Some(context) = &event.context {
                    let fraction = context.current_tokens as f64 / context.token_limit as f64;
                    tx.execute("INSERT INTO context VALUES (?1,?2,0,0) ON CONFLICT(day) DO UPDATE SET high=MAX(high,?2)",
                        params![day,fraction]).map_err(db_error)?;
                }
                if let Some(success) = event.compaction.as_ref().and_then(|value| value.success) {
                    tx.execute("INSERT INTO context VALUES (?1,0,?2,?3) ON CONFLICT(day) DO UPDATE SET successes=successes+?2,failures=failures+?3",
                        params![day,u32::from(success),u32::from(!success)]).map_err(db_error)?;
                }
                recorded = true;
            }
        }
        // Live activity polls repeat every 30 seconds; keeping only state changes stops a
        // long idle session from evicting its real work under the per-session timeline cap.
        let repeated_activity = prefs.timelines
            && !imported
            && matches!(event.kind, EventKind::Active | EventKind::Idle)
            && tx
                .query_row(
                    "SELECT event FROM timeline WHERE session=?1 ORDER BY time DESC,rowid DESC LIMIT 1",
                    params![timeline_session],
                    |r| r.get::<_, String>(0),
                )
                .optional()
                .map_err(db_error)?
                .and_then(|json| serde_json::from_str::<Observation>(&json).ok())
                .is_some_and(|last| last.kind == event.kind);
        if prefs.timelines
            && !imported
            && !repeated_activity
            && !event.kind.is_attention()
            && event.kind != EventKind::ContextInvalidated
            && event.metric_session_reported != Some(false)
        {
            let mut saved = event.clone();
            saved.session = timeline_session.clone();
            saved.metric_id = saved
                .metric_id
                .map(|id| digest(&format!("{}:{id}", self.timeline_key)));
            if let Some(tokens) = &mut saved.tokens {
                tokens.call_id = timeline_id.clone();
            }
            let json = serde_json::to_string(&saved).map_err(|_| "Timeline encoding failed.")?;
            tx.execute(
                "INSERT OR IGNORE INTO timeline VALUES (?1,?2,?3,?4,?5)",
                params![
                    timeline_id,
                    timeline_session,
                    source,
                    event.timestamp_unix_ms,
                    json
                ],
            )
            .map_err(db_error)?;
        }
        Ok(recorded)
    }

    pub fn mark_gap(&mut self, sources: &[UsageSource], now: f64) -> Result<()> {
        date(now)?;
        if number_meta(&self.db, "started")?.is_some() {
            let tx = self.db.transaction().map_err(db_error)?;
            for source in sources
                .iter()
                .map(|source| source.wire_name())
                .chain(["all"])
            {
                record_gap(&tx, source, now, now)?;
            }
            tx.commit().map_err(db_error)?;
        }
        Ok(())
    }

    pub fn prune(&self, days: u32, now: f64) -> Result<()> {
        let day = (date(now)?.with_timezone(&self.zone).date_naive() - chrono::Duration::days(6))
            .to_string();
        self.db
            .execute("DELETE FROM hourly WHERE substr(hour,1,10) < ?1", [&day])
            .map_err(db_error)?;
        self.db
            .execute(
                "DELETE FROM hourly_coverage WHERE substr(bucket,1,10) < ?1",
                [&day],
            )
            .map_err(db_error)?;
        self.db
            .execute(
                "DELETE FROM receipts WHERE source='cli' AND time < ?1",
                [now - 86_400_000.0],
            )
            .map_err(db_error)?;
        self.db
            .execute(
                "DELETE FROM timeline WHERE time < ?1",
                [now - f64::from(days) * 86_400_000.0],
            )
            .map_err(db_error)?;
        self.db.execute_batch("DELETE FROM timeline WHERE rowid IN (
            SELECT rowid FROM (SELECT rowid, ROW_NUMBER() OVER(PARTITION BY session ORDER BY time DESC,rowid DESC) n FROM timeline) WHERE n>2000);
            DELETE FROM timeline WHERE session NOT IN (SELECT session FROM timeline GROUP BY session ORDER BY MAX(time) DESC LIMIT 1000);
            DELETE FROM timeline WHERE rowid NOT IN (SELECT rowid FROM timeline ORDER BY time DESC,rowid DESC LIMIT 100000);
            DELETE FROM timeline_flags WHERE session NOT IN (SELECT session FROM timeline);").map_err(db_error)
    }

    pub fn history(&self, start: &str, end: &str) -> Result<History> {
        self.history_filtered(start, end, None)
    }

    pub fn history_filtered(&self, start: &str, end: &str, model: Option<&str>) -> Result<History> {
        if chrono::NaiveDate::parse_from_str(start, "%Y-%m-%d").is_err()
            || chrono::NaiveDate::parse_from_str(end, "%Y-%m-%d").is_err()
            || start > end
        {
            return Err("Choose a valid history date range.".into());
        }
        let first =
            NaiveDate::parse_from_str(start, "%Y-%m-%d").map_err(|_| "Invalid reporting day.")?;
        let last =
            NaiveDate::parse_from_str(end, "%Y-%m-%d").map_err(|_| "Invalid reporting day.")?;
        if (last - first).num_days() > 3660 {
            return Err("Choose a history range of at most ten years.".into());
        }
        let mut calendar = Vec::new();
        for day in first.iter_days().take_while(|day| *day <= last) {
            let interval = calendar::day(day, self.zone)?;
            // Only recent days need hourly chart boundaries.
            let hours = if (last - day).num_days() < 7 {
                calendar::hours(&interval, self.zone)?
            } else {
                Vec::new()
            };
            calendar.push(ReportingDay {
                day: day.to_string(),
                interval,
                hours,
            });
        }
        let mut statement = self.db.prepare("SELECT day,source,model,usage FROM daily WHERE day>=?1 AND day<=?2 ORDER BY day,source,model").map_err(db_error)?;
        let records = statement
            .query_map(params![start, end], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(db_error)?;
        let mut days = Vec::new();
        let mut totals: BTreeMap<(String, String), Aggregate> = BTreeMap::new();
        let mut row_count = 0;
        for record in records {
            let (day, source, name, json) = record.map_err(db_error)?;
            let usage: Aggregate =
                serde_json::from_str(&json).map_err(|_| "Saved usage is invalid.")?;
            totals
                .entry((day.clone(), source.clone()))
                .or_default()
                .combine(&usage)?;
            if model.is_none_or(|model| model == name) {
                row_count += 1;
                if days.len() < 20_000 {
                    days.push(HistoryRow {
                        day,
                        source,
                        model: (!name.is_empty()).then_some(name),
                        usage,
                    });
                }
            }
        }
        let mut statement = self.db.prepare("SELECT hour,source,usage FROM hourly WHERE substr(hour,1,10)>=?1 AND substr(hour,1,10)<=?2 ORDER BY hour").map_err(db_error)?;
        let hours = statement
            .query_map(params![start, end], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })
            .map_err(db_error)?
            .map(|row| {
                let (hour, source, json) = row.map_err(db_error)?;
                Ok(HourRow {
                    hour,
                    source,
                    usage: serde_json::from_str(&json)
                        .map_err(|_| "Saved hourly usage is invalid.")?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let mut statement = self
            .db
            .prepare("SELECT start,end FROM gaps ORDER BY start DESC LIMIT 4096")
            .map_err(db_error)?;
        let gaps = statement
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(db_error)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(db_error)?;
        let mut statement = self
            .db
            .prepare(
                "SELECT day,successes,failures FROM context WHERE day>=?1 AND day<=?2 ORDER BY day",
            )
            .map_err(db_error)?;
        let compactions = statement
            .query_map(params![start, end], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .map_err(db_error)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(db_error)?;
        let mut statement = self
            .db
            .prepare(
                "SELECT day,high FROM context WHERE day>=?1 AND day<=?2 AND high>0 ORDER BY day",
            )
            .map_err(db_error)?;
        let context_peaks = statement
            .query_map(params![start, end], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(db_error)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(db_error)?;
        let mut statement = self.db.prepare("SELECT source,start,end FROM source_gaps WHERE start<=?2 AND end>=?1 ORDER BY start").map_err(db_error)?;
        let low = calendar
            .first()
            .ok_or("Invalid reporting range.")?
            .interval
            .start;
        let high = calendar
            .last()
            .ok_or("Invalid reporting range.")?
            .interval
            .end;
        let source_gaps = statement
            .query_map(params![low, high], |r| {
                Ok(CoverageGap {
                    source: r.get(0)?,
                    start: r.get(1)?,
                    end: r.get(2)?,
                })
            })
            .map_err(db_error)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(db_error)?;
        Ok(History {
            generation: self.history_generation(),
            captured_at: crate::transport::now_ms(),
            model_filter: model.map(str::to_owned),
            row_count,
            totals: totals
                .into_iter()
                .map(|((day, source), usage)| HistoryRow {
                    day,
                    source,
                    model: None,
                    usage,
                })
                .collect(),
            time_zone: self.zone.to_string(),
            started_at: number_meta(&self.db, "started")?,
            coverage_began: number_meta(&self.db, "coverage-began")?,
            coverage: coverage_rows(&self.db, "coverage", start, end)?,
            hourly_coverage: coverage_rows(&self.db, "hourly_coverage", start, end)?,
            source_gaps,
            calendar,
            days,
            hours,
            gaps,
            compactions,
            context_peaks,
            truncated: row_count > 20_000,
        })
    }

    pub fn today(&self, now: f64) -> Result<String> {
        Ok(date(now)?
            .with_timezone(&self.zone)
            .format("%Y-%m-%d")
            .to_string())
    }

    pub fn timeline(&self, session: Option<&str>) -> Result<Vec<TimelineRow>> {
        let mut statement = self.db.prepare("SELECT session,source,time,event FROM timeline WHERE (?1 IS NULL OR session=?1) ORDER BY time DESC LIMIT 2000").map_err(db_error)?;
        let rows = statement
            .query_map([session], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, f64>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })
            .map_err(db_error)?
            .map(|row| {
                let (session, source, timestamp, event) = row.map_err(db_error)?;
                Ok(TimelineRow {
                    session,
                    source,
                    timestamp,
                    event: serde_json::from_str(&event)
                        .map_err(|_| "Saved timeline is invalid.")?,
                })
            })
            .collect();
        rows
    }

    fn timeline_status(&self, days: u32, now: f64) -> Result<TimelineStatus> {
        Ok(TimelineStatus {
            generation: self.timeline_generation(),
            captured_at: now,
            retention_days: days,
            cutoff: now - f64::from(days) * 86_400_000.0,
            recording: meta(&self.db, "timeline-recording")?.as_deref() == Some("true"),
            interrupted: meta(&self.db, "timeline-interrupted")?.as_deref() == Some("true"),
            pruned: meta(&self.db, "timeline-pruned")?.as_deref() == Some("true"),
            legacy: meta(&self.db, "timeline-legacy")?.as_deref() == Some("true"),
        })
    }
    pub fn timeline_sessions(&self, days: u32, now: f64) -> Result<TimelineList> {
        self.prune(days, now)?;
        let mut statement = self.db.prepare("SELECT session,group_concat(DISTINCT source),MIN(time),MAX(time),COUNT(*),
            EXISTS(SELECT 1 FROM timeline_flags f WHERE f.session=timeline.session AND f.truncated=1)
            FROM timeline GROUP BY session ORDER BY MAX(time) DESC,session").map_err(db_error)?;
        let sessions = statement
            .query_map([], |r| {
                Ok(TimelineSession {
                    session: r.get(0)?,
                    sources: r
                        .get::<_, String>(1)?
                        .split(',')
                        .map(str::to_owned)
                        .collect(),
                    first: r.get(2)?,
                    last: r.get(3)?,
                    count: r.get(4)?,
                    truncated: r.get(5)?,
                })
            })
            .map_err(db_error)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(db_error)?;
        Ok(TimelineList {
            status: self.timeline_status(days, now)?,
            sessions,
        })
    }
    pub fn timeline_detail(&self, session: &str, days: u32, now: f64) -> Result<TimelineDetail> {
        self.prune(days, now)?;
        let mut events = self.timeline(Some(session))?;
        if events.is_empty() {
            return Err("This session has no retained timeline. It may have expired, been cleared, or never been recorded; unlinked usage has no session timeline.".into());
        }
        events.reverse();
        let truncated = self
            .db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM timeline_flags WHERE session=?1 AND truncated=1)",
                [session],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        Ok(TimelineDetail {
            status: self.timeline_status(days, now)?,
            session: session.into(),
            truncated,
            events,
        })
    }

    pub fn delete(&mut self, timelines: bool) -> Result<()> {
        let key = random_id()?;
        let tx = self.db.transaction().map_err(db_error)?;
        if timelines {
            tx.execute_batch("DELETE FROM timeline; DELETE FROM timeline_flags;
                DELETE FROM metadata WHERE key IN ('timeline-began','timeline-checkpoint','timeline-recording',
                'timeline-sources','timeline-interrupted','timeline-pruned','timeline-legacy');").map_err(db_error)?;
        } else {
            tx.execute_batch("DELETE FROM daily; DELETE FROM hourly; DELETE FROM receipts; DELETE FROM context; DELETE FROM gaps;
                DELETE FROM coverage; DELETE FROM hourly_coverage; DELETE FROM coverage_intervals; DELETE FROM source_gaps;
                DELETE FROM metadata WHERE key IN ('started','checkpoint','recording','recording-since','coverage-began','coverage-sources');").map_err(db_error)?;
        }
        tx.execute(
            "INSERT OR REPLACE INTO metadata VALUES (?1,?2)",
            params![
                if timelines {
                    "timeline-key"
                } else {
                    "history-key"
                },
                key
            ],
        )
        .map_err(db_error)?;
        tx.commit().map_err(db_error)?;
        self.revision = self.revision.wrapping_add(1);
        if timelines {
            self.timeline_key = key;
        } else {
            self.history_key = key;
        }
        Ok(())
    }
}

fn meta(db: &Connection, key: &str) -> Result<Option<String>> {
    db.query_row("SELECT value FROM metadata WHERE key=?1", [key], |r| {
        r.get(0)
    })
    .optional()
    .map_err(db_error)
}
fn number_meta(db: &Connection, key: &str) -> Result<Option<f64>> {
    meta(db, key)?
        .map(|value| {
            value
                .parse::<f64>()
                .ok()
                .filter(|v| v.is_finite())
                .ok_or_else(|| "Saved archive timing is invalid.".into())
        })
        .transpose()
}
fn migrate_hours(db: &Connection, zone: Tz) -> Result<()> {
    let mut statement = db
        .prepare("SELECT DISTINCT hour FROM hourly")
        .map_err(db_error)?;
    let keys = statement
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(db_error)?;
    for key in keys {
        let old = chrono::DateTime::parse_from_rfc3339(&key)
            .map_err(|_| "Saved hourly timing is invalid.")?;
        let wall_hour = old.format("%Y-%m-%dT%H").to_string();
        let mut start = None;
        // Schema 1 rounded partial DST hours to :00 using the observation's offset.
        for minute in 0..60 {
            let candidate = old + chrono::Duration::minutes(minute);
            let local = candidate.with_timezone(&zone);
            if local.offset().fix() == *old.offset()
                && local.format("%Y-%m-%dT%H").to_string() == wall_hour
            {
                start = Some(calendar::hour(candidate.timestamp_millis() as f64, zone)?.start);
                break;
            }
        }
        let new = hour_key(
            start.ok_or("Saved hourly timing does not match its reporting zone.")?,
            zone,
        )?;
        if new != key {
            db.execute("UPDATE hourly SET hour=?1 WHERE hour=?2", params![new, key])
                .map_err(db_error)?;
        }
    }
    Ok(())
}
fn hour_key(ms: f64, zone: Tz) -> Result<String> {
    Ok(date(ms)?
        .with_timezone(&zone)
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, false))
}
fn record_gap(db: &Connection, source: &str, start: f64, end: f64) -> Result<()> {
    // Gaps are coalesced: only the nearest preceding interval can overlap start.
    // Bound the indexed scan so large imports do not revisit every earlier call.
    let (low, high): (f64, f64) = db
        .query_row(
            "SELECT MIN(COALESCE(MIN(start),?2),?2),MAX(COALESCE(MAX(end),?3),?3) FROM source_gaps
         WHERE source=?1 AND start BETWEEN COALESCE(
             (SELECT MAX(start) FROM source_gaps WHERE source=?1 AND start<=?2),?2
         ) AND ?3 AND end>=?2",
            params![source, start, end],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(db_error)?;
    db.execute(
        "DELETE FROM source_gaps WHERE source=?1 AND start>=?2 AND start<=?3",
        params![source, low, high],
    )
    .map_err(db_error)?;
    db.execute(
        "INSERT INTO source_gaps VALUES (?1,?2,?3)",
        params![source, low, high],
    )
    .map_err(db_error)?;
    Ok(())
}
fn record_coverage(db: &Connection, zone: Tz, source: &str, start: f64, end: f64) -> Result<()> {
    let day = date(start)?.with_timezone(&zone).date_naive().to_string();
    let mut statement = db.prepare("SELECT start,end FROM coverage_intervals WHERE day=?1 AND source=?2 AND start<=?4 AND end>=?3").map_err(db_error)?;
    let intervals = statement
        .query_map(params![day, source, start, end], |r| {
            Ok((r.get::<_, f64>(0)?, r.get::<_, f64>(1)?))
        })
        .map_err(db_error)?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(db_error)?;
    let mut seconds = (end - start) / 1000.0;
    let (mut low, mut high) = (start, end);
    for (a, b) in intervals {
        seconds -= (end.min(b) - start.max(a)).max(0.0) / 1000.0;
        low = low.min(a);
        high = high.max(b);
    }
    if seconds < -0.000001 {
        return Err("Saved recording coverage overlaps incorrectly.".into());
    }
    db.execute(
        "DELETE FROM coverage_intervals WHERE day=?1 AND source=?2 AND start<=?4 AND end>=?3",
        params![day, source, low, high],
    )
    .map_err(db_error)?;
    db.execute(
        "INSERT INTO coverage_intervals VALUES (?1,?2,?3,?4)",
        params![day, source, low, high],
    )
    .map_err(db_error)?;
    for (table, bucket) in [
        ("coverage", day),
        (
            "hourly_coverage",
            hour_key(calendar::hour(start, zone)?.start, zone)?,
        ),
    ] {
        db.execute(&format!("INSERT INTO {table} VALUES (?1,?2,?3) ON CONFLICT(bucket,source) DO UPDATE SET seconds=seconds+excluded.seconds"),
            params![bucket,source,seconds.max(0.0)]).map_err(db_error)?;
    }
    Ok(())
}
fn coverage_rows(db: &Connection, table: &str, start: &str, end: &str) -> Result<Vec<CoverageRow>> {
    let mut statement = db.prepare(&format!("SELECT bucket,source,seconds FROM {table} WHERE substr(bucket,1,10)>=?1 AND substr(bucket,1,10)<=?2 ORDER BY bucket,source")).map_err(db_error)?;
    let rows = statement
        .query_map(params![start, end], |r| {
            Ok(CoverageRow {
                bucket: r.get(0)?,
                source: r.get(1)?,
                recording_seconds: r.get(2)?,
            })
        })
        .map_err(db_error)?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(db_error);
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gap_lookup_coalesces_points_overlaps_and_bridged_intervals_in_any_order() {
        let intervals = [
            (10.0, 10.0),
            (20.0, 20.0),
            (30.0, 40.0),
            (50.0, 60.0),
            (35.0, 35.0),
            (20.0, 30.0),
            (25.0, 55.0),
            (70.0, 80.0),
            (90.0, 90.0),
            (90.0, 90.0),
            (100.0, 110.0),
            (0.0, 0.0),
        ];
        for reverse in [false, true] {
            let db = Connection::open_in_memory().unwrap();
            db.execute_batch(
                "CREATE TABLE source_gaps (source TEXT, start REAL, end REAL);
                 CREATE INDEX gap_lookup ON source_gaps(source,start,end);
                 INSERT INTO source_gaps VALUES ('other',0,200);",
            )
            .unwrap();
            let mut seen: Vec<(f64, f64)> = Vec::new();
            for index in 0..intervals.len() {
                let (start, end) = intervals[if reverse {
                    intervals.len() - 1 - index
                } else {
                    index
                }];
                record_gap(&db, "test", start, end).unwrap();
                seen.push((start, end));
                seen.sort_by(|a, b| a.0.total_cmp(&b.0));
                let mut expected: Vec<(f64, f64)> = Vec::new();
                for &(start, end) in &seen {
                    if let Some(last) = expected.last_mut().filter(|last| last.1 >= start) {
                        last.1 = last.1.max(end);
                    } else {
                        expected.push((start, end));
                    }
                }
                let actual = db
                    .prepare("SELECT start,end FROM source_gaps WHERE source='test' ORDER BY start")
                    .unwrap()
                    .query_map([], |row| Ok((row.get::<_, f64>(0)?, row.get::<_, f64>(1)?)))
                    .unwrap()
                    .collect::<rusqlite::Result<Vec<_>>>()
                    .unwrap();
                assert_eq!(actual, expected);
                assert_eq!(db.query_row("SELECT COUNT(*) FROM source_gaps WHERE source='other' AND start=0 AND end=200", [], |row| row.get::<_, i64>(0)).unwrap(), 1);
            }
        }
    }
}

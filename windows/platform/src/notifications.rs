use crate::{
    attention::Notice,
    preferences::Preferences,
    storage::{random_id, Result, Store},
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use tokenotch_core::hook::{digest, EventKind, Observation, Source};

const DAY: f64 = 86_400_000.0;
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Category {
    Stopped,
    Error,
    Request,
    Context,
    Incident,
    Recovery,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum Target {
    Notice { id: String },
    Usage,
    Service,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Alert {
    pub id: String,
    pub category: Category,
    pub title: String,
    pub body: String,
    pub target: Target,
    pub observed_at: f64,
    #[serde(skip)]
    pub context: Option<(String, u64)>,
    #[serde(skip)]
    pub incident: Option<String>,
}
#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
pub struct Delivery {
    pub desktop: bool,
    pub sound: bool,
    pub card: bool,
}
#[derive(Clone)]
pub struct Pending {
    pub alert: Alert,
    pub delivery: Delivery,
    pub queued_at: f64,
}
#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryStatus {
    pub observed_at: Option<f64>,
    pub desktop: Option<String>,
    pub sound: Option<String>,
    pub card: Option<String>,
}
impl Pending {
    pub fn delivery_now(&self, prefs: &Preferences, now: f64) -> Delivery {
        if !(0.0..60_000.0).contains(&(now - self.queued_at))
            || !allows(prefs, self.alert.category, now)
        {
            return Delivery::default();
        }
        Delivery {
            desktop: self.delivery.desktop && prefs.desktop_banner,
            sound: self.delivery.sound && prefs.sound,
            card: self.delivery.card && prefs.expand_card,
        }
    }
}
pub fn allows(prefs: &Preferences, category: Category, now: f64) -> bool {
    prefs.allows_notification(now)
        && match category {
            Category::Stopped => prefs.notify_stopped,
            Category::Error => prefs.notify_errors,
            Category::Request => prefs.notify_requests,
            Category::Context => prefs.notify_context,
            Category::Incident => prefs.service_health && prefs.notify_incidents,
            Category::Recovery => prefs.service_health && prefs.notify_recovery,
        }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Receipts {
    key: String,
    consumed: BTreeMap<String, f64>,
    #[serde(default)]
    context_warned: BTreeMap<String, f64>,
}
struct ContextState {
    fraction: Option<f64>,
    limit: Option<u64>,
    at: f64,
    armed: bool,
}
pub struct Notifications {
    receipts: Receipts,
    contexts: BTreeMap<String, ContextState>,
    started_at: f64,
}
impl Notifications {
    pub fn open(store: &Store, now: f64) -> Result<Self> {
        let receipts = store
            .load::<Receipts>("notification-receipts.json")?
            .unwrap_or(Receipts {
                key: random_id()?,
                consumed: BTreeMap::new(),
                context_warned: BTreeMap::new(),
            });
        let hash = |key: &str| key.len() == 64 && key.bytes().all(|c| c.is_ascii_hexdigit());
        if !now.is_finite()
            || !hash(&receipts.key)
            || receipts.consumed.len() > 4096
            || receipts.context_warned.len() > 100
            || receipts
                .consumed
                .iter()
                .chain(receipts.context_warned.iter())
                .any(|(key, at)| !hash(key) || !at.is_finite())
        {
            return Err(
                "Saved notification suppression state is invalid. Alerts were not delivered."
                    .into(),
            );
        }
        Ok(Self {
            receipts,
            contexts: BTreeMap::new(),
            started_at: now,
        })
    }
    pub fn reset_context(&mut self) {
        self.contexts.clear();
    }
    fn consume(&mut self, id: &str, now: f64) -> bool {
        self.receipts.consumed.retain(|_, at| now - *at < 7.0 * DAY);
        let duplicate = self.receipts.consumed.contains_key(id);
        self.receipts.consumed.entry(id.into()).or_insert(now);
        prune(&mut self.receipts.consumed, 4096);
        duplicate
    }
    fn persist(&self, store: &Store) -> Result<()> {
        store.save("notification-receipts.json", &self.receipts)
    }
    fn decision(&self, alert: Alert, prefs: &Preferences, now: f64) -> Option<Pending> {
        (alert.observed_at >= self.started_at
            && allows(prefs, alert.category, now)
            && (prefs.desktop_banner || prefs.sound || prefs.expand_card))
            .then_some(Pending {
                alert,
                queued_at: now,
                delivery: Delivery {
                    desktop: prefs.desktop_banner,
                    sound: prefs.sound,
                    card: prefs.expand_card,
                },
            })
    }
    pub fn test(
        &mut self,
        prefs: &Preferences,
        store: &Store,
        now: f64,
    ) -> Result<Option<Pending>> {
        let id = digest(&random_id()?);
        self.consume(&id, now);
        self.persist(store)?;
        Ok(self.decision(
            Alert {
                id,
                category: Category::Stopped,
                title: "Tokenotch test notification".into(),
                body: "Your stopped-category, mute, quiet-hour and channel settings apply.".into(),
                target: Target::Usage,
                observed_at: now,
                context: None,
                incident: None,
            },
            prefs,
            now,
        ))
    }
    pub fn observe(
        &mut self,
        event: &Observation,
        notice: Option<&Notice>,
        prefs: &Preferences,
        store: &Store,
        now: f64,
    ) -> Result<Option<Pending>> {
        event
            .validate_payload()
            .map_err(|error| error.to_string())?;
        if !now.is_finite() {
            return Err("Notification observation time is invalid.".into());
        }
        if matches!(
            event.kind,
            EventKind::Context | EventKind::ContextInvalidated
        ) {
            return self.context(event, prefs, store, now);
        }
        let (kind, category, title, body) = match event.kind {
            EventKind::Stopped => ("stopped",Category::Stopped,"Copilot execution stopped","The client reported a stop. This does not establish task success."),
            EventKind::Failed | EventKind::UnrecoverableError => ("error",Category::Error,"Copilot reported an error","Review the local session. An error report does not by itself establish that the session ended."),
            EventKind::InputRequested => ("inputRequested",Category::Request,"Copilot requested your input","Open session details. The response status is not observed; viewing does not answer this request."),
            EventKind::ApprovalRequested => ("approvalRequested",Category::Request,"Copilot requested approval","Open session details. The response status is not observed; viewing does not approve this request."),
            _ => return Ok(None),
        };
        // Preserve schema-1 receipt identities when moving delivery out of Attention.
        let id = digest(&format!(
            "{}:{:?}:{}:{kind}:{}",
            self.receipts.key, event.source, event.session, event.timestamp_unix_ms
        ));
        let duplicate = self.consume(&id, now);
        self.persist(store)?;
        Ok(notice.filter(|_| !duplicate).and_then(|notice| {
            self.decision(
                Alert {
                    id,
                    category,
                    title: title.into(),
                    body: body.into(),
                    target: Target::Notice {
                        id: notice.id.clone(),
                    },
                    observed_at: event.timestamp_unix_ms,
                    context: None,
                    incident: None,
                },
                prefs,
                now,
            )
        }))
    }
    fn context(
        &mut self,
        event: &Observation,
        prefs: &Preferences,
        store: &Store,
        now: f64,
    ) -> Result<Option<Pending>> {
        if event.source != Source::Cli {
            return Ok(None);
        }
        self.contexts.retain(|_, state| now - state.at < DAY);
        self.receipts.context_warned.retain(|_, at| now - *at < DAY);
        let session = digest(&format!("{}:context:{}", self.receipts.key, event.session));
        if self
            .contexts
            .get(&session)
            .is_some_and(|state| event.timestamp_unix_ms <= state.at)
        {
            return Ok(None);
        }
        if event.kind == EventKind::ContextInvalidated {
            self.contexts.insert(
                session,
                ContextState {
                    fraction: None,
                    limit: None,
                    at: event.timestamp_unix_ms,
                    armed: false,
                },
            );
            self.prune_contexts();
            return Ok(None);
        }
        let reading = event
            .context
            .as_ref()
            .ok_or("Context observation is missing its reading.")?;
        let fraction = reading.current_tokens as f64 / reading.token_limit as f64;
        let previous = self.contexts.get(&session);
        let fresh = (-30_000.0..=300_000.0).contains(&(now - event.timestamp_unix_ms));
        let continuous = fresh
            && previous.is_some_and(|state| {
                state.fraction.is_some()
                    && event.timestamp_unix_ms - state.at <= 300_000.0
                    && state.limit == Some(reading.token_limit)
            });
        let mut armed = if continuous {
            previous.is_some_and(|state| state.armed) || fraction < 0.7
        } else {
            fresh && fraction < 0.8
        };
        let crossing = continuous
            && armed
            && previous.is_some_and(|state| state.fraction.is_some_and(|fraction| fraction < 0.8))
            && fraction >= 0.8;
        if crossing {
            armed = false;
        }
        self.contexts.insert(
            session.clone(),
            ContextState {
                fraction: fresh.then_some(fraction),
                limit: Some(reading.token_limit),
                at: event.timestamp_unix_ms,
                armed,
            },
        );
        self.prune_contexts();
        if !crossing
            || self
                .receipts
                .context_warned
                .get(&session)
                .is_some_and(|at| event.timestamp_unix_ms - *at < 600_000.0)
        {
            return Ok(None);
        }
        self.receipts
            .context_warned
            .insert(session, event.timestamp_unix_ms);
        prune(&mut self.receipts.context_warned, 100);
        let id = digest(&format!(
            "{}:context:{}:{}",
            self.receipts.key, event.session, event.timestamp_unix_ms
        ));
        let duplicate = self.consume(&id, now);
        self.persist(store)?;
        Ok((!duplicate).then(|| self.decision(Alert {
            id,category:Category::Context,title:"Copilot context is above 80%".into(),
            body:"A fresh local CLI reading crossed 80% context utilization. This does not predict compaction.".into(),
            target:Target::Usage,observed_at:event.timestamp_unix_ms,
            context:Some((event.session.clone(),reading.token_limit)),incident:None,
        },prefs,now)).flatten())
    }
    fn prune_contexts(&mut self) {
        while self.contexts.len() > 100 {
            let oldest = self
                .contexts
                .iter()
                .min_by(|a, b| a.1.at.total_cmp(&b.1.at))
                .map(|(key, _)| key.clone());
            if let Some(key) = oldest {
                self.contexts.remove(&key);
            }
        }
    }
    pub fn service(
        &mut self,
        observations: &[(String, bool)],
        baseline: bool,
        prefs: &Preferences,
        store: &Store,
        now: f64,
    ) -> Result<Vec<Pending>> {
        let mut pending = Vec::new();
        for (incident, resolved) in observations {
            let category = if *resolved {
                Category::Recovery
            } else {
                Category::Incident
            };
            let id = digest(&format!(
                "{}:{}:{incident}",
                self.receipts.key,
                if *resolved { "recovery" } else { "incident" }
            ));
            if !self.consume(&id, now) && !baseline {
                if let Some(value) = self.decision(Alert {
                    id,category,observed_at:now,context:None,incident:Some(incident.clone()),target:Target::Service,
                    title:if *resolved { "Copilot incident resolved" } else { "Copilot service incident" }.into(),
                    body:if *resolved { "GitHub explicitly reports this Copilot incident as resolved." }
                        else { "GitHub reports an incident affecting Copilot. Open service status for details." }.into(),
                },prefs,now) { pending.push(value); }
            }
        }
        if !observations.is_empty() {
            self.persist(store)?;
        }
        Ok(pending)
    }
}
fn prune(values: &mut BTreeMap<String, f64>, limit: usize) {
    while values.len() > limit {
        let oldest = values
            .iter()
            .min_by(|a, b| a.1.total_cmp(b.1))
            .map(|(key, _)| key.clone());
        if let Some(key) = oldest {
            values.remove(&key);
        }
    }
}

#[derive(Default)]
pub struct HealthLedger {
    active: Option<BTreeSet<String>>,
}
impl HealthLedger {
    pub fn observe(
        &mut self,
        incidents: &BTreeMap<String, bool>,
    ) -> Result<(bool, Vec<(String, bool)>)> {
        let baseline = self.active.is_none();
        let mut active = self.active.clone().unwrap_or_default();
        let mut changes = Vec::new();
        for (id, resolved) in incidents {
            let changed = if *resolved {
                active.remove(id)
            } else {
                active.insert(id.clone())
            };
            if baseline || changed {
                changes.push((id.clone(), *resolved));
            }
        }
        if active.len() > 1000 {
            return Err(
                "Too many unresolved service incidents. Service alert state was preserved.".into(),
            );
        }
        self.active = Some(active);
        Ok((baseline, changes))
    }
    pub fn active_count(&self) -> usize {
        self.active.as_ref().map_or(0, BTreeSet::len)
    }
    pub fn active(&self, id: &str) -> bool {
        self.active
            .as_ref()
            .is_some_and(|active| active.contains(id))
    }
}

pub fn parse_health(bytes: &[u8]) -> Result<BTreeMap<String, bool>> {
    #[derive(Deserialize)]
    struct Component {
        id: String,
        name: String,
    }
    #[derive(Deserialize)]
    struct Affected {
        id: String,
    }
    #[derive(Deserialize)]
    struct Incident {
        id: String,
        status: String,
        components: Vec<Affected>,
    }
    #[derive(Deserialize)]
    struct Feed {
        components: Vec<Component>,
        incidents: Vec<Incident>,
    }
    if bytes.len() > 262_144 {
        return Err("GitHub status response exceeds 256 KiB.".into());
    }
    let feed: Feed = serde_json::from_slice(bytes)
        .map_err(|_| "GitHub returned unsupported service incident data.")?;
    let ids: BTreeSet<_> = feed
        .components
        .iter()
        .filter(|c| c.name.to_lowercase().contains("copilot"))
        .map(|c| c.id.as_str())
        .collect();
    if ids.is_empty() || ids.iter().any(|id| id.is_empty() || id.len() > 256) {
        return Err("GitHub Copilot service components are unavailable.".into());
    }
    let mut incidents = BTreeMap::new();
    for incident in feed.incidents {
        if !incident
            .components
            .iter()
            .any(|c| ids.contains(c.id.as_str()))
        {
            continue;
        }
        if incident.id.is_empty()
            || incident.id.len() > 256
            || !["investigating", "identified", "monitoring", "resolved"]
                .contains(&incident.status.as_str())
        {
            return Err("GitHub returned an unsupported Copilot incident status.".into());
        }
        let resolved = incident.status == "resolved";
        if incidents
            .insert(digest(&incident.id), resolved)
            .is_some_and(|previous| previous != resolved)
        {
            return Err("GitHub returned conflicting incident states.".into());
        }
    }
    Ok(incidents)
}

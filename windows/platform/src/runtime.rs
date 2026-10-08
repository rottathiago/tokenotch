use crate::{
    account::{Account, Authentication},
    archive::{Archive, History},
    attention::Attention,
    connections::Connections,
    notifications::{
        self, Category, Delivery, DeliveryStatus, HealthLedger, Notifications, Pending, Target,
    },
    preferences::Preferences,
    storage::{random_id, Result, Store},
    transport::{self, now_ms, Envelope},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
use tokenotch_core::{
    hook::{EventKind, Observation, Source, UsageSource},
    live::{ActivityState, TokenLedger},
};

pub type Shared = Arc<Mutex<Runtime>>;
#[derive(Serialize, Deserialize)]
pub struct Receiver {
    pub port: u16,
    pub token: String,
}
pub struct Runtime {
    pub store: Store,
    pub preferences: Preferences,
    pub connections: Connections,
    pub activity: ActivityState,
    pub tokens: TokenLedger,
    pub attention: Attention,
    pub archive: Option<Archive>,
    pub warning: Option<String>,
    pub account: Option<Account>,
    pub account_auth: Authentication,
    pub account_error: Option<String>,
    pub account_busy: bool,
    pub account_shared: bool,
    pub account_cli: Option<std::path::PathBuf>,
    pub receiver: Receiver,
    pub receiver_running: bool,
    pub pipe_running: bool,
    pub live_generation: String,
    pub delivery: BTreeMap<String, f64>,
    pub notifications: Vec<Pending>,
    pub notifier: Notifications,
    pub notification_error: Option<String>,
    pub notification_delivery: DeliveryStatus,
    pub health: Option<Value>,
    pub health_error: Option<String>,
    pub health_ledger: HealthLedger,
    pub health_busy: bool,
    health_generation: u64,
    pub pending_import: Option<crate::import::Preview>,
    import_generation: u64,
}

impl Runtime {
    pub fn open(store: Store) -> Result<Self> {
        let mut preferences = store
            .load::<Preferences>("preferences.json")?
            .unwrap_or_default();
        preferences.validate()?;
        // Builds before history defaulted on saved `history: false` without an archive.
        // An existing archive means the user chose to pause, so only never-recorded installs migrate.
        if !preferences.history && !store.path("usage.sqlite")?.exists() {
            preferences.history = true;
            store.save("preferences.json", &preferences)?;
        }
        let connections = Connections::new(store.clone())?;
        connections.reconcile_vscode()?;
        store.remove("vscode-setup-request.json")?;
        let attention = Attention::open(&store, preferences.remember_notices)?;
        let notifier = Notifications::open(&store, now_ms())?;
        let mut archive =
            if preferences.history || preferences.timelines || store.path("usage.sqlite")?.exists()
            {
                Some(Archive::open(&store)?)
            } else {
                None
            };
        if let Some(archive) = &mut archive {
            archive.checkpoint(preferences.history, &[], now_ms(), true)?;
            archive.timeline_checkpoint(preferences.timelines, &[], now_ms(), true)?;
            archive.prune(preferences.retention_days, now_ms())?;
        }
        let receiver = store
            .load::<Receiver>("receiver.json")?
            .unwrap_or(Receiver {
                port: 0,
                token: random_id()?,
            });
        if receiver.token.len() != 64 || !receiver.token.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err("The receiver credential is invalid. Repair private storage.".into());
        }
        Ok(Self {
            store,
            preferences,
            connections,
            activity: ActivityState::default(),
            tokens: TokenLedger::default(),
            attention,
            archive,
            warning: None,
            account: None,
            account_auth: Authentication::Unknown,
            account_error: None,
            account_busy: false,
            account_shared: false,
            account_cli: None,
            receiver,
            receiver_running: false,
            pipe_running: false,
            live_generation: random_id()?,
            delivery: BTreeMap::new(),
            notifications: Vec::new(),
            notifier,
            notification_error: None,
            notification_delivery: DeliveryStatus::default(),
            health: None,
            health_error: None,
            health_ledger: HealthLedger::default(),
            health_busy: false,
            health_generation: 0,
            pending_import: None,
            import_generation: 0,
        })
    }

    pub fn preferences(&mut self, preferences: Preferences) -> Result<()> {
        preferences.validate()?;
        if self.account_busy
            && (preferences.account_enabled != self.preferences.account_enabled
                || preferences.cli_executable != self.preferences.cli_executable)
        {
            return Err(
                "Wait for the current account operation before changing account settings.".into(),
            );
        }
        self.checkpoint(now_ms(), false)?;
        if preferences.onboarding_complete
            && !self.preferences.onboarding_complete
            && !self.connections.configured(Source::Cli)?
            && !self.connections.configured(Source::Vscode)?
        {
            return Err("Configure at least one local client before finishing setup.".into());
        }
        if (preferences.history || preferences.timelines) && self.archive.is_none() {
            self.archive = Some(Archive::open(&self.store)?);
        }
        if preferences.remember_notices != self.preferences.remember_notices {
            self.attention
                .remember(&self.store, preferences.remember_notices)?;
        }
        if !preferences.vscode_metrics && self.preferences.vscode_metrics {
            self.receiver.token = random_id()?;
            self.store.save("receiver.json", &self.receiver)?;
            self.tokens.remove(UsageSource::VscodeLocal);
            self.tokens.remove(UsageSource::VscodeCopilot);
        }
        self.store.save("preferences.json", &preferences)?;
        if preferences.account_enabled != self.preferences.account_enabled
            || preferences.cli_executable != self.preferences.cli_executable
        {
            self.account = None;
            self.account_auth = Authentication::Unknown;
            self.account_error = None;
            self.account_shared = false;
            self.account_cli = None;
        }
        for pending in &mut self.notifications {
            pending.delivery = pending.delivery_now(&preferences, now_ms());
        }
        self.notifications
            .retain(|pending| pending.delivery != Delivery::default());
        if (preferences.notifications
            && preferences.notify_context
            && !preferences.mute_notifications)
            != (self.preferences.notifications
                && self.preferences.notify_context
                && !self.preferences.mute_notifications)
        {
            self.notifier.reset_context();
        }
        if preferences.service_health != self.preferences.service_health {
            self.health_generation = self.health_generation.wrapping_add(1);
            self.health_busy = false;
            self.health = None;
            self.health_error = None;
            self.health_ledger = HealthLedger::default();
            self.notifications.retain(|pending| {
                !matches!(
                    pending.alert.category,
                    Category::Incident | Category::Recovery
                )
            });
        }
        if preferences.history != self.preferences.history {
            self.import_generation = self.import_generation.wrapping_add(1);
        }
        self.preferences = preferences;
        self.checkpoint(now_ms(), false)?;
        Ok(())
    }

    pub fn checkpoint(&mut self, now: f64, discontinuity: bool) -> Result<()> {
        if self.archive.is_none() {
            return Ok(());
        }
        let result = (|| {
            let mut sources = Vec::new();
            let mut timeline_sources = Vec::new();
            if self.preferences.timelines && self.pipe_running {
                if self.store.read("cli.registration", 128)?.is_some() {
                    timeline_sources.push(Source::Cli);
                }
                if self.connections.configured(Source::Vscode)? {
                    timeline_sources.push(Source::Vscode);
                }
            }
            if self.preferences.history {
                if self.pipe_running && self.store.read("cli.registration", 128)?.is_some() {
                    sources.push(UsageSource::Cli);
                }
                self.connections.reconcile_vscode()?;
                if self.preferences.vscode_metrics
                    && self.receiver_running
                    && self
                        .store
                        .load::<Value>("vscode-approved.json")?
                        .is_some_and(|v| v["metrics"] == true)
                    && self
                        .store
                        .load::<Value>("vscode-settings.receipt.json")?
                        .is_some_and(|v| v["owner"].is_object())
                {
                    sources.extend([UsageSource::VscodeLocal, UsageSource::VscodeCopilot]);
                }
            }
            if let Some(archive) = &mut self.archive {
                archive.checkpoint(self.preferences.history, &sources, now, discontinuity)?;
                archive.timeline_checkpoint(
                    self.preferences.timelines,
                    &timeline_sources,
                    now,
                    discontinuity,
                )?;
                archive.prune(self.preferences.retention_days, now)?;
            }
            Ok(())
        })();
        if let Err(message) = result {
            return self.archive_failure(message);
        }
        Ok(())
    }

    pub fn archive_failure<T>(&mut self, message: String) -> Result<T> {
        self.warning = Some(message.clone());
        self.import_generation = self.import_generation.wrapping_add(1);
        self.preferences.history = false;
        self.preferences.timelines = false;
        self.store.save("preferences.json", &self.preferences)?;
        Err(message)
    }

    pub fn coverage_gap(&mut self, sources: &[UsageSource], now: f64) -> Result<()> {
        if self.preferences.timelines {
            if let Some(archive) = &self.archive {
                if let Err(message) = archive.mark_timeline_interruption() {
                    return self.archive_failure(message);
                }
            }
        }
        if self.preferences.history {
            if let Some(archive) = &mut self.archive {
                if let Err(message) = archive.mark_gap(sources, now) {
                    return self.archive_failure(message);
                }
            }
        }
        Ok(())
    }

    pub fn detail_generation(&self, kind: crate::navigation::DetailKind) -> Option<String> {
        use crate::navigation::DetailKind;
        match kind {
            DetailKind::Live => Some(self.live_generation.clone()),
            DetailKind::History | DetailKind::Insight => {
                self.archive.as_ref().map(Archive::history_generation)
            }
            DetailKind::Timeline => self.archive.as_ref().map(Archive::timeline_generation),
        }
    }

    pub fn accept(&mut self, envelope: Envelope) -> Result<()> {
        if envelope.event.metric_source.is_some() {
            return Err("Metric origin is not admitted by the hook pipe.".into());
        }
        let registration = self
            .store
            .read(transport::registration_name(envelope.event.source), 128)?
            .ok_or("Collection is disabled for this client.")?;
        if envelope.registration.as_bytes() != registration {
            return Err("Client registration is no longer valid.".into());
        }
        self.observe(&envelope.event, false)
    }

    pub fn observe(&mut self, event: &Observation, metrics: bool) -> Result<()> {
        let now = now_ms();
        event
            .validate(now, metrics)
            .map_err(|error| error.to_string())?;
        let changed = if matches!(
            event.kind,
            EventKind::Usage | EventKind::Context | EventKind::ContextInvalidated
        ) {
            self.tokens
                .observe(event, now, metrics)
                .map_err(|error| error.to_string())?
        } else if event.kind.lifecycle_order().is_some() {
            self.activity
                .accept(event, now)
                .map_err(|error| error.to_string())?
        } else {
            true
        };
        // Live deduplication is not a receipt for a successful archive transaction.
        if changed || event.kind == EventKind::Usage {
            if let Some(archive) = &mut self.archive {
                let preferences = Preferences {
                    // A usage replay can repair accounting, not repopulate cleared timelines.
                    timelines: self.preferences.timelines && changed,
                    ..self.preferences.clone()
                };
                if let Err(message) = archive.record(event, &preferences, false) {
                    return self.archive_failure(message);
                }
            }
        }
        if !changed {
            return Ok(());
        }
        self.delivery.insert(
            if metrics {
                event.usage_source().wire_name().to_owned()
            } else {
                match event.source {
                    Source::Cli => "cli",
                    Source::Vscode => "vscode",
                }
                .into()
            },
            now,
        );
        let notice = match self
            .attention
            .observe(event, &self.preferences, &self.store, now)
        {
            Ok(notice) => notice,
            Err(message) => {
                self.notification_error = Some(message.clone());
                return Err(message);
            }
        };
        match self
            .notifier
            .observe(event, notice.as_ref(), &self.preferences, &self.store, now)
        {
            Ok(Some(pending)) => self.enqueue_notification(pending),
            Ok(None) => {}
            Err(message) => {
                self.notification_error = Some(message.clone());
                return Err(message);
            }
        }
        Ok(())
    }

    pub fn snapshot(&mut self) -> Result<Value> {
        let now = now_ms();
        // Persist through the same instant used to classify the unfinished bucket.
        self.checkpoint(now, false)?;
        self.activity
            .expire(now)
            .map_err(|error| error.to_string())?;
        self.tokens.expire(now).map_err(|error| error.to_string())?;
        let sessions:Vec<_>=self.activity.sessions().map(|session|json!({
            "source":session.source,"id":session.session,"kind":session.kind,"label":session.label(now),
            "observedAt":session.observed_at_unix_ms,"working":session.is_working(now),
            "workStartedAt":session.work_started_at_unix_ms,
            "context":if session.source==Source::Cli {self.tokens.context(&session.session)} else {None}
        })).collect();
        let cli = self.connections.configured(Source::Cli);
        let vscode = self.connections.configured(Source::Vscode);
        let today = match self
            .archive
            .as_ref()
            .map(|archive| {
                let day = archive.today(now)?;
                archive.history(&day, &day)
            })
            .transpose()
        {
            Ok(today) => today,
            Err(message) => return self.archive_failure(message),
        };
        Ok(json!({
            "archives":{"history":self.archive.as_ref().map(Archive::history_generation),
                "historyRevision":self.archive.as_ref().map(Archive::history_revision),
                "timelines":self.archive.as_ref().map(Archive::timeline_generation),
                "live":self.live_generation,"timelineCutoff":now-f64::from(self.preferences.retention_days)*86_400_000.0},
            "preferences":self.preferences,"sessions":sessions,
            "samples":self.tokens.samples().collect::<Vec<_>>(),
            "partial":self.tokens.last_discarded_at_unix_ms.is_some(),"notices":self.attention.notices.values().collect::<Vec<_>>(),
            "noticeCapacityReached":self.attention.capacity_reached,
            "connections":{"cli":cli.as_ref().is_ok_and(|v|*v),"vscode":vscode.as_ref().is_ok_and(|v|*v),
                "cliError":cli.err(),"vscodeError":vscode.err(),
                "vscodeSetup":self.connections.vscode_setup(now)?,
                "vscodeResult":self.store.load::<Value>("vscode-setup-result.json")?},
            "delivery":self.delivery,"receiverRunning":self.receiver_running,
            "account":self.account,"accountAuth":self.account_auth,"accountError":self.account_error,"accountBusy":self.account_busy,
            "accountShared":self.account_shared,
            "accountCli":self.preferences.cli_executable.clone().or_else(||self.account_cli.as_ref().and_then(|v|v.to_str()).map(str::to_owned)),
            "warning":self.warning,"today":today,"health":self.health,"healthError":self.health_error,"healthBusy":self.health_busy,"now":now,
            "notificationError":self.notification_error,"notificationDelivery":self.notification_delivery
        }))
    }

    pub fn history(&mut self, start: &str, end: &str) -> Result<History> {
        self.history_filtered(start, end, None)
    }

    /// Cheap fingerprint of state that other windows must reflect immediately:
    /// notice attention state and the saved-history revision.
    pub fn change_signature(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        for notice in self.attention.notices.values() {
            (&notice.id, notice.viewed, notice.dismissed, notice.resolved).hash(&mut hasher);
        }
        self.archive
            .as_ref()
            .map(Archive::history_revision)
            .hash(&mut hasher);
        hasher.finish()
    }

    /// Connecting a client starts usage history so the History page has data;
    /// returns whether recording was newly enabled.
    pub fn enable_history_for_connection(&mut self) -> Result<bool> {
        if self.preferences.history {
            return Ok(false);
        }
        let mut preferences = self.preferences.clone();
        preferences.history = true;
        self.preferences(preferences)?;
        Ok(true)
    }

    pub fn history_filtered(
        &mut self,
        start: &str,
        end: &str,
        model: Option<&str>,
    ) -> Result<History> {
        self.checkpoint(now_ms(), false)?;
        let archive = self
            .archive
            .as_mut()
            .ok_or("History is not enabled. No earlier observations can be reconstructed.")?;
        archive.prune(self.preferences.retention_days, now_ms())?;
        archive.history_filtered(start, end, model)
    }

    pub fn clear(&mut self, kind: &str) -> Result<()> {
        match kind {
            "live" => {
                self.live_generation = random_id()?;
                self.tokens = TokenLedger::default();
                self.activity = ActivityState::default();
                self.delivery.clear();
                self.notifier.reset_context();
                self.clear("notices")?;
            }
            "notices" => {
                self.store.remove("notices.json")?;
                self.attention = Attention::open(&self.store, false)?;
                self.notifications
                    .retain(|pending| !matches!(pending.alert.target, Target::Notice { .. }));
            }
            "history" | "timelines" => {
                if kind == "history" {
                    self.import_generation = self.import_generation.wrapping_add(1);
                }
                if let Some(archive) = &mut self.archive {
                    archive.delete(kind == "timelines")?;
                }
                self.checkpoint(now_ms(), false)?;
            }
            _ => return Err("Unsupported deletion request.".into()),
        }
        Ok(())
    }

    fn enqueue_notification(&mut self, pending: Pending) {
        if self.notifications.len() < 100 {
            self.notifications.push(pending);
        } else {
            self.notification_error = Some("Notification capacity was reached. The missed alert was consumed and will not be replayed.".into());
        }
    }

    pub fn notification_delivery(&self, pending: &Pending, now: f64) -> Delivery {
        let alert = &pending.alert;
        if let Target::Notice { id } = &alert.target {
            if !self.attention.notices.values().any(|notice| {
                &notice.id == id && !notice.resolved && !notice.dismissed && !notice.viewed
            }) {
                return Delivery::default();
            }
        }
        if let Some((session, limit)) = &alert.context {
            if !self.tokens.context(session).is_some_and(|reading| {
                reading.observed_at_unix_ms >= alert.observed_at
                    && !reading.is_stale(now)
                    && reading.context.as_ref().is_some_and(|value| {
                        value.token_limit == *limit
                            && value.current_tokens as f64 / value.token_limit as f64 >= 0.8
                    })
            }) {
                return Delivery::default();
            }
        }
        if let Some(incident) = &alert.incident {
            if self.health_ledger.active(incident) != (alert.category == Category::Incident) {
                return Delivery::default();
            }
        }
        pending.delivery_now(&self.preferences, now)
    }

    pub fn validate_notification_target(&self, target: &Target) -> Result<()> {
        if let Target::Notice { id } = target {
            if !self
                .attention
                .notices
                .values()
                .any(|notice| &notice.id == id)
            {
                return Err("This notification's session notice expired, was cleared, or was superseded. No other session was selected.".into());
            }
        }
        Ok(())
    }
    pub fn test_notification(&mut self, now: f64) -> Result<bool> {
        if let Some(pending) = self.notifier.test(&self.preferences, &self.store, now)? {
            self.enqueue_notification(pending);
            Ok(true)
        } else {
            Ok(false)
        }
    }

    pub fn begin_health(&mut self) -> Result<u64> {
        if !self.preferences.service_health {
            return Err("Public GitHub service checks are disabled.".into());
        }
        if self.health_busy {
            return Err("A service status check is already running.".into());
        }
        self.health_busy = true;
        Ok(self.health_generation)
    }

    pub fn finish_health(
        &mut self,
        generation: u64,
        result: Result<BTreeMap<String, bool>>,
        now: f64,
    ) -> Result<()> {
        if generation != self.health_generation || !self.preferences.service_health {
            return Ok(());
        }
        self.health_busy = false;
        let incidents = match result {
            Ok(incidents) => incidents,
            Err(message) => {
                self.health_error = Some(format!("{message} Status is unavailable; this is not evidence of an incident or recovery."));
                return Err(self.health_error.clone().expect("assigned health error"));
            }
        };
        let (baseline, changes) = match self.health_ledger.observe(&incidents) {
            Ok(value) => value,
            Err(message) => {
                self.health_error = Some(message.clone());
                return Err(message);
            }
        };
        self.health = Some(json!({"status":if self.health_ledger.active_count() > 0 {
            "One or more Copilot incidents await explicit resolution"
        } else { "No Copilot incident reported" },"observedAt":now,"activeIncidents":self.health_ledger.active_count()}));
        self.health_error = None;
        match self
            .notifier
            .service(&changes, baseline, &self.preferences, &self.store, now)
        {
            Ok(pending) => {
                for alert in pending {
                    self.enqueue_notification(alert);
                }
            }
            Err(message) => {
                self.notification_error = Some(message.clone());
                return Err(message);
            }
        }
        Ok(())
    }
}

pub fn warn(shared: &Shared, message: &str) {
    if let Ok(mut state) = shared.lock() {
        state.warning = Some(message.into());
    } else {
        eprintln!("Tokenotch collection state is unavailable.");
    }
}

pub fn collection_gap(shared: &Shared, sources: &[UsageSource], message: &str) {
    if let Ok(mut state) = shared.lock() {
        state.warning = Some(message.into());
        if let Err(message) = state.coverage_gap(sources, now_ms()) {
            state.warning = Some(message);
        }
    } else {
        eprintln!("Tokenotch collection state is unavailable.");
    }
}

pub async fn commit_import(shared: Shared, fingerprint: String) -> Result<usize> {
    let state = shared.clone();
    let (preview, generation) = tokio::task::spawn_blocking(move || {
        let (preview, generation) = {
            let mut state = state.lock().map_err(|_| "Archive state is unavailable.")?;
            if !state.preferences.history {
                return Err("Enable usage history before saving an import.".to_owned());
            }
            let preview = state
                .pending_import
                .take()
                .ok_or("Preview the export before importing.")?;
            if preview.fingerprint != fingerprint {
                return Err("Import approval does not match the preview.".into());
            }
            if state.archive.is_none() {
                return Err("The history archive is unavailable.".into());
            }
            (preview, state.import_generation)
        };
        preview.verify()?;
        Ok((preview, generation))
    })
    .await
    .map_err(|_| "Export verification could not finish.")??;

    let mut events = preview.events.into_iter();
    let mut calls = 0;
    loop {
        // Bound each transaction and release the runtime between batches so live
        // delivery can still meet the hook's 900 ms acknowledgement deadline.
        let batch: Vec<_> = events.by_ref().take(64).collect();
        let finished = batch.is_empty();
        let state = shared.clone();
        calls += tokio::task::spawn_blocking(move || {
            let mut state = state.lock().map_err(|_| "Archive state is unavailable.")?;
            if !state.preferences.history || state.import_generation != generation {
                return Err("Import stopped because usage history was paused or cleared. Preview the export again to resume; already saved calls will not be duplicated.".to_owned());
            }
            let prefs = state.preferences.clone();
            let archive = state
                .archive
                .as_mut()
                .ok_or("The history archive is unavailable.")?;
            let result = if finished {
                archive.prune(prefs.retention_days, now_ms()).map(|()| 0)
            } else {
                archive.record_batch(&batch, &prefs, true)
            };
            match result {
                Ok(count) => Ok(count),
                Err(message) => state.archive_failure(message),
            }
        })
        .await
        .map_err(|_| "Export import could not finish; preview again to resume without duplicating saved calls.")??;
        if finished {
            return Ok(calls);
        }
        tokio::task::yield_now().await;
    }
}

pub async fn refresh_account(shared: Shared, login: bool) -> Result<()> {
    let (configured, detected, store, home, prefer_shared) = {
        let mut state = shared.lock().map_err(|_| "Account state is unavailable.")?;
        if !state.preferences.account_enabled {
            return Err("Account quota is disabled.".into());
        }
        if state.account_busy {
            return Err("An account operation is already running.".into());
        }
        state.account_busy = true;
        (
            state
                .preferences
                .cli_executable
                .clone()
                .map(std::path::PathBuf::from),
            state.account_cli.clone(),
            state.store.clone(),
            state.connections.cli_home.clone(),
            state.account_shared,
        )
    };
    let result = async {
        let path = match configured.or(detected) {
            Some(path) => path,
            None => crate::account::detect_cli().await.ok_or(
                "GitHub Copilot CLI was not found. Install it (winget install GitHub.Copilot), or choose copilot.exe under Usage > Copilot plan.",
            )?,
        };
        let mut snapshot =
            crate::account::snapshot(&path, &store, Some(&home), prefer_shared).await;
        let signed_out = snapshot
            .as_ref()
            .is_ok_and(|v| v.authentication == Authentication::SignedOut);
        if login && signed_out {
            crate::account::sign_in(&path, &store).await?;
            snapshot = crate::account::snapshot(&path, &store, Some(&home), false).await;
        }
        Ok::<_, String>((path, snapshot))
    }
    .await;
    let mut state = shared.lock().map_err(|_| "Account state is unavailable.")?;
    state.account_busy = false;
    if !state.preferences.account_enabled {
        state.account = None;
        state.account_auth = Authentication::Unknown;
        return Ok(());
    }
    let result = match result {
        Ok((path, snapshot)) => {
            if state.preferences.cli_executable.is_none() {
                state.account_cli = Some(path);
            }
            snapshot
        }
        Err(message) => Err(message),
    };
    state.finish_account(result)
}

impl Runtime {
    pub fn finish_account(&mut self, result: Result<crate::account::Snapshot>) -> Result<()> {
        let quota = match result {
            Ok(snapshot) => {
                if self.account.as_ref().is_some_and(|account| {
                    !matches!(&snapshot.authentication, Authentication::SignedIn { login, .. } if *login == account.login)
                }) {
                    self.account = None;
                }
                self.account_auth = snapshot.authentication;
                self.account_shared = snapshot.shared;
                snapshot.quota
            }
            Err(message) => {
                self.account_auth = Authentication::Unknown;
                Err(message)
            }
        };
        match quota {
            Ok(account) => {
                self.account = Some(account);
                self.account_error = None;
                Ok(())
            }
            Err(message) => {
                self.account_error = Some(message.clone());
                Err(message)
            }
        }
    }
}

pub async fn refresh_health(shared: Shared) -> Result<()> {
    let generation = shared
        .lock()
        .map_err(|_| "Service status is unavailable.")?
        .begin_health()?;
    let result = async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "Public status client unavailable.")?;
        let mut response = client
            .get("https://www.githubstatus.com/api/v2/summary.json")
            .send()
            .await
            .map_err(|_| "GitHub public service status could not be fetched.")?
            .error_for_status()
            .map_err(|_| "GitHub status service returned an error.")?;
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "GitHub status response is unavailable.")?
        {
            if bytes.len() + chunk.len() > 262_144 {
                return Err("GitHub status response is too large.".to_owned());
            }
            bytes.extend_from_slice(&chunk);
        }
        notifications::parse_health(&bytes)
    }
    .await;
    let mut state = shared.lock().map_err(|_| "Service state unavailable.")?;
    state.finish_health(generation, result, now_ms())
}

#[cfg(windows)]
pub fn start_pipe(shared: Shared) -> Result<()> {
    use tokio::{
        io::AsyncWriteExt,
        time::{timeout, Duration},
    };
    let mut pipe = transport::server(true)?;
    {
        let mut state = shared
            .lock()
            .map_err(|_| "Collection state is unavailable.")?;
        state.pipe_running = true;
        if let Err(message) = state.checkpoint(now_ms(), false) {
            state.pipe_running = false;
            return Err(message);
        }
    }
    tokio::spawn(async move {
        let permits = Arc::new(tokio::sync::Semaphore::new(8));
        loop {
            if pipe.connect().await.is_err() {
                warn(&shared, "The private event pipe stopped.");
                break;
            }
            let next = match transport::server(false) {
                Ok(value) => value,
                Err(message) => {
                    warn(&shared, &message);
                    break;
                }
            };
            let mut connected = std::mem::replace(&mut pipe, next);
            let Ok(permit) = permits.clone().try_acquire_owned() else {
                collection_gap(
                    &shared,
                    &[UsageSource::Cli],
                    "Local event capacity exceeded; observations may be missing.",
                );
                continue;
            };
            let state = shared.clone();
            tokio::spawn(async move {
                let _permit = permit;
                let result = timeout(Duration::from_secs(2), async {
                    let bytes = transport::read_frame(&mut connected).await?;
                    let envelope: Envelope = serde_json::from_slice(&bytes)
                        .map_err(|_| "Invalid local event envelope.")?;
                    state
                        .lock()
                        .map_err(|_| "Collection state is unavailable.")?
                        .accept(envelope)
                })
                .await;
                let accepted = matches!(result, Ok(Ok(())));
                match result {
                    Ok(Err(message)) => warn(&state, &message),
                    Err(_) => collection_gap(
                        &state,
                        &[UsageSource::Cli],
                        "Local event delivery timed out.",
                    ),
                    _ => {}
                }
                let _ = timeout(
                    Duration::from_millis(200),
                    connected.write_u8(u8::from(accepted)),
                )
                .await;
            });
        }
        if let Ok(mut state) = shared.lock() {
            state.pipe_running = false;
            if let Err(message) = state.checkpoint(now_ms(), true) {
                state.warning = Some(message);
            }
        }
    });
    Ok(())
}

#[cfg(not(windows))]
pub fn start_pipe(_: Shared) -> Result<()> {
    Err("Native collection requires Windows.".into())
}

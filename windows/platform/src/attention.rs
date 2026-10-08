use crate::{
    preferences::Preferences,
    storage::{random_id, Result, Store},
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use tokenotch_core::hook::{digest, EventKind, Observation, Source};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Notice {
    pub id: String,
    pub session: String,
    pub source: Source,
    pub kind: String,
    pub timestamp: f64,
    pub viewed: bool,
    pub dismissed: bool,
    pub resolved: bool,
    pub restored: bool,
}
#[derive(Serialize, Deserialize)]
struct Saved {
    key: String,
    notices: Vec<Notice>,
}
pub struct Attention {
    key: String,
    pub notices: BTreeMap<String, Notice>,
    saved: BTreeMap<String, Notice>,
    contexts: BTreeMap<String, (f64, f64)>,
    pub capacity_reached: bool,
}

impl Attention {
    pub fn open(store: &Store, remember: bool) -> Result<Self> {
        let mut result = Self {
            key: random_id()?,
            notices: BTreeMap::new(),
            saved: BTreeMap::new(),
            contexts: BTreeMap::new(),
            capacity_reached: false,
        };
        if remember {
            if let Some(saved) = store.load::<Saved>("notices.json")? {
                if saved.key.len() != 64 || saved.notices.len() > 100 {
                    return Err("Saved notices are invalid.".into());
                }
                result.key = saved.key;
                for mut notice in saved.notices {
                    notice.restored = true;
                    result.saved.insert(notice.session.clone(), notice.clone());
                    result.notices.insert(notice.session.clone(), notice);
                }
            }
        }
        Ok(result)
    }

    pub fn observe(
        &mut self,
        event: &Observation,
        prefs: &Preferences,
        store: &Store,
        now: f64,
    ) -> Result<Option<Notice>> {
        let session = digest(&format!(
            "{}:{:?}:{}",
            self.key, event.source, event.session
        ));
        let previous = self.notices.get(&session);
        if previous.is_some_and(|notice| notice.timestamp >= event.timestamp_unix_ms) {
            return Ok(None);
        }
        let kind = match event.kind {
            EventKind::Stopped => Some("stopped"),
            EventKind::Failed | EventKind::UnrecoverableError => Some("error"),
            EventKind::InputRequested => Some("inputRequested"),
            EventKind::ApprovalRequested => Some("approvalRequested"),
            EventKind::Compaction
                if event
                    .compaction
                    .as_ref()
                    .is_some_and(|v| v.success == Some(false)) =>
            {
                Some("compactionFailed")
            }
            EventKind::Context => {
                let value = event
                    .context
                    .as_ref()
                    .ok_or("Context observation is missing its reading.")?;
                let fraction = value.current_tokens as f64 / value.token_limit as f64;
                let old = self
                    .contexts
                    .insert(session.clone(), (fraction, event.timestamp_unix_ms));
                if old.is_some_and(|(old, at)| {
                    old < 0.8 && fraction >= 0.8 && event.timestamp_unix_ms - at <= 300_000.0
                }) {
                    Some("highContext")
                } else {
                    None
                }
            }
            _ => None,
        };
        let mut new_notice = None;
        if let Some(kind) = kind {
            // Activity stops do not erase unresolved requests/errors, nor prove success.
            let preserve = previous.is_some_and(|n| {
                !n.resolved
                    && !n.dismissed
                    && (n.kind != "stopped" && kind == "stopped"
                        || ["error", "inputRequested", "approvalRequested"]
                            .contains(&n.kind.as_str())
                            && ["highContext", "compactionFailed"].contains(&kind))
            });
            let duplicate_error =
                kind == "error" && previous.is_some_and(|n| n.kind == "error" && !n.resolved);
            if !preserve && !duplicate_error {
                let notice = Notice {
                    id: digest(&format!("{session}:{kind}:{}", event.timestamp_unix_ms)),
                    session: session.clone(),
                    source: event.source,
                    kind: kind.into(),
                    timestamp: event.timestamp_unix_ms,
                    viewed: false,
                    dismissed: false,
                    resolved: false,
                    restored: false,
                };
                self.notices.insert(session.clone(), notice.clone());
                if prefs.remember_notices {
                    self.saved.insert(session.clone(), notice.clone());
                }
                new_notice = Some(notice);
            }
        } else {
            // A model call after the notice means the session resumed, e.g. the user
            // answered or approved directly in the client without a new prompt.
            let resumed = event.kind == EventKind::Usage
                && event.tokens.is_some()
                && previous.is_some_and(|n| {
                    ["inputRequested", "approvalRequested", "error", "stopped"]
                        .contains(&n.kind.as_str())
                });
            let resolves = event.kind == EventKind::Working
                || resumed
                || matches!(event.kind, EventKind::Ended | EventKind::Cancelled)
                || event.kind == EventKind::ContextInvalidated
                    && previous.is_some_and(|n| n.kind == "highContext")
                || event
                    .compaction
                    .as_ref()
                    .is_some_and(|v| v.success == Some(true))
                    && previous.is_some_and(|n| n.kind == "compactionFailed");
            if resolves {
                if let Some(notice) = self.notices.get_mut(&session) {
                    notice.resolved = true;
                    if prefs.remember_notices && self.saved.contains_key(&session) {
                        self.saved.insert(session.clone(), notice.clone());
                    }
                }
            }
        }
        if event.kind == EventKind::ContextInvalidated {
            self.contexts.remove(&session);
        }
        self.prune(now);
        if prefs.remember_notices {
            self.persist(store)?;
        }
        Ok(new_notice)
    }

    fn prune(&mut self, now: f64) {
        self.notices.retain(|_, n| {
            !(n.resolved || n.dismissed || n.viewed && n.kind == "stopped")
                || now - n.timestamp < 7.0 * 86_400_000.0
        });
        while self.notices.len() > 100 {
            if let Some(key) = self
                .notices
                .iter()
                .min_by(|a, b| a.1.timestamp.total_cmp(&b.1.timestamp))
                .map(|(key, _)| key.clone())
            {
                self.notices.remove(&key);
                self.capacity_reached = true;
            }
        }
        self.saved.retain(|key, _| self.notices.contains_key(key));
        self.contexts
            .retain(|_, (_, time)| now - *time < 86_400_000.0);
        while self.contexts.len() > 100 {
            let key = self
                .contexts
                .keys()
                .next()
                .cloned()
                .expect("nonempty bounded context map");
            self.contexts.remove(&key);
        }
    }

    pub fn acknowledge(
        &mut self,
        id: &str,
        dismiss: bool,
        store: &Store,
        remember: bool,
    ) -> Result<()> {
        let notice = self
            .notices
            .values_mut()
            .find(|n| n.id == id)
            .ok_or("This notice is no longer available.")?;
        notice.viewed = true;
        if dismiss {
            notice.dismissed = true;
        }
        if self.saved.contains_key(&notice.session) {
            self.saved.insert(notice.session.clone(), notice.clone());
        }
        if remember {
            self.persist(store)?;
        }
        Ok(())
    }

    pub fn remember(&mut self, store: &Store, enabled: bool) -> Result<()> {
        self.saved.clear();
        if enabled {
            self.persist(store)
        } else {
            store.remove("notices.json")
        }
    }
    fn persist(&self, store: &Store) -> Result<()> {
        store.save(
            "notices.json",
            &Saved {
                key: self.key.clone(),
                notices: self.saved.values().cloned().collect(),
            },
        )
    }
}

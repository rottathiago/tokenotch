use crate::storage::Result;
use chrono::Timelike;
use serde::{Deserialize, Serialize};
use tokenotch_core::placement::Edge;

#[derive(Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct Preferences {
    pub edge: Edge,
    pub widget_visible: bool,
    pub collapse_idle: bool,
    pub auto_hide_notch: bool,
    pub hide_fullscreen: bool,
    pub display: Option<String>,
    pub all_displays: bool,
    pub position: f64,
    pub scale: f64,
    pub text_scale: f64,
    pub reduce_motion: bool,
    pub reduce_transparency: bool,
    pub time_format: String,
    pub history: bool,
    pub timelines: bool,
    pub retention_days: u32,
    pub remember_notices: bool,
    pub notifications: bool,
    pub mute_notifications: bool,
    pub desktop_banner: bool,
    pub sound: bool,
    pub expand_card: bool,
    pub notify_stopped: bool,
    pub notify_errors: bool,
    pub notify_requests: bool,
    pub notify_context: bool,
    pub notify_incidents: bool,
    pub notify_recovery: bool,
    pub quiet_hours: bool,
    pub quiet_start: u32,
    pub quiet_end: u32,
    pub snoozed_until: f64,
    pub service_health: bool,
    pub vscode_metrics: bool,
    pub account_enabled: bool,
    pub cli_executable: Option<String>,
    pub onboarding_complete: bool,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            edge: Edge::Right,
            widget_visible: true,
            collapse_idle: true,
            auto_hide_notch: false,
            hide_fullscreen: true,
            display: None,
            all_displays: false,
            position: 0.5,
            scale: 1.0,
            text_scale: 1.0,
            reduce_motion: false,
            reduce_transparency: false,
            time_format: "24".into(),
            history: true,
            timelines: false,
            retention_days: 7,
            remember_notices: false,
            notifications: false,
            mute_notifications: false,
            desktop_banner: true,
            sound: false,
            expand_card: false,
            notify_stopped: true,
            notify_errors: true,
            notify_requests: false,
            notify_context: false,
            notify_incidents: false,
            notify_recovery: false,
            quiet_hours: false,
            quiet_start: 22 * 60,
            quiet_end: 8 * 60,
            snoozed_until: 0.0,
            service_health: false,
            vscode_metrics: false,
            account_enabled: false,
            cli_executable: None,
            onboarding_complete: false,
        }
    }
}

impl Preferences {
    pub fn validate(&self) -> Result<()> {
        if !self.position.is_finite() || !(0.0..=1.0).contains(&self.position) {
            return Err("Choose a position within the screen edge.".into());
        }
        if ![1, 7, 30].contains(&self.retention_days)
            || !["12", "24"].contains(&self.time_format.as_str())
            || !self.scale.is_finite()
            || !(0.75..=1.5).contains(&self.scale)
            || !self.text_scale.is_finite()
            || !(1.0..=2.0).contains(&self.text_scale)
            || self.quiet_start >= 1440
            || self.quiet_end >= 1440
            || !self.snoozed_until.is_finite()
            || self.display.as_ref().is_some_and(|value| value.len() > 256)
        {
            return Err("Unsupported preference value.".into());
        }
        Ok(())
    }

    pub fn allows_notification(&self, now: f64) -> bool {
        if !now.is_finite()
            || !self.notifications
            || self.mute_notifications
            || now < self.snoozed_until
        {
            return false;
        }
        crate::calendar::date(now).is_ok_and(|at| self.allows_at(at.with_timezone(&chrono::Local)))
    }
    pub fn allows_at<T: chrono::TimeZone>(&self, at: chrono::DateTime<T>) -> bool {
        if !self.notifications
            || self.mute_notifications
            || (at.timestamp_millis() as f64) < self.snoozed_until
        {
            return false;
        }
        let minute = at.hour() * 60 + at.minute();
        !self.quiet_hours
            || if self.quiet_start < self.quiet_end {
                minute < self.quiet_start || minute >= self.quiet_end
            } else {
                minute < self.quiet_start && minute >= self.quiet_end
            }
    }
}

use crate::storage::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum DetailKind {
    History,
    Live,
    Timeline,
    Insight,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DetailRequest {
    pub kind: DetailKind,
    pub captured_at: f64,
    pub archive_id: Option<String>,
    pub data: Value,
}
impl DetailRequest {
    pub fn validate(&self, generation: Option<&str>) -> Result<()> {
        if !self.captured_at.is_finite()
            || !self.data.is_object()
            || serde_json::to_vec(self)
                .map_err(|_| "The selected detail could not be encoded.")?
                .len()
                > 4 * 1_048_576
        {
            return Err(
                "The selected detail is invalid or too large. Narrow the selected period.".into(),
            );
        }
        if self.archive_id.as_deref() != generation || generation.is_none() {
            return Err("This selected detail was cleared or is no longer available. Reload the original view.".into());
        }
        Ok(())
    }
}

#[derive(Default)]
pub struct DetailInbox {
    pending: Option<(f64, DetailRequest)>,
}
impl DetailInbox {
    pub fn put(&mut self, request: DetailRequest, now: f64) {
        self.pending = Some((now + 600_000.0, request));
    }
    pub fn take(&mut self, now: f64) -> Result<Option<DetailRequest>> {
        match self.pending.take() {
            Some((expires, _)) if now >= expires => {
                Err("This navigation target expired. Select it again in the original view.".into())
            }
            Some((_, request)) => Ok(Some(request)),
            None => Ok(None),
        }
    }
}

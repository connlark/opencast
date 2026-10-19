//! Values read before publisher I/O and the exact witnesses used at settlement.
use super::polling::Fence;
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bound {
    pub feed_id: String,
    pub started_at: i64,
    pub epoch: i64,
    pub eligibility: i64,
    /// Generation and nullable success token read before publisher I/O. A
    /// replacement token proves a success occurred; integer seconds cannot
    /// order duplicate scans. Unknown never permits replay of this request.
    pub generation: i64,
    pub token: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Reservation {
    pub snapshot: String,
    pub lease: String,
    pub observation: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Processing {
    pub observation: String,
    pub token: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Checkpoint {
    pub feed: String,
    pub epoch: i64,
    pub eligibility: i64,
    /// Published generation read before this scan (not its next generation).
    pub generation: i64,
    pub processing: Option<Processing>,
    pub poll: Option<Fence>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Schedule {
    pub due_at: i64,
    pub credible_release_at: Option<i64>,
    pub credible_cadence: Option<i64>,
    pub publish_cadence: Option<i64>,
    pub outcome: String,
}
impl From<&crate::polling::Settle> for Schedule {
    fn from(value: &crate::polling::Settle) -> Self {
        Self {
            due_at: value.due_at,
            credible_release_at: value.credible_release_at,
            credible_cadence: value.credible_cadence,
            publish_cadence: value.publish_cadence,
            outcome: value.outcome.into(),
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Unchanged {
    pub checkpoint: Checkpoint,
    pub started_at: i64,
    pub token: String,
    pub etag: Option<String>,
    pub modified: Option<String>,
    pub url: Option<String>,
    /// None means a 304; Some is the already snapshot-bound parsed-200 digest.
    pub bound_digest: Option<String>,
    pub schedule: Option<Schedule>,
}

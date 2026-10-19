//! Closed observation/catalog requests. R2 bytes and clients never cross this seam.
use super::{decode_failure, Failure, Kind, Outcome, Parameter, Phase, Reply, Response, Result};
use super::{observations::Checkpoint, polling::Fence};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scan {
    pub checkpoint: Checkpoint,
    /// None retains the source's deferred (unclaimed) fence.
    pub lease: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Staging {
    pub feed: String,
    pub epoch: i64,
    pub eligibility: i64,
    pub generation: i64,
    pub lease: String,
    pub observation: String,
    pub snapshot: String,
    pub started_at: i64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Page {
    pub key: String,
    pub sha256: String,
    pub bytes: i64,
    pub index: String,
    // Preserve the complete source page JSON at the storage boundary.
    #[serde(default)]
    pub count: i64,
    #[serde(default)]
    pub first_hash: String,
    #[serde(default)]
    pub last_hash: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Publication {
    pub scan: Scan,
    pub observation: String,
    pub manifest: String,
    pub pages: Vec<Page>,
    pub generation: i64,
    pub token: String,
    pub started_at: i64,
    pub candidate_count: i64,
    pub counts_json: String,
    pub metadata_json: String,
    pub bound_digest: Option<String>,
    pub etag: Option<String>,
    pub modified: Option<String>,
    pub validator_url: Option<String>,
    pub credible_release_at: Option<i64>,
    pub credible_cadence: Option<i64>,
    pub publish_cadence: Option<i64>,
    pub undated: i64,
    pub due_at: Option<i64>,
    pub withdrawn: Vec<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    ReadSettled {
        feed: String,
    },
    ReadPreparationWait {
        feed: String,
    },
    ClaimScan {
        checkpoint: Checkpoint,
        lease: String,
        now: i64,
    },
    ReadPriorStart {
        feed: String,
        since: i64,
    },
    Materialize {
        staging: Staging,
    },
    ReadObject {
        key: String,
    },
    ReservePages {
        scan: Scan,
        keys: Vec<String>,
        started_at: i64,
        now: i64,
    },
    UploadPages {
        scan: Scan,
        pages: Vec<Page>,
        now: i64,
    },
    ReleaseUnused {
        keys: Vec<String>,
        lease: String,
    },
    ReserveManifest {
        scan: Scan,
        manifest: Page,
        pages: Vec<Page>,
        now: i64,
    },
    MarkManifestUploaded {
        scan: Scan,
        key: String,
        now: i64,
    },
    Publish {
        publication: Publication,
        now: i64,
    },
    ReadFence {
        scan: Scan,
        now: i64,
    },
    Checkpoint {
        scan: Scan,
        observation: String,
        key: String,
        now: i64,
    },
    ClaimPreparation {
        feed: String,
        token: String,
        poll: Option<Fence>,
        now: i64,
    },
    ReadPreparation {
        feed: String,
        token: String,
    },
    ExtendPreparationLease {
        feed: String,
        lease: String,
        token: String,
        now: i64,
    },
    ReadPendingFuture {
        feed: String,
        cursor: String,
    },
    PreparationFailed {
        observation: String,
        token: Option<String>,
        now: i64,
    },
}
impl Operation {
    pub fn is_read(&self) -> bool {
        matches!(
            self,
            Self::ReadSettled { .. }
                | Self::ReadPreparationWait { .. }
                | Self::ReadPriorStart { .. }
                | Self::ReadObject { .. }
                | Self::ReadFence { .. }
                | Self::ReadPreparation { .. }
                | Self::ReadPendingFuture { .. }
        )
    }
    pub fn id(&self) -> &'static str {
        use Operation::*;
        match self {
            ReadSettled { .. } => "read_settled",
            ReadPreparationWait { .. } => "read_preparation_wait",
            ClaimScan { .. } => "b_claim_scan",
            ReadPriorStart { .. } => "b_prior_start",
            Materialize { .. } => "B13",
            ReadObject { .. } => "b_read_object",
            ReservePages { .. } => "b_reserve_pages",
            UploadPages { .. } => "b_upload_pages",
            ReleaseUnused { .. } => "b_release_unused",
            ReserveManifest { .. } => "B14",
            MarkManifestUploaded { .. } => "b_manifest_uploaded",
            Publish { .. } => "B15",
            ReadFence { .. } => "b_read_fence",
            Checkpoint { .. } => "b_checkpoint",
            ClaimPreparation { .. } => "b_claim_preparation",
            ReadPreparation { .. } => "b_read_preparation",
            ExtendPreparationLease { .. } => "b_extend_preparation_lease",
            ReadPendingFuture { .. } => "b_pending_future",
            PreparationFailed { .. } => "b_preparation_failed",
        }
    }
}
pub(super) fn validate(operation: &Operation) -> Result<()> {
    fn numbers(value: &Value) -> bool {
        match value {
            Value::Number(n) => n
                .as_i64()
                .is_some_and(|n| Parameter::Integer(Some(n)).validate().is_ok()),
            Value::Array(a) => a.iter().all(numbers),
            Value::Object(o) => o.values().all(numbers),
            _ => true,
        }
    }
    if serde_json::to_value(operation).is_ok_and(|v| numbers(&v)) {
        return Ok(());
    }
    let mut error = Failure::new(Kind::Assertion, Phase::Transaction);
    if operation.is_read() {
        error.outcome = Outcome::NotApplicable;
    }
    Err(error)
}
// Full source row shapes, including nullable fields; no missing field becomes a
// caller's null/zero default. Text stays byte-exact (including JSON text).
pub(super) fn validate_rows(operation: &Operation, replies: &[Reply]) -> Result<()> {
    let (text, integer, nullable): (&[&str], &[&str], &[&str]) = match operation {
        Operation::ReadSettled { .. } => (&[], &["1"], &[]),
        Operation::ReadPreparationWait { .. } => (
            &[],
            &["processing_next_at", "processing_until"],
            &["processing_until"],
        ),
        Operation::ReadPriorStart { .. } => (&[], &["started"], &["started"]),
        Operation::ReadObject { .. } => (&["sha256"], &["bytes"], &[]),
        Operation::ReadFence { .. } => (&[], &["1"], &[]),
        Operation::ReadPendingFuture { .. } => {
            (&["episode_id", "fingerprint"], &[], &["fingerprint"])
        }
        Operation::ReadPreparation { .. } => (
            &[
                "observation_id",
                "feed_id",
                "lease_id",
                "snapshot_key",
                "candidate_storage",
                "reason_counts_json",
                "state",
                "etag",
                "last_modified",
                "metadata_json",
                "preparation_key",
                "processing_token",
            ],
            &[
                "generation",
                "owner_epoch",
                "expected_generation",
                "scan_started_at",
                "completed_at",
                "candidate_count",
                "staged_count",
                "valid_eof",
                "spooled_count",
                "candidate_cursor",
                "eligibility_generation",
                "drain_complete",
                "recovery_evidence",
                "processing_until",
                "processing_failures",
                "processing_next_at",
            ],
            &[
                "completed_at",
                "etag",
                "last_modified",
                "preparation_key",
                "processing_token",
                "processing_until",
            ],
        ),
        _ => (&[], &[], &[]),
    };
    for reply in replies {
        for row in &reply.rows {
            let object = row
                .as_object()
                .ok_or_else(|| decode_failure(operation.is_read()))?;
            if object.len() != text.len() + integer.len() || object.is_empty() {
                return Err(decode_failure(operation.is_read()));
            }
            for field in text.iter().chain(integer) {
                let v = object
                    .get(*field)
                    .ok_or_else(|| decode_failure(operation.is_read()))?;
                let valid = (v.is_null() && nullable.contains(field))
                    || if text.contains(field) {
                        v.is_string()
                    } else {
                        v.as_i64()
                            .is_some_and(|n| Parameter::Integer(Some(n)).validate().is_ok())
                    };
                if !valid {
                    return Err(decode_failure(operation.is_read()));
                }
            }
        }
    }
    Ok(())
}
/// Dispatch through the enclosing invocation's authority.
pub async fn execute(
    authority: &super::Authority,
    operation: Operation,
) -> worker::Result<Response> {
    match authority.bound(operation.id(), operation.is_read()).await? {
        super::authority::Backend::Postgres(env) => {
            let (cancel, deadline) = authority.context();
            let result = execute_postgres(env, &operation, cancel.clone(), deadline).await;
            result.map_err(|failure| {
                worker::Error::RustError(format!(
                    "storage_{}_{:?}_{:?}",
                    operation.id(),
                    failure.kind,
                    failure.outcome
                ))
            })
        }
    }
}
pub(super) async fn execute_postgres(
    env: &worker::Env,
    operation: &Operation,
    cancel: opencast_worker_database_core::database::Cancellation,
    deadline: u64,
) -> Result<Response> {
    super::postgres::slice_b::execute(env, operation, cancel, deadline).await
}

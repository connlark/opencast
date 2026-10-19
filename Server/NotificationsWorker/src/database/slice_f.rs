//! Closed control and ingress requests. Each source run/read remains a separate operation.
use super::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Admission {
    pub source: String,
    pub event: String,
    pub kind: String,
    pub digest: String,
    pub occurred_at: i64,
    pub eligible_at: i64,
    pub expires_at: i64,
    pub receipt: String,
    pub envelope_json: String,
    pub now: i64,
    pub disposition: String,
    pub feed: Option<String>,
    pub interest: Option<String>,
    pub epoch: Option<i64>,
    pub observation: Option<String>,
    pub observation_generation: Option<i64>,
    pub interest_generation: Option<i64>,
    pub run_id: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub interest: String,
    pub generation: i64,
    pub producer: String,
    pub operation_id: String,
    pub requester_ref: String,
    pub grant_digest: String,
    pub run_id: String,
    pub job_handle: String,
    pub accepted_at: i64,
    pub now: i64,
    pub receipt: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Cancellation {
    pub interest: String,
    pub generation: i64,
    pub producer: String,
    pub run_id: Option<String>,
    pub grant_digest: Option<String>,
    pub operation_id: Option<String>,
    pub requester_ref: Option<String>,
    pub reason: String,
    pub receipt: String,
}
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedAction {
    Pause,
    PauseSends,
    Resume,
    ResumeSends,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    ReadEvent {
        source: String,
        event: String,
    },
    ReadInterest {
        interest: String,
    },
    AdmitEvent {
        admission: Admission,
    },
    RegisterInterest {
        registration: Registration,
    },
    CancelInterest {
        cancellation: Cancellation,
    },
    SuppressDeliveries {
        interest: String,
        now: i64,
    },
    InspectFeed {
        feed: String,
    },
    ChangeFeed {
        feed: String,
        epoch: i64,
        now: i64,
        action: FeedAction,
    },
    ReadSuppression {
        interest: String,
    },
    ReadRollup {
        now: i64,
    },
}
impl Operation {
    pub fn is_read(&self) -> bool {
        matches!(
            self,
            Self::ReadEvent { .. }
                | Self::ReadInterest { .. }
                | Self::InspectFeed { .. }
                | Self::ReadSuppression { .. }
                | Self::ReadRollup { .. }
        )
    }
    pub fn id(&self) -> &'static str {
        match self {
            Self::ReadEvent { .. } => "read_event",
            Self::ReadInterest { .. } => "read_interest",
            Self::AdmitEvent { .. } => "admit_event",
            Self::RegisterInterest { .. } => "register_interest",
            Self::CancelInterest { .. } => "cancel_interest",
            Self::SuppressDeliveries { .. } => "suppress_deliveries",
            Self::InspectFeed { .. } => "inspect_feed",
            Self::ChangeFeed { .. } => "change_feed",
            Self::ReadSuppression { .. } => "read_suppression",
            Self::ReadRollup { .. } => "read_rollup",
        }
    }
    /// Read durable operation-specific evidence after Unknown. Evidence is not an
    /// acknowledgement: concurrent writers may have superseded it. Never replay here.
    pub fn readback(&self) -> Option<Self> {
        match self {
            Self::AdmitEvent { admission: a } => Some(Self::ReadEvent {
                source: a.source.clone(),
                event: a.event.clone(),
            }),
            Self::RegisterInterest { registration: r } => Some(Self::ReadInterest {
                interest: r.interest.clone(),
            }),
            Self::CancelInterest { cancellation: c } => Some(Self::ReadInterest {
                interest: c.interest.clone(),
            }),
            Self::SuppressDeliveries { interest, .. } => Some(Self::ReadSuppression {
                interest: interest.clone(),
            }),
            Self::ChangeFeed { feed, .. } => Some(Self::InspectFeed { feed: feed.clone() }),
            _ => None,
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
pub(super) fn validate_rows(operation: &Operation, replies: &[Reply]) -> Result<()> {
    if let Operation::ReadRollup { now } = operation {
        return super::rows::validate(&polling::Operation::ReadRollup { now: *now }, replies);
    }
    let fields: &[(&str, bool, bool)] = match operation {
        Operation::ReadEvent { .. } => &[
            ("source", false, false),
            ("event_id", false, false),
            ("schema_version", true, false),
            ("kind", false, false),
            ("payload_digest", false, false),
            ("occurred_at", true, false),
            ("eligible_at", true, false),
            ("expires_at", true, false),
            ("receipt_id", false, false),
            ("envelope_json", false, false),
            ("fanout_cursor", false, true),
            ("fanout_complete", true, false),
            ("disposition", false, false),
            ("next_attempt_at", true, false),
            ("failures", true, false),
            ("lease_id", false, true),
            ("lease_until", true, true),
            ("terminal_at", true, true),
            ("feed_id", false, true),
            ("interest_id", false, true),
            ("owner_epoch", true, true),
        ],
        Operation::ReadInterest { .. } => &[
            ("install_id", false, false),
            ("install_epoch", true, false),
            ("operation_id", false, false),
            ("producer", false, false),
            ("requester_ref", false, false),
            ("generation", true, false),
            ("grant_digest", false, false),
            ("grant_nonce", false, false),
            ("grant_key_version", true, false),
            ("issued_at", true, false),
            ("accept_before", true, false),
            ("register_before", true, false),
            ("accepted_at", true, true),
            ("run_id", false, true),
            ("job_handle", false, true),
            ("state", false, false),
            ("seen_at", true, true),
            ("reason", false, true),
            ("interest_id", false, true),
            ("receipt_id", false, true),
            ("attempt_started_at", true, true),
            ("local_fallback_safe", true, true),
        ],
        Operation::InspectFeed { .. } => &[
            ("epoch", true, false),
            ("admission_paused", true, false),
            ("send_paused", true, false),
            ("dispatch_until", true, false),
            ("lease_until", true, true),
            ("observation_generation", true, false),
            ("poll_failures", true, false),
            ("handling_failures", true, false),
            ("last_poll_outcome", false, true),
            ("due_at", true, false),
            ("retry_at", true, false),
        ],
        Operation::ReadSuppression { .. } => &[("remaining", true, false)],
        _ => &[],
    };
    for reply in replies {
        for row in &reply.rows {
            let object = row
                .as_object()
                .ok_or_else(|| decode_failure(operation.is_read()))?;
            if object.len() != fields.len() || object.is_empty() {
                return Err(decode_failure(operation.is_read()));
            }
            for (name, integer, nullable) in fields {
                let v = object
                    .get(*name)
                    .ok_or_else(|| decode_failure(operation.is_read()))?;
                if !((v.is_null() && *nullable)
                    || if *integer {
                        v.as_i64()
                            .is_some_and(|n| Parameter::Integer(Some(n)).validate().is_ok())
                    } else {
                        v.is_string()
                    })
                {
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
            if result
                .as_ref()
                .is_err_and(|failure| failure.outcome == Outcome::Unknown)
            {
                // Observe closed witnesses under the same cancellation and cap.
                // Even a matching later row cannot reconstruct affected counts
                // or exclude superseding work. Keep Unknown; never replay or
                // authorize a send/object deletion from a lost acknowledgement.
                let readbacks = operation.readback().into_iter().collect::<Vec<_>>();
                for readback in readbacks {
                    let observed = execute_postgres(env, &readback, cancel.clone(), deadline).await;
                    // A digest of the witness rows, never a row value.
                    let witness = observed.as_ref().ok().map(|response| {
                        crate::database_identity::witness(
                            response.replies.iter().map(|reply| reply.rows.as_slice()),
                        )
                    });
                    worker::console_warn!(
                        "{}",
                        serde_json::json!({"event":"storage_unknown_readback","operation":operation.id(),"readback":readback.id(),"observed":observed.is_ok(),"witness":witness.as_ref().map(|(digest, _)| digest),"rows":witness.as_ref().map(|(_, rows)| rows),"settlement":"deferred"})
                    );
                }
            }
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

/// Local collector metadata has no secrets, URLs or installation identifiers.
/// Maintenance fencing has not shipped; reporting that gap prevents a collector
/// from treating a backend label as proof of a database-enforced write fence.
pub fn operational_identity() -> Value {
    serde_json::json!({"backend":"postgres","schema":"0004","maintenance":{"state":"not_implemented","write_fence_verified":false},"authority":"local_fixture"})
}

/// PostgreSQL entrypoint for a caller-owned, deadline-bounded storage segment.
pub(super) async fn execute_postgres(
    env: &worker::Env,
    operation: &Operation,
    cancel: opencast_worker_database_core::database::Cancellation,
    deadline: u64,
) -> Result<Response> {
    super::postgres::slice_f::execute(env, operation, cancel, deadline).await
}

//! Closed delivery and outbox operations. Network, queue and object I/O stay outside storage.
use super::{decode_failure, Failure, Kind, Outcome, Parameter, Phase, Reply, Response, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FanoutRecipient {
    pub delivery: String,
    pub install: String,
    pub epoch: i64,
    pub generation: i64,
    pub apns: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FanoutPage {
    pub episode: bool,
    pub source: String,
    pub event: String,
    pub lease: String,
    pub cursor: String,
    pub last: String,
    pub complete: bool,
    pub interest: String,
    pub expires_at: i64,
    pub now: i64,
    pub owner_epoch: Option<i64>,
    pub episode_id: Option<String>,
    pub fingerprint: Option<String>,
    pub run: Option<String>,
    pub recipients: Vec<FanoutRecipient>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BurstGroup {
    pub delivery: String,
    pub presentation: String,
    pub route_event: String,
    pub expires_at: i64,
    pub apns: String,
    pub events: Vec<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BurstPage {
    pub presentation: String,
    pub lease: String,
    pub now: i64,
    pub feed: String,
    pub install: String,
    pub generation: i64,
    pub install_epoch: i64,
    pub owner_epoch: i64,
    pub groups: Vec<BurstGroup>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Release {
    pub episode_id: String,
    pub event_id: String,
    pub presentation_key: String,
    pub first_observed_at: i64,
    pub eligible_at: i64,
    pub expires_at: i64,
    pub reason: String,
    pub fingerprint: Option<String>,
    pub published_at: Option<i64>,
    pub metadata: Value,
    pub state: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    RepairFeed {
        feed: String,
    },
    RepairBursts {
        feed: String,
        now: i64,
    },
    ReadFeedRepair {
        feed: String,
    },
    ReadFeedBursts {
        feed: String,
    },
    ReadEventProgress {
        source: String,
        event: String,
    },
    ReadBurstProgress {
        presentation: String,
    },
    ReadDeliveryProgress {
        delivery: String,
    },
    ReadDrainProgress {
        observation: String,
    },
    ReadOutboxProgress {
        event: String,
    },
    ReadCircuitProgress {},
    ReadInstallProgress {
        install: String,
    },
    ReadDeviceProgress {
        install: String,
        token_hash: String,
    },

    ClaimEvent {
        source: String,
        event: String,
        lease: String,
        now: i64,
    },
    ReadClaimedEvent {
        source: String,
        event: String,
        lease: String,
    },
    ReadEpisodeRecipients {
        feed: String,
        occurred_at: i64,
        cursor: String,
        reason: Option<String>,
        generation: Option<i64>,
        eligible_at: i64,
        published_at: Option<i64>,
    },
    ReadJobRecipients {
        interest: String,
        cursor: String,
        run: Option<String>,
        generation: Option<i64>,
    },
    ReadRelease {
        event: String,
    },
    ReadUnreadyBurst {
        presentation: String,
    },
    EnsureBurst {
        presentation: String,
        feed: String,
        epoch: i64,
    },
    ClaimBurst {
        presentation: String,
        lease: String,
        now: i64,
    },
    ReadClaimedBurst {
        presentation: String,
        lease: String,
    },
    ReadBurstRecipient {
        feed: String,
        cursor: String,
    },
    ReadBurstMembers {
        presentation: String,
        cursor: String,
        activated_at: i64,
        absence_generation: Option<i64>,
        absence_at: Option<i64>,
        install: String,
        now: i64,
    },
    FailBurst {
        presentation: String,
        lease: String,
        now: i64,
    },
    ReadClaimedDelivery {
        delivery: String,
        lease: String,
    },
    ReadEndpoint {
        install: String,
        epoch: i64,
    },
    ReadSendAuthority {
        delivery: String,
        generation: i64,
        source: String,
        now: i64,
        lease: String,
        control: String,
    },
    InvalidateEndpoint {
        install: String,
        token_hash: String,
        token_generation: Option<i64>,
        invalidated_at: i64,
        now: i64,
        registration_revision: i64,
    },
    MarkStaleToken {
        delivery: String,
        lease: String,
        token_generation: Option<i64>,
    },
    ThrottleInstall {
        install: String,
        until: i64,
    },
    PauseCircuit {
        reason: String,
        now: i64,
    },
    ReadDiagnosticAuthority {
        install: String,
        token_hash: String,
    },
    InvalidateDiagnosticEndpoint {
        install: String,
        token_hash: String,
        token_generation: i64,
        invalidated_at: i64,
        now: i64,
        registration_revision: i64,
    },
    ReadDrain {
        feed: String,
    },
    ReadMatureReleases {
        feed: String,
        now: i64,
    },
    ExpireRelease {
        event: String,
        epoch: i64,
    },
    ReadDueOutbox {
        feed: String,
        now: i64,
    },
    ExpireOutbox {
        event: String,
    },
    RetryOutbox {
        event: String,
        next: i64,
    },
    AcceptOutbox {
        event: String,
        receipt: String,
    },
    ConflictOutbox {
        event: String,
    },
    Fanout {
        page: FanoutPage,
    },
    CompleteBurst {
        presentation: String,
        lease: String,
        events_now: i64,
        burst_now: i64,
    },
    GroupBurst {
        page: BurstPage,
    },
    ClaimDelivery {
        delivery: String,
        generation: i64,
        source: String,
        now: i64,
        lease: String,
        control: String,
    },
    FinishDelivery {
        delivery: String,
        lease: String,
        state: String,
        reason: String,
        next: i64,
        terminal_at: Option<i64>,
    },
    Drain {
        feed: String,
        observation: String,
        generation: i64,
        epoch: i64,
        cursor: i64,
        next: i64,
        records: Vec<Release>,
    },
    OutboxRelease {
        event: String,
        epoch: i64,
        observation: String,
        digest: String,
        occurred_at: i64,
        expires_at: i64,
        now: i64,
        payload: Value,
    },
}
impl Operation {
    pub fn is_read(&self) -> bool {
        matches!(
            self,
            Self::ReadFeedRepair { .. }
                | Self::ReadFeedBursts { .. }
                | Self::ReadEventProgress { .. }
                | Self::ReadBurstProgress { .. }
                | Self::ReadDeliveryProgress { .. }
                | Self::ReadDrainProgress { .. }
                | Self::ReadOutboxProgress { .. }
                | Self::ReadCircuitProgress { .. }
                | Self::ReadInstallProgress { .. }
                | Self::ReadDeviceProgress { .. }
                | Self::ReadClaimedEvent { .. }
                | Self::ReadEpisodeRecipients { .. }
                | Self::ReadJobRecipients { .. }
                | Self::ReadRelease { .. }
                | Self::ReadUnreadyBurst { .. }
                | Self::ReadClaimedBurst { .. }
                | Self::ReadBurstRecipient { .. }
                | Self::ReadBurstMembers { .. }
                | Self::ReadClaimedDelivery { .. }
                | Self::ReadEndpoint { .. }
                | Self::ReadSendAuthority { .. }
                | Self::ReadDiagnosticAuthority { .. }
                | Self::ReadDrain { .. }
                | Self::ReadMatureReleases { .. }
                | Self::ReadDueOutbox { .. }
        )
    }
    pub fn id(&self) -> &'static str {
        match self {
            Self::RepairFeed { .. } => "repair_feed",
            Self::RepairBursts { .. } => "repair_bursts",
            Self::ReadFeedRepair { .. } => "read_feed_repair",
            Self::ReadFeedBursts { .. } => "read_feed_bursts",
            Self::ReadEventProgress { .. } => "d_read_event_progress",
            Self::ReadBurstProgress { .. } => "d_read_burst_progress",
            Self::ReadDeliveryProgress { .. } => "d_read_delivery_progress",
            Self::ReadDrainProgress { .. } => "d_read_drain_progress",
            Self::ReadOutboxProgress { .. } => "d_read_outbox_progress",
            Self::ReadCircuitProgress { .. } => "d_read_circuit_progress",
            Self::ReadInstallProgress { .. } => "d_read_install_progress",
            Self::ReadDeviceProgress { .. } => "d_read_device_progress",
            Self::ClaimEvent { .. } => "d_claim_event",
            Self::ReadClaimedEvent { .. } => "d_read_claimed_event",
            Self::ReadEpisodeRecipients { .. } => "d_read_episode_recipients",
            Self::ReadJobRecipients { .. } => "d_read_job_recipients",
            Self::ReadRelease { .. } => "d_read_release",
            Self::ReadUnreadyBurst { .. } => "d_read_unready_burst",
            Self::EnsureBurst { .. } => "d_ensure_burst",
            Self::ClaimBurst { .. } => "d_claim_burst",
            Self::ReadClaimedBurst { .. } => "d_read_claimed_burst",
            Self::ReadBurstRecipient { .. } => "d_read_burst_recipient",
            Self::ReadBurstMembers { .. } => "d_read_burst_members",
            Self::FailBurst { .. } => "d_fail_burst",
            Self::ReadClaimedDelivery { .. } => "d_read_claimed_delivery",
            Self::ReadEndpoint { .. } => "d_read_endpoint",
            Self::ReadSendAuthority { .. } => "d_read_send_authority",
            Self::InvalidateEndpoint { .. } => "d_invalidate_endpoint",
            Self::MarkStaleToken { .. } => "d_mark_stale_token",
            Self::ThrottleInstall { .. } => "d_throttle_install",
            Self::PauseCircuit { .. } => "d_pause_circuit",
            Self::ReadDiagnosticAuthority { .. } => "d_read_diagnostic_authority",
            Self::InvalidateDiagnosticEndpoint { .. } => "d_invalidate_diagnostic_endpoint",
            Self::ReadDrain { .. } => "d_read_drain",
            Self::ReadMatureReleases { .. } => "d_read_mature_releases",
            Self::ExpireRelease { .. } => "d_expire_release",
            Self::ReadDueOutbox { .. } => "d_read_due_outbox",
            Self::ExpireOutbox { .. } => "d_expire_outbox",
            Self::RetryOutbox { .. } => "d_retry_outbox",
            Self::AcceptOutbox { .. } => "d_accept_outbox",
            Self::ConflictOutbox { .. } => "d_conflict_outbox",
            Self::Fanout { .. } => "B02",
            Self::CompleteBurst { .. } => "B03",
            Self::GroupBurst { .. } => "B04",
            Self::ClaimDelivery { .. } => "B07",
            Self::FinishDelivery { .. } => "B08",
            Self::Drain { .. } => "B09",
            Self::OutboxRelease { .. } => "B10",
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
                let readbacks = operation.readback();
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
                #[cfg(feature = "storage-fixture")]
                worker::console_error!(
                    "storage_fixture_{}_{:?}_{:?}",
                    operation.id(),
                    failure.kind,
                    failure.outcome
                );
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
    super::postgres::slice_d::execute(env, operation, cancel, deadline).await
}

// Full source projections: reject a missing, extra, null or mistyped field.
pub(super) fn validate_rows(operation: &Operation, replies: &[Reply]) -> Result<()> {
    let fields: &[(&str, bool, bool)] = match operation {
        Operation::ReadFeedRepair { .. } => &[
            ("feed_id", true, false),
            ("handling_failures", false, false),
            ("retry_at", false, false),
            ("last_poll_error", true, true),
        ],
        Operation::ReadEventProgress { .. } => &[
            ("source", true, false),
            ("event_id", true, false),
            ("schema_version", false, false),
            ("kind", true, false),
            ("payload_digest", true, false),
            ("occurred_at", false, false),
            ("eligible_at", false, false),
            ("expires_at", false, false),
            ("receipt_id", true, false),
            ("envelope_json", true, false),
            ("fanout_cursor", true, true),
            ("fanout_complete", false, false),
            ("disposition", true, false),
            ("next_attempt_at", false, false),
            ("failures", false, false),
            ("lease_id", true, true),
            ("lease_until", false, true),
            ("terminal_at", false, true),
            ("feed_id", true, true),
            ("interest_id", true, true),
            ("owner_epoch", false, true),
        ],
        Operation::ReadBurstProgress { .. } | Operation::ReadFeedBursts { .. } => &[
            ("presentation_key", true, false),
            ("feed_id", true, false),
            ("owner_epoch", false, false),
            ("cursor", true, false),
            ("lease_id", true, true),
            ("lease_until", false, true),
            ("complete", false, false),
            ("failures", false, false),
            ("next_attempt_at", false, false),
        ],
        Operation::ReadDeliveryProgress { .. } => &[
            ("delivery_id", true, false),
            ("presentation_id", true, false),
            ("install_id", true, false),
            ("install_epoch", false, false),
            ("interest_key", true, false),
            ("interest_generation", false, false),
            ("state", true, false),
            ("expires_at", false, false),
            ("next_attempt_at", false, false),
            ("lease_id", true, true),
            ("lease_until", false, true),
            ("attempt_token_generation", false, true),
            ("attempt_started_at", false, true),
            ("apns_id", true, false),
            ("collapse_id", true, false),
            ("source", true, false),
            ("event_id", true, false),
            ("attempt", false, false),
            ("stale_410_generation", false, true),
            ("failures", false, false),
            ("terminal_at", false, true),
            ("last_reason", true, true),
            ("owner_epoch", false, true),
            ("member_count", false, false),
        ],
        Operation::ReadDrainProgress { .. } => &[
            ("observation_id", true, false),
            ("feed_id", true, false),
            ("generation", false, false),
            ("owner_epoch", false, false),
            ("lease_id", true, false),
            ("expected_generation", false, false),
            ("snapshot_key", true, false),
            ("scan_started_at", false, false),
            ("completed_at", false, true),
            ("candidate_count", false, false),
            ("staged_count", false, false),
            ("valid_eof", false, false),
            ("candidate_storage", true, false),
            ("spooled_count", false, false),
            ("candidate_cursor", false, false),
            ("reason_counts_json", true, false),
            ("state", true, false),
            ("eligibility_generation", false, false),
            ("etag", true, true),
            ("last_modified", true, true),
            ("metadata_json", true, false),
            ("drain_complete", false, false),
            ("recovery_evidence", false, false),
            ("preparation_key", true, true),
            ("processing_token", true, true),
            ("processing_until", false, true),
            ("processing_failures", false, false),
            ("processing_next_at", false, false),
        ],
        Operation::ReadOutboxProgress { .. } => &[
            ("source", true, false),
            ("event_id", true, false),
            ("observation_id", true, true),
            ("payload_digest", true, false),
            ("occurred_at", false, false),
            ("expires_at", false, false),
            ("next_attempt_at", false, false),
            ("state", true, false),
            ("receipt_id", true, true),
            ("payload_json", true, false),
        ],
        Operation::ReadCircuitProgress { .. } => &[
            ("lane", true, false),
            ("paused", false, false),
            ("reason", true, true),
            ("updated_at", false, false),
        ],
        Operation::ReadInstallProgress { .. } => &[
            ("install_id", true, false),
            ("epoch", false, false),
            ("deleted_at", false, true),
            ("token_generation", false, false),
            ("token_hash", true, true),
            ("enabled", false, false),
            ("job_capable", false, false),
            ("registered_at", false, false),
            ("next_send_at", false, false),
            ("registration_revision", false, false),
        ],
        Operation::ReadDeviceProgress { .. } => &[
            ("install_id", true, false),
            ("device_token", true, false),
            ("device_token_hash", true, false),
            ("apns_environment", true, false),
            ("bundle_id", true, false),
            ("notifications_enabled", false, false),
            ("last_seen_at", false, false),
        ],

        Operation::ReadClaimedEvent { .. } => &[
            ("source", true, false),
            ("event_id", true, false),
            ("schema_version", false, false),
            ("kind", true, false),
            ("payload_digest", true, false),
            ("occurred_at", false, false),
            ("eligible_at", false, false),
            ("expires_at", false, false),
            ("receipt_id", true, false),
            ("envelope_json", true, false),
            ("fanout_cursor", true, true),
            ("fanout_complete", false, false),
            ("disposition", true, false),
            ("next_attempt_at", false, false),
            ("failures", false, false),
            ("lease_id", true, true),
            ("lease_until", false, true),
            ("terminal_at", false, true),
            ("feed_id", true, true),
            ("interest_id", true, true),
            ("owner_epoch", false, true),
        ],
        Operation::ReadEpisodeRecipients { .. } => &[
            ("install_id", true, false),
            ("generation", false, false),
            ("epoch", false, false),
        ],
        Operation::ReadJobRecipients { .. } => &[
            ("install_id", true, false),
            ("generation", false, false),
            ("epoch", false, false),
        ],
        Operation::ReadRelease { .. } => &[
            ("feed_id", true, false),
            ("episode_id", true, false),
            ("observation_id", true, false),
            ("generation", false, false),
            ("owner_epoch", false, false),
            ("event_id", true, false),
            ("presentation_key", true, false),
            ("first_observed_at", false, false),
            ("eligible_at", false, false),
            ("expires_at", false, false),
            ("reason", true, false),
            ("fingerprint", true, true),
            ("published_at", false, true),
            ("metadata_json", true, false),
            ("state", true, false),
            ("disposition", true, true),
        ],
        Operation::ReadUnreadyBurst { .. } => &[("1", false, false)],
        Operation::ReadClaimedBurst { .. } => &[
            ("presentation_key", true, false),
            ("feed_id", true, false),
            ("owner_epoch", false, false),
            ("cursor", true, false),
            ("lease_id", true, true),
            ("lease_until", false, true),
            ("complete", false, false),
            ("failures", false, false),
            ("next_attempt_at", false, false),
        ],
        Operation::ReadBurstRecipient { .. } => &[
            ("install_id", true, false),
            ("feed_id", true, false),
            ("generation", false, false),
            ("activated_at", false, false),
            ("absence_generation", false, true),
            ("absence_at", false, true),
            ("enabled", false, false),
            ("changed_at", false, false),
            ("epoch", false, false),
        ],
        Operation::ReadBurstMembers { .. } => &[
            ("event_id", true, false),
            ("eligible_at", false, false),
            ("episode_id", true, false),
            ("expires_at", false, false),
        ],
        Operation::ReadClaimedDelivery { .. } => &[
            ("delivery_id", true, false),
            ("presentation_id", true, false),
            ("install_id", true, false),
            ("install_epoch", false, false),
            ("interest_key", true, false),
            ("interest_generation", false, false),
            ("state", true, false),
            ("expires_at", false, false),
            ("next_attempt_at", false, false),
            ("lease_id", true, true),
            ("lease_until", false, true),
            ("attempt_token_generation", false, true),
            ("attempt_started_at", false, true),
            ("apns_id", true, false),
            ("collapse_id", true, false),
            ("source", true, false),
            ("event_id", true, false),
            ("attempt", false, false),
            ("stale_410_generation", false, true),
            ("failures", false, false),
            ("terminal_at", false, true),
            ("last_reason", true, true),
            ("owner_epoch", false, true),
            ("member_count", false, false),
            ("envelope_json", true, false),
        ],
        Operation::ReadEndpoint { .. } => &[
            ("device_token", true, false),
            ("device_token_hash", true, false),
            ("apns_environment", true, false),
            ("bundle_id", true, false),
            ("token_generation", false, false),
            ("registered_at", false, false),
            ("registration_revision", false, false),
        ],
        Operation::ReadSendAuthority { .. } => &[("1", false, false)],
        Operation::ReadDiagnosticAuthority { .. } => &[
            ("token_generation", false, false),
            ("registration_revision", false, false),
        ],
        Operation::ReadDrain { .. } => &[
            ("observation_id", true, false),
            ("feed_id", true, false),
            ("generation", false, false),
            ("owner_epoch", false, false),
            ("lease_id", true, false),
            ("expected_generation", false, false),
            ("snapshot_key", true, false),
            ("scan_started_at", false, false),
            ("completed_at", false, true),
            ("candidate_count", false, false),
            ("staged_count", false, false),
            ("valid_eof", false, false),
            ("candidate_storage", true, false),
            ("spooled_count", false, false),
            ("candidate_cursor", false, false),
            ("reason_counts_json", true, false),
            ("state", true, false),
            ("eligibility_generation", false, false),
            ("etag", true, true),
            ("last_modified", true, true),
            ("metadata_json", true, false),
            ("drain_complete", false, false),
            ("recovery_evidence", false, false),
            ("preparation_key", true, true),
            ("processing_token", true, true),
            ("processing_until", false, true),
            ("processing_failures", false, false),
            ("processing_next_at", false, false),
            ("sha256", true, false),
            ("bytes", false, false),
        ],
        Operation::ReadMatureReleases { .. } => &[
            ("feed_id", true, false),
            ("episode_id", true, false),
            ("observation_id", true, false),
            ("generation", false, false),
            ("owner_epoch", false, false),
            ("event_id", true, false),
            ("presentation_key", true, false),
            ("first_observed_at", false, false),
            ("eligible_at", false, false),
            ("expires_at", false, false),
            ("reason", true, false),
            ("fingerprint", true, true),
            ("published_at", false, true),
            ("metadata_json", true, false),
            ("state", true, false),
            ("disposition", true, true),
        ],
        Operation::ReadDueOutbox { .. } => &[
            ("source", true, false),
            ("event_id", true, false),
            ("observation_id", true, true),
            ("payload_digest", true, false),
            ("occurred_at", false, false),
            ("expires_at", false, false),
            ("next_attempt_at", false, false),
            ("state", true, false),
            ("receipt_id", true, true),
            ("payload_json", true, false),
        ],
        _ => &[],
    };
    for reply in replies {
        for row in &reply.rows {
            let object = row
                .as_object()
                .ok_or_else(|| decode_failure(operation.is_read()))?;
            if object.len() != fields.len() || fields.is_empty() {
                return Err(decode_failure(operation.is_read()));
            }
            for (name, text, nullable) in fields {
                let value = object
                    .get(*name)
                    .ok_or_else(|| decode_failure(operation.is_read()))?;
                if !((value.is_null() && *nullable)
                    || if *text {
                        value.is_string()
                    } else {
                        value
                            .as_i64()
                            .is_some_and(|n| Parameter::Integer(Some(n)).validate().is_ok())
                    })
                {
                    return Err(decode_failure(operation.is_read()));
                }
            }
        }
    }
    Ok(())
}

impl Operation {
    /// Durable witnesses for an Unknown acknowledgement. The caller compares the
    /// lease/cursor/token/state with this request before scheduling any new work.
    pub fn readback(&self) -> Vec<Self> {
        use Operation::*;
        match self {
            RepairFeed { feed } => vec![ReadFeedRepair { feed: feed.clone() }],
            RepairBursts { feed, .. } => vec![ReadFeedBursts { feed: feed.clone() }],
            ClaimEvent { source, event, .. } => vec![ReadEventProgress {
                source: source.clone(),
                event: event.clone(),
            }],
            Fanout { page } => vec![ReadEventProgress {
                source: page.source.clone(),
                event: page.event.clone(),
            }],
            EnsureBurst { presentation, .. }
            | ClaimBurst { presentation, .. }
            | CompleteBurst { presentation, .. }
            | FailBurst { presentation, .. } => vec![ReadBurstProgress {
                presentation: presentation.clone(),
            }],
            GroupBurst { page } => vec![ReadBurstProgress {
                presentation: page.presentation.clone(),
            }],
            ClaimDelivery { delivery, .. }
            | MarkStaleToken { delivery, .. }
            | FinishDelivery { delivery, .. } => vec![ReadDeliveryProgress {
                delivery: delivery.clone(),
            }],
            InvalidateEndpoint {
                install,
                token_hash,
                ..
            }
            | InvalidateDiagnosticEndpoint {
                install,
                token_hash,
                ..
            } => {
                vec![
                    ReadDeviceProgress {
                        install: install.clone(),
                        token_hash: token_hash.clone(),
                    },
                    ReadInstallProgress {
                        install: install.clone(),
                    },
                ]
            }
            ThrottleInstall { install, .. } => vec![ReadInstallProgress {
                install: install.clone(),
            }],
            PauseCircuit { .. } => vec![ReadCircuitProgress {}],
            Drain { observation, .. } => vec![ReadDrainProgress {
                observation: observation.clone(),
            }],
            ExpireRelease { event, .. } => vec![ReadRelease {
                event: event.clone(),
            }],
            OutboxRelease { event, .. } => vec![
                ReadRelease {
                    event: event.clone(),
                },
                ReadOutboxProgress {
                    event: event.clone(),
                },
            ],
            ExpireOutbox { event }
            | RetryOutbox { event, .. }
            | AcceptOutbox { event, .. }
            | ConflictOutbox { event } => vec![ReadOutboxProgress {
                event: event.clone(),
            }],
            _ => vec![],
        }
    }
}

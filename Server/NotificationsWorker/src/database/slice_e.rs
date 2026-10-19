//! Closed recovery and retention operations. External deletion remains outside storage segments.
use super::{decode_failure, Failure, Kind, Outcome, Parameter, Phase, Reply, Response, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    ClaimCleanup {
        lease: String,
        now: i64,
        generation: i64,
    },
    PrunePollStats {
        before: i64,
    },
    ReleaseCleanup {
        lease: String,
        advance: bool,
        generation: i64,
    },
    /// Read durable state after Unknown; this does not authorize external effects.
    Readback {
        after: Box<Operation>,
    },
    FailedEvent {
        source: String,
        event: String,
        now: i64,
        lease: String,
    },
    FailedDelivery {
        delivery: String,
        now: i64,
        lease: String,
    },
    RecoverLeases {
        now: i64,
    },
    ExpireDeliveries {
        now: i64,
    },
    ExpireEvents {
        now: i64,
    },
    ReadDueEvents {
        now: i64,
    },
    ReadDueDeliveries {
        now: i64,
        episode: bool,
    },
    TerminalizeEvents {
        now: i64,
    },
    ExpireDeletedInstalls {
        now: i64,
    },
    ReadTerminalEvents {
        before: i64,
    },
    RetireEvent {
        source: String,
        event: String,
    },
    ExpireLegacyBridges {
        now: i64,
    },
    ExpireTickets {
        now: i64,
    },
    RetireJobInterests {
        before: i64,
    },
    PruneFeeds {
        before: i64,
    },
    ReadDeliverySummary,
    ReadEventSummary,
    ReadCircuit,
    ReadFeedDeliveries {
        feed: String,
        now: i64,
    },
    ExpireFeedHistory {
        now: i64,
    },
    ExpireOutbox {
        now: i64,
    },
    ScrubOutbox {
        now: i64,
    },
    RetireOutbox {
        now: i64,
    },
    RetireReleases {
        now: i64,
    },
    RetireBursts,
    ReadGcCandidates {
        now: i64,
        limit: usize,
    },
    ClaimGc {
        now: i64,
        key: String,
    },
    ReadGcClaim {
        now: i64,
        key: String,
    },
    MarkDeleted {
        key: String,
    },
    RetireObservations {
        now: i64,
    },
    RetireSnapshotRefs,
    RetireSnapshots,
    AbandonPoisoned {
        feed: String,
        now: i64,
    },
}
impl Operation {
    pub fn is_read(&self) -> bool {
        matches!(
            self,
            Self::Readback { .. }
                | Self::ReadDueEvents { .. }
                | Self::ReadDueDeliveries { .. }
                | Self::ReadTerminalEvents { .. }
                | Self::ReadDeliverySummary
                | Self::ReadEventSummary
                | Self::ReadCircuit
                | Self::ReadFeedDeliveries { .. }
                | Self::ReadGcCandidates { .. }
                | Self::ReadGcClaim { .. }
        )
    }
    pub fn id(&self) -> &'static str {
        match self {
            Self::ClaimCleanup { .. } => "claim_cleanup",
            Self::PrunePollStats { .. } => "prune_poll_stats",
            Self::ReleaseCleanup { .. } => "release_cleanup",
            Self::Readback { .. } => "e_readback",
            Self::FailedEvent { .. } => "e_failed_event",
            Self::FailedDelivery { .. } => "e_failed_delivery",
            Self::RecoverLeases { .. } => "e_recover_leases",
            Self::ExpireDeliveries { .. } => "e_expire_deliveries",
            Self::ExpireEvents { .. } => "e_expire_events",
            Self::ReadDueEvents { .. } => "e_read_due_events",
            Self::ReadDueDeliveries { .. } => "e_read_due_deliveries",
            Self::TerminalizeEvents { .. } => "e_terminalize_events",
            Self::ExpireDeletedInstalls { .. } => "e_expire_deleted_installs",
            Self::ReadTerminalEvents { .. } => "e_read_terminal_events",
            Self::RetireEvent { .. } => "B05",
            Self::ExpireLegacyBridges { .. } => "e_expire_legacy_bridges",
            Self::ExpireTickets { .. } => "e_expire_tickets",
            Self::RetireJobInterests { .. } => "e_retire_job_interests",
            Self::PruneFeeds { .. } => "B06",
            Self::ReadDeliverySummary => "e_read_delivery_summary",
            Self::ReadEventSummary => "e_read_event_summary",
            Self::ReadCircuit => "e_read_circuit",
            Self::ReadFeedDeliveries { .. } => "e_read_feed_deliveries",
            Self::ExpireFeedHistory { .. } => "B11",
            Self::ExpireOutbox { .. } => "e_expire_outbox",
            Self::ScrubOutbox { .. } => "e_scrub_outbox",
            Self::RetireOutbox { .. } => "e_retire_outbox",
            Self::RetireReleases { .. } => "e_retire_releases",
            Self::RetireBursts => "e_retire_bursts",
            Self::ReadGcCandidates { .. } => "e_read_gc_candidates",
            Self::ClaimGc { .. } => "e_claim_gc",
            Self::ReadGcClaim { .. } => "e_read_gc_claim",
            Self::MarkDeleted { .. } => "e_mark_deleted",
            Self::RetireObservations { .. } => "e_retire_observations",
            Self::RetireSnapshotRefs => "e_retire_snapshot_refs",
            Self::RetireSnapshots => "e_retire_snapshots",
            Self::AbandonPoisoned { .. } => "B17",
        }
    }
}
pub(super) fn validate(operation: &Operation) -> Result<()> {
    if matches!(operation, Operation::Readback { after } if after.is_read()) {
        return Err(decode_failure(true));
    }
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
    if matches!(operation, Operation::Readback { .. }) {
        return Ok(());
    }
    let (text, integer, nullable): (&[&str], &[&str], &[&str]) = match operation {
        Operation::ReadDueEvents { .. } => (&["source", "event_id"], &[], &[]),
        Operation::ReadDueDeliveries { .. } => {
            (&["delivery_id", "source"], &["interest_generation"], &[])
        }
        Operation::ReadTerminalEvents { .. } => (&["source", "event_id"], &[], &[]),
        Operation::ReadDeliverySummary => (&["state"], &["count", "oldest_due"], &["oldest_due"]),
        Operation::ReadEventSummary => (
            &[],
            &["count", "oldest_due", "poisoned"],
            &["oldest_due", "poisoned"],
        ),
        Operation::ReadCircuit => (&["reason"], &["paused", "updated_at"], &["reason"]),
        Operation::ReadFeedDeliveries { .. } => {
            (&["delivery_id", "source"], &["interest_generation"], &[])
        }
        Operation::ReadGcCandidates { .. } => (&["object_key"], &[], &[]),
        Operation::ReadGcClaim { .. } => (&["object_key"], &[], &[]),
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
            if result
                .as_ref()
                .is_err_and(|failure| failure.outcome == Outcome::Unknown)
            {
                // Observe closed witnesses under the same cancellation and cap.
                // Even a matching later row cannot reconstruct affected counts
                // or exclude superseding work. Keep Unknown; never replay or
                // authorize a send/object deletion from a lost acknowledgement.
                let readbacks = if operation.is_read() {
                    vec![]
                } else {
                    vec![Operation::Readback {
                        after: Box::new(operation.clone()),
                    }]
                };
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
pub(super) async fn execute_postgres(
    env: &worker::Env,
    operation: &Operation,
    cancel: opencast_worker_database_core::database::Cancellation,
    deadline: u64,
) -> Result<Response> {
    super::postgres::slice_e::execute(env, operation, cancel, deadline).await
}

pub(super) mod readback {
    use super::Operation;
    use crate::database::*;

    pub(in crate::database) fn describe(operation: &Operation, postgres: bool) -> Statement {
        use Operation::*;
        let (relations, parameters): (Vec<(&str, &str)>, Vec<Parameter>) = match operation {
        ClaimCleanup { .. } | ReleaseCleanup { .. } => (vec![("n_poll_dispatch", "id=1")], vec![]),
        PrunePollStats { before } => (vec![("n_poll_stat", "bucket<?1")], vec![integer(*before)]),
        FailedEvent { source, event, .. } => (vec![("n_event", "source=?1 AND event_id=?2")], vec![text(source), text(event)]),
        FailedDelivery { delivery, .. } => (vec![("n_delivery", "delivery_id=?1")], vec![text(delivery)]),
        RecoverLeases { now, .. } => (vec![("n_delivery", "(state='leased' AND lease_until<=?1) OR (last_reason='lease_expired' AND next_attempt_at=?1)")], vec![integer(*now)]),
        ExpireDeliveries { now, .. } => (vec![("n_delivery", "expires_at<=?1")], vec![integer(*now)]),
        ExpireEvents { now, .. } => (vec![("n_event", "expires_at<=?1")], vec![integer(*now)]),
        TerminalizeEvents { now, .. } => (vec![("n_event", "fanout_complete=1 AND (terminal_at IS NULL OR terminal_at=?1)")], vec![integer(*now)]),
        ExpireDeletedInstalls { now, .. } => (vec![("n_deleted_install", "expires_at<=?1")], vec![integer(*now)]),
        RetireEvent { source, event, .. } => (vec![("n_delivery_member", "source=?1 AND event_id=?2"), ("n_delivery", "source=?1 AND event_id=?2"), ("n_group_member", "source=?1 AND event_id=?2"), ("n_event", "source=?1 AND event_id=?2")], vec![text(source), text(event)]),
        ExpireLegacyBridges { now, .. } => (vec![("n_legacy_bridge", "expires_at<=?1")], vec![integer(*now)]),
        ExpireTickets { now, .. } => (vec![("n_requester_ticket", "expires_at<=?1")], vec![integer(*now)]),
        RetireJobInterests { before, .. } => (vec![("n_job_interest", "register_before<?1")], vec![integer(*before)]),
        PruneFeeds { .. } => (vec![("n_interest", "1=1"), ("n_legacy_bridge", "1=1"), ("n_feed", "1=1")], vec![]),
        ExpireFeedHistory { now, .. } => (vec![("n_observation", "feed_id IN(SELECT feed_id FROM n_feed WHERE no_interest_since<=?1-2592000)"), ("n_episode_release", "feed_id IN(SELECT feed_id FROM n_feed WHERE no_interest_since<=?1-2592000)"), ("n_feed", "feed_id IN(SELECT feed_id FROM n_feed WHERE no_interest_since<=?1-2592000)")], vec![integer(*now)]),
        ExpireOutbox { now, .. } => (vec![("n_outbox", "source='feed_polling' AND expires_at<=?1")], vec![integer(*now)]),
        ScrubOutbox { now, .. } => (vec![("n_outbox", "source='feed_polling' AND expires_at<=?1")], vec![integer(*now)]),
        RetireOutbox { now, .. } => (vec![("n_outbox", "source='feed_polling' AND expires_at<=?1-604800")], vec![integer(*now)]),
        RetireReleases { now, .. } => (vec![("n_episode_release", "expires_at<=?1-604800")], vec![integer(*now)]),
        RetireBursts => (vec![("n_burst", "1=1")], vec![]),
        ClaimGc { key, .. } => (vec![("n_snapshot", "object_key=?1")], vec![text(key)]),
        MarkDeleted { key, .. } => (vec![("n_snapshot", "object_key=?1")], vec![text(key)]),
        RetireObservations { now, .. } => (vec![("n_observation", "scan_started_at<=?1-604800")], vec![integer(*now)]),
        RetireSnapshotRefs => (vec![("n_snapshot_ref", "1=1")], vec![]),
        RetireSnapshots => (vec![("n_snapshot", "state='deleted'")], vec![]),
        AbandonPoisoned { feed, .. } => (vec![("n_observation", "feed_id=?1"), ("n_feed", "feed_id=?1")], vec![text(feed)]),
        _ => unreachable!("readbacks only follow validated mutations"),
    };
        let sql = relations
            .into_iter()
            .map(|(table, predicate)| {
                let columns = columns(table);
                let members = columns
                    .iter()
                    .map(|(name, _, _)| format!("'{name}',{name}"))
                    .collect::<Vec<_>>()
                    .join(",");
                let value = if postgres {
                    format!("json_build_object({members})::text")
                } else {
                    format!("json_object({members})")
                };
                format!(
                "SELECT '{table}' AS relation,{value} AS row_json FROM {table} WHERE {predicate}"
            )
            })
            .collect::<Vec<_>>()
            .join(" UNION ALL ");
        Statement {
            sql: if postgres { sql.replace('?', "$") } else { sql },
            parameters,
            count: CountRule::Any,
        }
    }
    fn columns(table: &str) -> &'static [(&'static str, bool, bool)] {
        match table {
            "n_poll_dispatch" => &[
                ("id", false, false),
                ("cleanup_lease", true, true),
                ("cleanup_until", false, false),
                ("cleanup_generation", false, false),
            ],
            "n_poll_stat" => &[
                ("bucket", false, false),
                ("publisher_failures", false, false),
                ("handling_failures", false, false),
                ("redeliveries", false, false),
                ("dead_letters", false, false),
                ("stale_commits", false, false),
                ("retry_after_clamps", false, false),
                ("scan_busy", false, false),
                ("permit_reclaims", false, false),
            ],
            "n_burst" => &[
                ("presentation_key", true, true),
                ("feed_id", true, false),
                ("owner_epoch", false, false),
                ("cursor", true, false),
                ("lease_id", true, true),
                ("lease_until", false, true),
                ("complete", false, false),
                ("failures", false, false),
                ("next_attempt_at", false, false),
            ],
            "n_deleted_install" => &[("fence", true, true), ("expires_at", false, false)],
            "n_delivery" => &[
                ("delivery_id", true, true),
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
            "n_delivery_member" => &[
                ("delivery_id", true, false),
                ("source", true, false),
                ("event_id", true, false),
                ("install_id", true, false),
                ("install_epoch", false, false),
                ("interest_generation", false, false),
            ],
            "n_episode_release" => &[
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
            "n_event" => &[
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
            "n_feed" => &[
                ("feed_id", true, true),
                ("canonical_url", true, false),
                ("epoch", false, false),
                ("due_at", false, false),
                ("lease_id", true, true),
                ("lease_until", false, true),
                ("observation_generation", false, false),
                ("eligibility_generation", false, false),
                ("admission_paused", false, false),
                ("publish_token", true, true),
                ("snapshot_key", true, true),
                ("etag", true, true),
                ("last_modified", true, true),
                ("last_success_at", false, true),
                ("no_interest_since", false, true),
                ("schedule_generation", false, false),
                ("retry_at", false, false),
                ("poll_failures", false, false),
                ("origin_key", true, true),
                ("baseline_at", false, true),
                ("credible_release_at", false, true),
                ("credible_cadence", false, true),
                ("send_paused", false, false),
                ("dispatch_until", false, false),
                ("semantic_digest", true, true),
                ("publish_cadence", false, true),
                ("last_poll_at", false, true),
                ("last_poll_outcome", true, true),
                ("last_poll_error", true, true),
                ("handling_failures", false, false),
                ("validator_url", true, true),
                ("validator_at", false, true),
            ],
            "n_group_member" => &[
                ("group_id", true, false),
                ("source", true, false),
                ("event_id", true, false),
                ("ordinal", false, false),
            ],
            "n_interest" => &[
                ("install_id", true, false),
                ("feed_id", true, false),
                ("generation", false, false),
                ("activated_at", false, false),
                ("absence_generation", false, true),
                ("absence_at", false, true),
                ("enabled", false, false),
                ("changed_at", false, false),
            ],
            "n_job_interest" => &[
                ("install_id", true, false),
                ("install_epoch", false, false),
                ("operation_id", true, false),
                ("producer", true, false),
                ("requester_ref", true, false),
                ("generation", false, false),
                ("grant_digest", true, false),
                ("grant_nonce", true, false),
                ("grant_key_version", false, false),
                ("issued_at", false, false),
                ("accept_before", false, false),
                ("register_before", false, false),
                ("accepted_at", false, true),
                ("run_id", true, true),
                ("job_handle", true, true),
                ("state", true, false),
                ("seen_at", false, true),
                ("reason", true, true),
                ("interest_id", true, true),
                ("receipt_id", true, true),
                ("attempt_started_at", false, true),
                ("local_fallback_safe", false, true),
            ],
            "n_legacy_bridge" => &[
                ("install_id", true, false),
                ("feed_id", true, false),
                ("identity_key", true, false),
                ("disposition", true, false),
                ("expires_at", false, false),
            ],
            "n_observation" => &[
                ("observation_id", true, true),
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
            "n_outbox" => &[
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
            "n_requester_ticket" => &[
                ("ticket_digest", true, true),
                ("producer", true, false),
                ("operation_id", true, false),
                ("requester_ref", true, false),
                ("issued_at", false, false),
                ("expires_at", false, false),
                ("environment", true, false),
            ],
            "n_snapshot" => &[
                ("object_key", true, true),
                ("feed_id", true, false),
                ("owner_epoch", false, false),
                ("lease_id", true, false),
                ("sha256", true, false),
                ("bytes", false, false),
                ("state", true, false),
                ("created_at", false, false),
                ("gc_after", false, false),
                ("expected_pages", false, false),
            ],
            "n_snapshot_ref" => &[("manifest_key", true, false), ("page_key", true, false)],
            _ => &[],
        }
    }
    pub(in crate::database) fn normalize(
        operation: &Operation,
        replies: &mut [Reply],
    ) -> Result<()> {
        if !matches!(operation, Operation::Readback { .. }) {
            return Ok(());
        }
        for reply in replies {
            for row in &mut reply.rows {
                let table = row
                    .get("relation")
                    .and_then(Value::as_str)
                    .ok_or_else(|| decode_failure(true))?;
                let expected = columns(table);
                let value: Value = serde_json::from_str(
                    row.get("row_json")
                        .and_then(Value::as_str)
                        .ok_or_else(|| decode_failure(true))?,
                )
                .map_err(|_| decode_failure(true))?;
                let fields = value.as_object().ok_or_else(|| decode_failure(true))?;
                if expected.is_empty() || fields.len() != expected.len() {
                    return Err(decode_failure(true));
                }
                for (name, text, nullable) in expected {
                    let field = fields.get(*name).ok_or_else(|| decode_failure(true))?;
                    let valid = (*nullable && field.is_null())
                        || if *text {
                            field.is_string()
                        } else {
                            field
                                .as_i64()
                                .is_some_and(|v| Parameter::Integer(Some(v)).validate().is_ok())
                        };
                    if !valid {
                        return Err(decode_failure(true));
                    }
                }
                *row = serde_json::json!({"relation":table,"row":value});
            }
            reply.rows.sort_by_key(Value::to_string);
        }
        Ok(())
    }
}

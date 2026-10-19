//! Expected semantic row shapes. Missing fields never become null/zero success.
use super::*;

enum Cell {
    Integer,
    OptionalInteger,
    Text,
    OptionalText,
}
use Cell::*;
type Field = (&'static str, Cell);
const CLAIM: &[Field] = &[
    ("origin_key", OptionalText),
    ("due_at", Integer),
    ("retry_at", Integer),
    ("baseline_at", OptionalInteger),
    ("credible_release_at", OptionalInteger),
    ("credible_cadence", OptionalInteger),
    ("publish_cadence", OptionalInteger),
    ("lease_until", OptionalInteger),
    ("preparing", Integer),
    ("draining", Integer),
    ("outboxing", Integer),
    ("five_minute", Integer),
];
const ROLLUP: &[Field] = &[
    ("overdue", Integer),
    ("healthy_overdue", Integer),
    ("oldest_due_seconds", Integer),
    ("late_600", Integer),
    ("late_baselines", Integer),
    ("in_flight", Integer),
    ("admission_deferred", Integer),
    ("unchanged_last_minute", Integer),
    ("published_last_minute", Integer),
    ("failed_last_minute", Integer),
    ("completed_last_5min", Integer),
];
const STATS: &[Field] = &[
    ("overdue", Integer),
    ("healthy_overdue", Integer),
    ("oldest_due_seconds", Integer),
    ("late_600", Integer),
    ("late_baselines", Integer),
    ("oldest_unhealthy_due_seconds", Integer),
    ("publisher_backoff", Integer),
    ("dead_lettered", Integer),
    ("in_flight", Integer),
    ("reservation_expired", Integer),
    ("queue_age_seconds", Integer),
    ("origin_cooldowns", Integer),
    ("preparation_abandoned", Integer),
    ("eligibility_abandoned", Integer),
    ("burst_poisoned", Integer),
    ("source_pending", Integer),
    ("snapshot_orphan_total", Integer),
    ("publisher_failure_total", Integer),
    ("handling_failure_total", Integer),
    ("redelivery_total", Integer),
    ("dead_letter_total", Integer),
    ("stale_commit_total", Integer),
    ("retry_after_clamped_total", Integer),
    ("scan_busy_total", Integer),
    ("permit_reclaim_total", Integer),
];

pub(super) fn validate(operation: &Operation, replies: &[Reply]) -> Result<()> {
    use Operation::*;
    let fields: &[Field] = match operation {
        ReadControl { .. } => &[("enabled", Integer)],
        ReadCandidates { .. } => &[("feed_id", Text), ("canonical_url", Text)],
        ReserveDispatch { .. } => &[
            ("feed_id", Text),
            ("epoch", Integer),
            ("schedule_generation", Integer),
            ("due_at", Integer),
        ],
        ReadClaim { .. } => CLAIM,
        ReadValidators { .. } => &[
            ("canonical_url", Text),
            ("etag", OptionalText),
            ("last_modified", OptionalText),
            ("validator_url", OptionalText),
            ("validator_at", OptionalInteger),
        ],
        ReadFeedSource { .. } => &[
            ("feed_url", Text),
            ("source_url", Text),
            ("etag", OptionalText),
            ("last_modified", OptionalText),
            ("validator_url", OptionalText),
            ("validator_at", OptionalInteger),
        ],
        ReadScanCheckpoint { .. } => &[
            ("epoch", Integer),
            ("eligibility_generation", Integer),
            ("snapshot_key", OptionalText),
            ("semantic_digest", OptionalText),
            ("publish_token", OptionalText),
            ("generation", Integer),
        ],
        ReadOrigin { .. } => &[("cooldown_until", Integer), ("failures", Integer)],
        ReadUnchangedFence { .. } => &[("1", Integer)],
        ReadRollup { .. } => ROLLUP,
        ReadStats { .. } => STATS,
        ReadWatchdog { .. } => &[("late_900", Integer), ("stall_state", OptionalText)],
        ReadDispatchState { full: true } => &[
            ("stall_state", Text),
            ("stall_since", Integer),
            ("stall_alerted_at", Integer),
            ("alert_armed_at", Integer),
        ],
        ReadDispatchState { full: false } => &[("stall_state", Text), ("stall_since", Integer)],
        _ => &[],
    };
    for reply in replies {
        for row in &reply.rows {
            let object = row
                .as_object()
                .ok_or_else(|| decode_failure(operation.is_read()))?;
            if fields.is_empty() || object.len() != fields.len() {
                return Err(decode_failure(operation.is_read()));
            }
            for (name, kind) in fields {
                let value = object
                    .get(*name)
                    .ok_or_else(|| decode_failure(operation.is_read()))?;
                let valid = match kind {
                    Integer | OptionalInteger if !value.is_null() => value
                        .as_i64()
                        .is_some_and(|n| Parameter::Integer(Some(n)).validate().is_ok()),
                    Text | OptionalText if !value.is_null() => value.is_string(),
                    OptionalInteger | OptionalText => true,
                    _ => false,
                };
                if !valid {
                    return Err(decode_failure(operation.is_read()));
                }
            }
        }
    }
    Ok(())
}

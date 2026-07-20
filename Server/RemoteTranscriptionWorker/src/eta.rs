//! Read-only ETA projection from durable job state. The constants are the
//! July 2026 bakeoff calibration; changing the model or chunk latency means
//! recalibrating this module and the Worker README together.

use crate::job::{self, JobRecord};
use crate::types::EstimateStatus;

pub const DELAYED_AFTER_SECONDS: i64 = 30;
pub const PROBE_AND_RESERVATION_SECONDS: f64 = 4.0;
pub const AI_WAVE_SECONDS: f64 = 13.0;
pub const AI_SCHEDULING_SECONDS: f64 = 2.0;
pub const CHUNK_PREPARATION_SECONDS_PER_MB: f64 = 0.5;
pub const FINALIZATION_BASE_SECONDS: f64 = 2.0;
pub const FINALIZATION_SECONDS_PER_CHUNK: f64 = 0.5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EtaProjection {
    pub remaining_seconds: Option<u32>,
    pub status: EstimateStatus,
}

pub fn expected_chunk_count(duration_seconds: f64) -> Option<u32> {
    if !duration_seconds.is_finite() || duration_seconds <= 0.0 {
        return None;
    }
    Some(((duration_seconds / job::STEP_SECONDS).ceil() as u32).max(1))
}

pub fn chunk_progress(record: &JobRecord) -> Option<(u32, u32)> {
    let total = if !record.chunks.is_empty() {
        record.chunks.len() as u32
    } else if !record.chunk_work.is_empty() {
        record.chunk_work.len() as u32
    } else {
        return None;
    };
    let completed = if record.chunk_work.is_empty() {
        record.next_chunk_index
    } else {
        record
            .chunk_work
            .iter()
            .filter(|work| work.completed)
            .count() as u32
    };
    Some((completed.min(total), total))
}

pub fn self_remaining_seconds(record: &JobRecord, chunk_concurrency: u32, now: i64) -> Option<u32> {
    let duration = record.canonical_duration_seconds?;
    let expected_total = expected_chunk_count(duration)?;
    let (completed, total) = chunk_progress(record).unwrap_or((0, expected_total));
    let total = total.max(1);
    let remaining_chunks = total.saturating_sub(completed.min(total));
    let ai_seconds = if remaining_chunks == 0 {
        0.0
    } else {
        let waves = remaining_chunks.div_ceil(chunk_concurrency.max(1));
        AI_SCHEDULING_SECONDS + f64::from(waves) * AI_WAVE_SECONDS
    };
    let source_bytes = record.server_byte_count.or_else(|| {
        record
            .upload_completed
            .then(|| {
                record
                    .device_identity
                    .as_ref()
                    .map(|identity| identity.byte_count)
            })
            .flatten()
    })?;
    let chunk_preparation_seconds =
        source_bytes.max(0) as f64 / 1_000_000.0 * CHUNK_PREPARATION_SECONDS_PER_MB;
    let finalization_seconds =
        FINALIZATION_BASE_SECONDS + f64::from(total) * FINALIZATION_SECONDS_PER_CHUNK;

    let remaining = match record.state.as_str() {
        job::STATE_SOURCE_MATCHED | job::STATE_PROBING => {
            let elapsed = elapsed_since_first(
                record,
                &[job::STATE_SOURCE_MATCHED, job::STATE_PROBING],
                now,
            );
            let probe = (PROBE_AND_RESERVATION_SECONDS - elapsed).max(0.0);
            probe + chunk_preparation_seconds.max(ai_seconds) + finalization_seconds
        }
        job::STATE_RESERVED => chunk_preparation_seconds.max(ai_seconds) + finalization_seconds,
        job::STATE_CHUNKING => {
            let elapsed = elapsed_since_first(record, &[job::STATE_CHUNKING], now);
            let preparation_remaining = (chunk_preparation_seconds - elapsed).max(0.0);
            preparation_remaining.max(ai_seconds) + finalization_seconds
        }
        job::STATE_TRANSCRIBING => ai_seconds + finalization_seconds,
        job::STATE_STITCHING => {
            let elapsed = elapsed_since_first(record, &[job::STATE_STITCHING], now);
            (finalization_seconds - elapsed).max(0.0)
        }
        _ => return None,
    };

    Some(remaining.ceil().clamp(1.0, u32::MAX as f64) as u32)
}

pub fn project(record: &JobRecord, chunk_concurrency: u32, now: i64) -> Option<EtaProjection> {
    let own_remaining = self_remaining_seconds(record, chunk_concurrency, now)?;
    if record.queued_since.is_some() {
        if let Some(queue_wait) = record.queue_wait_seconds {
            return Some(EtaProjection {
                remaining_seconds: Some(own_remaining.saturating_add(queue_wait)),
                status: EstimateStatus::Queued,
            });
        }
    }
    if now.saturating_sub(record.updated_at) >= DELAYED_AFTER_SECONDS {
        return Some(EtaProjection {
            remaining_seconds: None,
            status: EstimateStatus::Delayed,
        });
    }
    Some(EtaProjection {
        remaining_seconds: Some(own_remaining),
        status: EstimateStatus::OnTrack,
    })
}

fn elapsed_since_first(record: &JobRecord, states: &[&str], now: i64) -> f64 {
    let Some(started_at) = states
        .iter()
        .filter_map(|state| record.phase_timestamps.get(*state))
        .min()
    else {
        return 0.0;
    };
    now.saturating_sub(*started_at).max(0) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(duration: f64, byte_count: i64, state: &str, now: i64) -> JobRecord {
        let mut record = JobRecord::created(
            "job-eta".into(),
            "account".into(),
            "episode".into(),
            None,
            Some(duration),
            None,
            None,
            now,
        );
        record.canonical_duration_seconds = Some(duration);
        record.server_byte_count = Some(byte_count);
        record.state = state.into();
        record.phase_timestamps.insert(state.into(), now);
        record
    }

    #[test]
    fn bakeoff_anchors_match_the_calibrated_model() {
        let now = 1_000;
        let anchors = [
            (885.943, 9_825_356, 23),
            (2_916.6, 46_990_136, 52),
            (5_796.8, 93_076_365, 83),
            (6_978.4, 111_797_868, 98),
        ];
        for (duration, bytes, expected) in anchors {
            let record = record(duration, bytes, job::STATE_PROBING, now);
            assert_eq!(self_remaining_seconds(&record, 4, now), Some(expected));
        }
    }

    #[test]
    fn concurrency_and_partial_completion_change_remaining_waves() {
        let now = 1_000;
        let mut record = record(2_916.6, 46_990_136, job::STATE_TRANSCRIBING, now);
        record.chunk_work = job::init_chunk_work(10, 0);
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(48));
        assert_eq!(self_remaining_seconds(&record, 1, now), Some(139));

        for work in record.chunk_work.iter_mut().take(4) {
            work.completed = true;
        }
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(35));
    }

    #[test]
    fn chunk_preparation_overlaps_ai_and_finalization_counts_down() {
        let now = 1_000;
        let mut chunking = record(6_978.4, 111_797_868, job::STATE_CHUNKING, now - 40);
        chunking.updated_at = now;
        chunking.chunk_work = job::init_chunk_work(24, 8);
        assert_eq!(self_remaining_seconds(&chunking, 4, now), Some(68));

        let mut stitching = record(2_916.6, 46_990_136, job::STATE_STITCHING, now - 3);
        stitching.updated_at = now;
        stitching.chunk_work = job::init_chunk_work(10, 10);
        assert_eq!(self_remaining_seconds(&stitching, 4, now), Some(4));
    }

    #[test]
    fn network_variable_and_credit_wait_states_have_no_estimate() {
        let now = 1_000;
        for state in [
            job::STATE_CREATED,
            job::STATE_STAGING_ORIGIN,
            job::STATE_WAITING_FOR_DEVICE_SOURCE,
            job::STATE_EXACT_UPLOAD_REQUIRED,
            job::STATE_EXACT_UPLOADING,
            job::STATE_AWAITING_CREDITS,
            job::STATE_RESULT_READY,
        ] {
            assert_eq!(
                self_remaining_seconds(&record(900.0, 10_000_000, state, now), 4, now),
                None,
                "{state}"
            );
        }
    }

    #[test]
    fn exact_upload_uses_the_authenticated_device_byte_count() {
        let now = 1_000;
        let mut record = record(900.0, 10_000_000, job::STATE_TRANSCRIBING, now);
        record.server_byte_count = None;
        record.upload_completed = true;
        record.device_identity = Some(crate::types::SourceIdentity {
            sha256: "aa".into(),
            byte_count: 10_000_000,
            duration_seconds: Some(900.0),
            entity_tag: None,
            last_modified: None,
            final_url_sha256: None,
        });
        record.chunk_work = job::init_chunk_work(4, 0);
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(19));
    }

    #[test]
    fn delayed_threshold_is_thirty_seconds_and_queued_wins() {
        let now = 1_000;
        let mut record = record(900.0, 10_000_000, job::STATE_TRANSCRIBING, now);
        record.chunk_work = job::init_chunk_work(4, 0);
        record.updated_at = now - 29;
        assert_eq!(
            project(&record, 4, now).unwrap().status,
            EstimateStatus::OnTrack
        );

        record.updated_at = now - DELAYED_AFTER_SECONDS;
        let delayed = project(&record, 4, now).unwrap();
        assert_eq!(delayed.status, EstimateStatus::Delayed);
        assert_eq!(delayed.remaining_seconds, None);

        record.queued_since = Some(now - 40);
        record.queue_wait_seconds = Some(20);
        let queued = project(&record, 4, now).unwrap();
        assert_eq!(queued.status, EstimateStatus::Queued);
        assert_eq!(queued.remaining_seconds, Some(39));
    }
}

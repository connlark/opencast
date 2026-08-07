//! Read-only ETA projection from durable job state. The constants are the
//! 2026-08-05 span-read bakeoff calibration (nine dev-lane runs across wave
//! widths 1/2/4, wave counts 1–13); changing the model or chunk latency means
//! recalibrating this module and the Worker README together.

use crate::job::{self, JobRecord};
use crate::types::EstimateStatus;

pub const DELAYED_AFTER_SECONDS: i64 = 30;
pub const PROBE_AND_RESERVATION_SECONDS: f64 = 4.0;
/// Measured wave wall is width-insensitive across the widths production can
/// serve (two through four lanes measured 26.6 s and 26.7 s mean); a lone
/// call floors near 19 s but width one is unreachable behind
/// `chunk_ai_concurrency`, so a single constant carries the model.
pub const AI_WAVE_SECONDS: f64 = 26.0;
pub const AI_SCHEDULING_SECONDS: f64 = 2.0;
/// Native source-walk rate: streamed R2 read + frame walk + hash measured
/// 4 s + 0.27 s/MB across 9.8–174 MB sources, rounded conservative.
pub const CHUNK_PREPARATION_SECONDS_PER_MB: f64 = 0.3;
pub const NORMALIZED_CHUNK_PREPARATION_SECONDS_PER_MB: f64 = 2.0;
pub const FINALIZATION_BASE_SECONDS: f64 = 2.0;
pub const FINALIZATION_SECONDS_PER_CHUNK: f64 = 0.6;
/// Chained cloud ad detection budget (submit + Gemini + poll), added to
/// finalization only when the job requested the phase.
pub const AD_ANALYSIS_PHASE_SECONDS: f64 = 30.0;

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
    let stream_copy_bytes_per_chunk = source_bytes.max(0) as f64 / duration * job::CHUNK_SECONDS;
    let preparation_seconds_per_mb =
        if stream_copy_bytes_per_chunk > job::MAX_CHUNK_RAW_BYTES as f64 {
            NORMALIZED_CHUNK_PREPARATION_SECONDS_PER_MB
        } else {
            CHUNK_PREPARATION_SECONDS_PER_MB
        };
    // A stored native plan means chunking is metadata-only: the manifest is
    // built from the plan with zero R2 I/O, so there is no preparation phase
    // left to project. Without a plan the bytes-based figure stands in for
    // the native source walk (during PROBING) or the container chunk pass
    // (the sha-less fallback). Nothing overlaps AI any more — the overlap
    // driver is retired — so preparation is sequential with the wave phase.
    let chunk_preparation_seconds = if record.native_plan.is_some() {
        0.0
    } else {
        source_bytes.max(0) as f64 / 1_000_000.0 * preparation_seconds_per_mb
    };
    let ad_phase_seconds = if record.ad_analysis_requested {
        AD_ANALYSIS_PHASE_SECONDS
    } else {
        0.0
    };
    let finalization_seconds = FINALIZATION_BASE_SECONDS
        + f64::from(total) * FINALIZATION_SECONDS_PER_CHUNK
        + ad_phase_seconds;

    let remaining = match record.state.as_str() {
        job::STATE_SOURCE_MATCHED | job::STATE_PROBING => {
            // The native walk runs inside PROBING, so its bytes-based budget
            // counts down together with the probe/reservation floor.
            let elapsed = elapsed_since_first(
                record,
                &[job::STATE_SOURCE_MATCHED, job::STATE_PROBING],
                now,
            );
            let staged =
                (PROBE_AND_RESERVATION_SECONDS + chunk_preparation_seconds - elapsed).max(0.0);
            staged + ai_seconds + finalization_seconds
        }
        job::STATE_RESERVED => chunk_preparation_seconds + ai_seconds + finalization_seconds,
        job::STATE_CHUNKING => {
            let elapsed = elapsed_since_first(record, &[job::STATE_CHUNKING], now);
            let preparation_remaining = (chunk_preparation_seconds - elapsed).max(0.0);
            preparation_remaining + ai_seconds + finalization_seconds
        }
        job::STATE_TRANSCRIBING => ai_seconds + finalization_seconds,
        job::STATE_STITCHING => {
            let elapsed = elapsed_since_first(record, &[job::STATE_STITCHING], now);
            (finalization_seconds - elapsed).max(0.0)
        }
        job::STATE_DETECTING_ADS => {
            let elapsed = elapsed_since_first(record, &[job::STATE_DETECTING_ADS], now);
            (ad_phase_seconds - elapsed).max(0.0)
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

    /// The 2026-08-05 span-read bakeoff fixtures, projected at PROBING entry
    /// with their natural wave width. Measured probing->result_ready walls
    /// were 28, 101, 71, and 430 seconds respectively — the model lands
    /// within a few seconds on the three larger sources and stays
    /// conservative on the smallest (its lone wave of three calls ran cheap).
    #[test]
    fn bakeoff_anchors_match_the_calibrated_model() {
        let now = 1_000;
        let anchors = [
            (885.943, 9_825_356, 4, 39),
            (3_180.0, 25_447_863, 4, 101),
            (900.049, 36_001_959, 2, 74),
            (14_313.326, 174_313_938, 4, 428),
        ];
        for (duration, bytes, width, expected) in anchors {
            let record = record(duration, bytes, job::STATE_PROBING, now);
            assert_eq!(self_remaining_seconds(&record, width, now), Some(expected));
        }
    }

    #[test]
    fn concurrency_and_partial_completion_change_remaining_waves() {
        let now = 1_000;
        let mut record = record(2_916.6, 46_990_136, job::STATE_TRANSCRIBING, now);
        record.chunk_work = job::init_chunk_work(10, 0);
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(88));
        assert_eq!(self_remaining_seconds(&record, 1, now), Some(270));

        for work in record.chunk_work.iter_mut().take(4) {
            work.completed = true;
        }
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(62));
    }

    /// Without a stored plan (the container fallback), preparation is a
    /// sequential phase ahead of the waves; its budget counts down against
    /// CHUNKING elapsed and the AI projection stays whole.
    #[test]
    fn chunk_preparation_precedes_ai_and_counts_down() {
        let now = 1_000;
        let mut chunking = record(6_978.4, 111_797_868, job::STATE_CHUNKING, now - 40);
        chunking.updated_at = now;
        chunking.chunk_work = job::init_chunk_work(24, 8);
        assert_eq!(self_remaining_seconds(&chunking, 4, now), Some(123));

        let mut stitching = record(2_916.6, 46_990_136, job::STATE_STITCHING, now - 3);
        stitching.updated_at = now;
        stitching.chunk_work = job::init_chunk_work(10, 10);
        assert_eq!(self_remaining_seconds(&stitching, 4, now), Some(5));
    }

    #[test]
    fn top_bitrate_sources_project_as_stream_copy_at_reduced_width() {
        let now = 1_000;
        // 320 kbps — the class the container used to normalize chunk by
        // chunk. Its five-minute chunk now sits inside the raw ceiling, so
        // preparation projects at the stream-copy rate instead of 4x that,
        // and the wave runs two chunks wide to bound in-flight audio.
        let widest_chunk = (164_041_483_f64 / 4_099.004 * job::CHUNK_SECONDS) as i64;
        assert!(widest_chunk < job::MAX_CHUNK_RAW_BYTES);
        assert_eq!(job::chunk_ai_concurrency(widest_chunk, 4), 2);

        let mut record = record(4_099.004, 164_041_483, job::STATE_PROBING, now);
        assert_eq!(self_remaining_seconds(&record, 2, now), Some(248));

        record.state = job::STATE_CHUNKING.into();
        record.phase_timestamps.clear();
        record
            .phase_timestamps
            .insert(job::STATE_CHUNKING.into(), now - 240);
        record.chunk_work = job::init_chunk_work(14, 10);
        assert_eq!(self_remaining_seconds(&record, 2, now), Some(65));
    }

    fn native_plan() -> crate::native_media::NativePlan {
        crate::native_media::NativePlan {
            algorithm_version: crate::native_media::ALGORITHM_VERSION,
            source_sha256: "a".repeat(64),
            byte_count: 36_001_959,
            etag: "etag".into(),
            canonical_duration_seconds: 900.049,
            chunks: vec![],
        }
    }

    /// A stored native plan means chunking is metadata-only, so the
    /// projection is exactly `ai + finalization` with no preparation term.
    #[test]
    fn a_stored_native_plan_zeroes_chunk_preparation() {
        let now = 1_000;
        // 320 kbps, 15 minutes. Without the plan the bytes term stays:
        // 36 MB x 0.3 + ai (2 + 1 wave x 26) + finalization (2 + 4 x 0.6).
        let mut reserved = record(900.049, 36_001_959, job::STATE_RESERVED, now);
        assert_eq!(self_remaining_seconds(&reserved, 4, now), Some(44));

        // With the plan the preparation term drops out entirely.
        reserved.native_plan = Some(native_plan());
        assert_eq!(self_remaining_seconds(&reserved, 4, now), Some(33));

        let mut chunking = record(900.049, 36_001_959, job::STATE_CHUNKING, now);
        chunking.native_plan = Some(native_plan());
        assert_eq!(self_remaining_seconds(&chunking, 4, now), Some(33));
    }

    #[test]
    fn ad_analysis_flag_adds_the_phase_and_counts_it_down() {
        let now = 1_000;
        // Flag-off anchors are byte-identical to the calibrated model.
        let baseline = record(885.943, 9_825_356, job::STATE_PROBING, now);
        assert_eq!(self_remaining_seconds(&baseline, 4, now), Some(39));

        let mut flagged = record(885.943, 9_825_356, job::STATE_PROBING, now);
        flagged.ad_analysis_requested = true;
        assert_eq!(self_remaining_seconds(&flagged, 4, now), Some(69));

        // The new state counts the phase down from its first entry.
        let mut detecting = record(885.943, 9_825_356, job::STATE_DETECTING_ADS, now - 12);
        detecting.ad_analysis_requested = true;
        detecting.updated_at = now;
        detecting.chunk_work = job::init_chunk_work(3, 3);
        assert_eq!(self_remaining_seconds(&detecting, 4, now), Some(18));

        // Elapsed past the budget clamps to the 1-second floor.
        let mut overdue = record(885.943, 9_825_356, job::STATE_DETECTING_ADS, now - 90);
        overdue.ad_analysis_requested = true;
        overdue.updated_at = now;
        overdue.chunk_work = job::init_chunk_work(3, 3);
        assert_eq!(self_remaining_seconds(&overdue, 4, now), Some(1));
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
        });
        record.chunk_work = job::init_chunk_work(4, 0);
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(33));
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
        assert_eq!(queued.remaining_seconds, Some(53));
    }
}

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
/// call floors near 19 s. Exact geometry cannot reach width one (no legal
/// MP3 chunk exceeds half `MAX_CHUNK_BYTES_IN_FLIGHT`), but an inaccurate
/// provisional duration can project an oversized chunk and land there; the
/// single conservative constant carries that case too.
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

fn valid_duration(duration: Option<f64>) -> Option<f64> {
    duration.filter(|value| value.is_finite() && *value > 0.0)
}

fn provisional_duration_seconds(record: &JobRecord) -> Option<f64> {
    valid_duration(record.canonical_duration_seconds)
        .or_else(|| {
            valid_duration(
                record
                    .device_identity
                    .as_ref()
                    .and_then(|identity| identity.duration_seconds),
            )
        })
        .or_else(|| valid_duration(record.declared_duration_seconds))
}

fn exact_source_bytes(record: &JobRecord) -> Option<i64> {
    // Byte precedence mirrors source ownership: the canonical probed count,
    // else the authenticated device count once a completed exact upload owns
    // the job's source (after a DAI mismatch, `server_byte_count` describes
    // the deleted origin variant), else the staged server count.
    record
        .canonical_source_byte_count
        .filter(|bytes| *bytes > 0)
        .or_else(|| {
            if record.upload_completed {
                record
                    .device_identity
                    .as_ref()
                    .map(|identity| identity.byte_count)
                    .filter(|bytes| *bytes > 0)
            } else {
                None
            }
        })
        .or_else(|| record.server_byte_count.filter(|bytes| *bytes > 0))
}

fn projected_max_chunk_bytes(source_bytes: i64, duration_seconds: f64) -> Option<i64> {
    if source_bytes <= 0 || !duration_seconds.is_finite() || duration_seconds <= 0.0 {
        return None;
    }
    let projected = source_bytes as f64 / duration_seconds * job::CHUNK_SECONDS;
    if !projected.is_finite() || projected <= 0.0 || projected > i64::MAX as f64 {
        return None;
    }
    Some(projected.ceil() as i64)
}

/// The one geometry clamp on the ETA side. `configured_concurrency` is the
/// raw configured ceiling (or the FAKE_AI per-job override), never a value
/// `chunk_ai_concurrency` already clamped: exact plan/manifest geometry, else
/// provisional geometry before a plan exists, else the container ceiling.
fn projected_chunk_concurrency(
    record: &JobRecord,
    configured_concurrency: u32,
    duration_seconds: f64,
    source_bytes: i64,
) -> u32 {
    let provisional_max_chunk_bytes = matches!(
        record.state.as_str(),
        job::STATE_SOURCE_MATCHED | job::STATE_PROBING
    )
    .then(|| projected_max_chunk_bytes(source_bytes, duration_seconds))
    .flatten();
    let max_chunk_bytes = record
        .exact_max_chunk_bytes()
        .or(provisional_max_chunk_bytes)
        .unwrap_or(job::CONTAINER_MAX_CHUNK_RAW_BYTES);
    job::chunk_ai_concurrency(max_chunk_bytes, configured_concurrency)
}

/// One budget for the expected native probe walk: the probe/reservation
/// floor plus the calibrated native source-walk rate. The countdown inside
/// `source_matched`/`probing` and the delayed-classification boundary both
/// read this so they cannot drift. The 2.0 s/MB normalization rate belongs
/// to an actual container preparation path after probing, never here — even
/// when an inaccurate provisional duration projects an oversized chunk.
fn native_scan_budget_seconds(source_bytes: i64) -> f64 {
    PROBE_AND_RESERVATION_SECONDS
        + source_bytes.max(0) as f64 / 1_000_000.0 * CHUNK_PREPARATION_SECONDS_PER_MB
}

/// `configured_concurrency` is the configured wave ceiling (or the FAKE_AI
/// per-job override) *before* any geometry clamp;
/// `projected_chunk_concurrency` applies `chunk_ai_concurrency` exactly once
/// against the geometry this projection sees. Passing a value the driver
/// already clamped would double-clamp and understate width.
pub fn self_remaining_seconds(
    record: &JobRecord,
    configured_concurrency: u32,
    now: i64,
) -> Option<u32> {
    let duration = provisional_duration_seconds(record)?;
    let expected_total = expected_chunk_count(duration)?;
    let (completed, total) = chunk_progress(record).unwrap_or((0, expected_total));
    let total = total.max(1);
    let remaining_chunks = total.saturating_sub(completed.min(total));
    let source_bytes = exact_source_bytes(record)?;
    let chunk_concurrency =
        projected_chunk_concurrency(record, configured_concurrency, duration, source_bytes);
    let ai_seconds = if remaining_chunks == 0 {
        0.0
    } else {
        let waves = remaining_chunks.div_ceil(chunk_concurrency.max(1));
        AI_SCHEDULING_SECONDS + f64::from(waves) * AI_WAVE_SECONDS
    };
    // A stored native plan means chunking is metadata-only: the manifest is
    // built from the plan with zero R2 I/O, so there is no preparation phase
    // left to project. Without a plan the bytes-based figure stands in for
    // the container chunk pass after probing: the stream-copy rate when the
    // five-minute chunk fits the raw envelope, the normalization rate when
    // it does not. (The expected native walk during `source_matched`/
    // `probing` uses `native_scan_budget_seconds` instead.) Nothing overlaps
    // AI any more — the overlap driver is retired — so preparation is
    // sequential with the wave phase.
    let chunk_preparation_seconds = if record.native_plan.is_some() {
        0.0
    } else {
        let stream_copy_bytes_per_chunk =
            source_bytes.max(0) as f64 / duration * job::CHUNK_SECONDS;
        let preparation_seconds_per_mb =
            if stream_copy_bytes_per_chunk > job::MAX_CHUNK_RAW_BYTES as f64 {
                NORMALIZED_CHUNK_PREPARATION_SECONDS_PER_MB
            } else {
                CHUNK_PREPARATION_SECONDS_PER_MB
            };
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
            // The native walk runs inside PROBING; the same calibrated scan
            // budget that classifies `delayed` counts down here.
            let elapsed = elapsed_since_first(
                record,
                &[job::STATE_SOURCE_MATCHED, job::STATE_PROBING],
                now,
            );
            let staged = (native_scan_budget_seconds(source_bytes) - elapsed).max(0.0);
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

pub fn project(record: &JobRecord, configured_concurrency: u32, now: i64) -> Option<EtaProjection> {
    let own_remaining = self_remaining_seconds(record, configured_concurrency, now)?;
    if record.queued_since.is_some() {
        if let Some(queue_wait) = record.queue_wait_seconds {
            return Some(EtaProjection {
                remaining_seconds: Some(own_remaining.saturating_add(queue_wait)),
                status: EstimateStatus::Queued,
            });
        }
    }
    let delayed = if matches!(
        record.state.as_str(),
        job::STATE_SOURCE_MATCHED | job::STATE_PROBING
    ) {
        let source_bytes = exact_source_bytes(record)?;
        elapsed_since_first(
            record,
            &[job::STATE_SOURCE_MATCHED, job::STATE_PROBING],
            now,
        ) >= native_scan_budget_seconds(source_bytes) + DELAYED_AFTER_SECONDS as f64
    } else {
        now.saturating_sub(record.updated_at) >= DELAYED_AFTER_SECONDS
    };
    if delayed {
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
    let started_at = states
        .iter()
        .filter_map(|state| record.phase_timestamps.get(*state))
        .min()
        .copied()
        .unwrap_or(record.updated_at);
    now.saturating_sub(started_at).max(0) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn created_record(declared_duration: Option<f64>, now: i64) -> JobRecord {
        JobRecord::created(
            "job-eta".into(),
            "account".into(),
            "episode".into(),
            None,
            declared_duration,
            None,
            None,
            now,
        )
    }

    fn source_matched_record(
        declared_duration: Option<f64>,
        device_duration: Option<f64>,
        byte_count: i64,
        now: i64,
    ) -> JobRecord {
        let mut record = created_record(declared_duration, now);
        record.device_identity = Some(crate::types::SourceIdentity {
            sha256: "aa".repeat(32),
            byte_count,
            duration_seconds: device_duration,
            entity_tag: None,
            last_modified: None,
        });
        record.server_sha256 = Some("aa".repeat(32));
        record.server_byte_count = Some(byte_count);
        record.state = job::STATE_SOURCE_MATCHED.into();
        record
            .phase_timestamps
            .insert(job::STATE_SOURCE_MATCHED.into(), now);
        record
    }

    fn first_native_probe_record(
        declared_duration: Option<f64>,
        device_duration: Option<f64>,
        byte_count: i64,
        now: i64,
    ) -> JobRecord {
        let mut record = source_matched_record(declared_duration, device_duration, byte_count, now);
        record.state = job::STATE_PROBING.into();
        record
            .phase_timestamps
            .insert(job::STATE_PROBING.into(), now);
        record
    }

    /// Realistic stream-copy manifest for a canonical duration/byte pair:
    /// `expected_chunk_count` chunks, uniform five-minute widths with the
    /// remainder in the final chunk.
    fn manifest_chunks(duration: f64, byte_count: i64) -> Vec<job::ChunkRef> {
        let count = expected_chunk_count(duration).expect("positive duration");
        let full = (byte_count as f64 / duration * job::CHUNK_SECONDS).ceil() as i64;
        (0..count)
            .map(|index| {
                let start = i64::from(index) * full;
                job::ChunkRef {
                    index,
                    key: format!("chunks/job-eta/{index}.mp3"),
                    requested_start_seconds: f64::from(index) * job::STEP_SECONDS,
                    actual_duration_seconds: job::CHUNK_SECONDS.min(duration),
                    valid_start_seconds: 0.0,
                    valid_end_seconds: duration,
                    byte_count: full.min(byte_count - start),
                    sha256: "b".repeat(64),
                }
            })
            .collect()
    }

    /// Post-probe fixture built directly (no layered undo): canonical
    /// duration/bytes plus the chunk manifest production necessarily has
    /// once chunking is behind it. `reserved`/`chunking` keep an empty
    /// manifest — the container is still writing theirs.
    fn canonical_pipeline_record(
        duration: f64,
        byte_count: i64,
        state: &str,
        state_started_at: i64,
    ) -> JobRecord {
        let mut record = created_record(Some(duration), state_started_at);
        record.device_identity = Some(crate::types::SourceIdentity {
            sha256: "aa".repeat(32),
            byte_count,
            duration_seconds: Some(duration),
            entity_tag: None,
            last_modified: None,
        });
        record.server_sha256 = Some("aa".repeat(32));
        record.server_byte_count = Some(byte_count);
        record.canonical_source_sha256 = Some("aa".repeat(32));
        record.canonical_source_byte_count = Some(byte_count);
        record.canonical_duration_seconds = Some(duration);
        if state != job::STATE_RESERVED && state != job::STATE_CHUNKING {
            record.chunks = manifest_chunks(duration, byte_count);
        }
        record.state = state.into();
        record
            .phase_timestamps
            .insert(state.into(), state_started_at);
        record.updated_at = state_started_at;
        record
    }

    fn native_plan(
        canonical_duration_seconds: f64,
        source_bytes: i64,
        chunk_bytes: &[i64],
    ) -> crate::native_media::NativePlan {
        crate::native_media::NativePlan {
            algorithm_version: crate::native_media::ALGORITHM_VERSION,
            source_sha256: "a".repeat(64),
            byte_count: source_bytes,
            etag: "etag".into(),
            canonical_duration_seconds,
            chunks: chunk_bytes
                .iter()
                .enumerate()
                .map(|(index, byte_count)| crate::native_media::NativePlanChunk {
                    index: index as u32,
                    spans: vec![[0, *byte_count as u64]],
                    byte_count: *byte_count,
                    actual_duration_seconds: job::CHUNK_SECONDS,
                    sha256: Some("b".repeat(64)),
                })
                .collect(),
        }
    }

    #[test]
    fn first_probe_has_only_exact_bytes_and_provisional_duration() {
        let now = 1_000;
        let record = first_native_probe_record(Some(1_200.0), Some(900.0), 36_001_959, now);

        assert_eq!(record.server_byte_count, Some(36_001_959));
        assert_eq!(provisional_duration_seconds(&record), Some(900.0));
        assert_eq!(record.canonical_source_byte_count, None);
        assert_eq!(record.canonical_duration_seconds, None);
        assert_eq!(record.native_plan, None);

        let projection = project(&record, 4, now).expect("provisional ETA");
        assert_eq!(projection.status, EstimateStatus::OnTrack);
        assert_eq!(projection.remaining_seconds, Some(74));
    }

    #[test]
    fn provisional_duration_precedence_is_device_then_feed() {
        let now = 1_000;
        let measured = source_matched_record(Some(1_200.0), Some(900.0), 10_000_000, now);
        assert_eq!(provisional_duration_seconds(&measured), Some(900.0));

        let feed_only = source_matched_record(Some(1_200.0), None, 10_000_000, now);
        assert_eq!(provisional_duration_seconds(&feed_only), Some(1_200.0));
    }

    /// 46,990,136 B / 2,916.6 s → 10 manifest chunks of ≤4,833,585 B →
    /// width 4. All 10 remaining: 3 waves → AI 2 + 78 = 80; final
    /// 2 + 10 × 0.6 = 8 → 88 (width 1: 10 waves → 262 + 8 = 270). With 4
    /// complete: 6 left → 2 waves → AI 54 + 8 = 62.
    #[test]
    fn concurrency_and_partial_completion_change_remaining_waves() {
        let now = 1_000;
        let mut record =
            canonical_pipeline_record(2_916.6, 46_990_136, job::STATE_TRANSCRIBING, now);
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
    /// CHUNKING elapsed and the AI projection stays whole. 111,797,868 B /
    /// 6,978.4 s: prep 111.8 × 0.3 = 33.5 fully elapsed at 40 s; 16 of 24
    /// chunks left at the container's assumed width 4 → 4 waves → AI
    /// 2 + 104 = 106; final 2 + 14.4 = 16.4 → ceil(122.4) = 123. Stitching:
    /// final 2 + 10 × 0.6 = 8, elapsed 3 → 5.
    #[test]
    fn chunk_preparation_precedes_ai_and_counts_down() {
        let now = 1_000;
        let mut chunking =
            canonical_pipeline_record(6_978.4, 111_797_868, job::STATE_CHUNKING, now - 40);
        chunking.chunk_work = job::init_chunk_work(24, 8);
        assert_eq!(self_remaining_seconds(&chunking, 4, now), Some(123));

        let mut stitching =
            canonical_pipeline_record(2_916.6, 46_990_136, job::STATE_STITCHING, now - 3);
        stitching.chunk_work = job::init_chunk_work(10, 10);
        assert_eq!(self_remaining_seconds(&stitching, 4, now), Some(5));
    }

    /// 320 kbps class: 164,041,483 B / 4,099.004 s projects 12,005,653 B
    /// chunks → the in-flight budget affords two lanes. First probe: scan
    /// 4 + 164.04 × 0.3 = 53.21; 14 chunks / width 2 → 7 waves → AI
    /// 2 + 182 = 184; final 2 + 8.4 = 10.4 → ceil(247.6) = 248.
    #[test]
    fn top_bitrate_sources_project_as_stream_copy_at_reduced_width() {
        let now = 1_000;
        let record = first_native_probe_record(Some(4_099.004), Some(4_099.004), 164_041_483, now);
        let widest_chunk = projected_max_chunk_bytes(164_041_483, 4_099.004).unwrap();
        assert!(widest_chunk < job::MAX_CHUNK_RAW_BYTES);
        assert_eq!(
            projected_chunk_concurrency(&record, 4, 4_099.004, 164_041_483),
            2
        );
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(248));

        // Container-fallback chunking pass on the same source, mid-build
        // (no manifest yet): preparation 164.04 × 0.3 = 49.2 fully elapsed
        // at 240 s; 4 chunks left at the container's assumed width 4 → one
        // wave → AI 28; final 10.4 → ceil(38.4) = 39.
        let mut chunking =
            canonical_pipeline_record(4_099.004, 164_041_483, job::STATE_CHUNKING, now - 240);
        chunking.chunk_work = job::init_chunk_work(14, 10);
        assert_eq!(self_remaining_seconds(&chunking, 4, now), Some(39));
    }

    #[test]
    fn canonical_duration_and_exact_plan_replace_provisional_inputs() {
        let now = 1_000;
        let mut record = first_native_probe_record(Some(1_200.0), Some(900.0), 36_001_959, now);
        assert_eq!(provisional_duration_seconds(&record), Some(900.0));
        assert_eq!(
            projected_chunk_concurrency(&record, 4, 900.0, 36_001_959),
            2
        );
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(74));

        record.canonical_source_byte_count = Some(36_001_959);
        record.canonical_duration_seconds = Some(600.0);
        record.native_plan = Some(native_plan(
            600.0,
            36_001_959,
            &[6_000_000, 6_100_000, 6_050_000],
        ));
        record.state = job::STATE_RESERVED.into();
        record
            .phase_timestamps
            .insert(job::STATE_RESERVED.into(), now);

        assert_eq!(provisional_duration_seconds(&record), Some(600.0));
        assert_eq!(
            projected_chunk_concurrency(&record, 4, 600.0, 36_001_959),
            4
        );
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(32));
    }

    #[test]
    fn expected_native_scan_counts_down_without_premature_delay() {
        let now = 1_000;
        let mut record =
            first_native_probe_record(Some(4_099.004), Some(4_099.004), 164_041_483, now - 75);
        record.updated_at = now - 75;

        let projection = project(&record, 4, now).expect("ETA during expected scan");
        assert_eq!(projection.status, EstimateStatus::OnTrack);
        assert_eq!(projection.remaining_seconds, Some(195));

        record
            .phase_timestamps
            .insert(job::STATE_PROBING.into(), now - 84);
        record
            .phase_timestamps
            .insert(job::STATE_SOURCE_MATCHED.into(), now - 84);
        let delayed = project(&record, 4, now).expect("delayed ETA classification");
        assert_eq!(delayed.status, EstimateStatus::Delayed);
        assert_eq!(delayed.remaining_seconds, None);
    }

    #[test]
    fn missing_duration_stays_indeterminate() {
        let record = first_native_probe_record(None, None, 36_001_959, 1_000);
        assert_eq!(provisional_duration_seconds(&record), None);
        assert_eq!(self_remaining_seconds(&record, 4, 1_000), None);
        assert_eq!(project(&record, 4, 1_000), None);
    }

    #[test]
    fn ad_analysis_flag_adds_the_phase_and_counts_it_down() {
        let now = 1_000;
        let baseline = first_native_probe_record(Some(885.943), Some(885.943), 9_825_356, now);
        assert_eq!(self_remaining_seconds(&baseline, 4, now), Some(39));

        let mut flagged = first_native_probe_record(Some(885.943), Some(885.943), 9_825_356, now);
        flagged.ad_analysis_requested = true;
        assert_eq!(self_remaining_seconds(&flagged, 4, now), Some(69));

        let mut detecting =
            canonical_pipeline_record(885.943, 9_825_356, job::STATE_DETECTING_ADS, now - 12);
        detecting.ad_analysis_requested = true;
        detecting.chunk_work = job::init_chunk_work(3, 3);
        assert_eq!(self_remaining_seconds(&detecting, 4, now), Some(18));

        let mut overdue =
            canonical_pipeline_record(885.943, 9_825_356, job::STATE_DETECTING_ADS, now - 90);
        overdue.ad_analysis_requested = true;
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
            let mut record = source_matched_record(Some(900.0), Some(900.0), 10_000_000, now);
            record.state = state.into();
            record.phase_timestamps.clear();
            record.phase_timestamps.insert(state.into(), now);
            assert_eq!(self_remaining_seconds(&record, 4, now), None, "{state}");
        }
    }

    /// After a DAI mismatch and completed exact upload, `server_byte_count`
    /// still describes the deleted origin variant. Width and the delayed
    /// budget must follow the uploaded device bytes until the canonical
    /// probe replaces them.
    #[test]
    fn exact_upload_uses_the_authenticated_device_byte_count() {
        let now = 1_000;
        // Uploaded device copy: 36,001,959 B / 900 s (320 kbps class) →
        // 12,000,653 B projected chunks → width 2. The deleted origin
        // variant was smaller: 24,001,306 B would project 8,000,435 B
        // chunks → width 3 — width 2 proves the device bytes drive it.
        let mut record = first_native_probe_record(Some(1_200.0), Some(900.0), 36_001_959, now);
        record.server_sha256 = Some("bb".repeat(32));
        record.server_byte_count = Some(24_001_306);
        record.upload_completed = true;

        assert_eq!(exact_source_bytes(&record), Some(36_001_959));
        assert_eq!(
            projected_chunk_concurrency(&record, 4, 900.0, 36_001_959),
            2
        );
        // Same figure as the staged-server 36 MB first-probe case: the
        // uploaded identity fully replaces the stale origin count.
        assert_eq!(self_remaining_seconds(&record, 4, now), Some(74));

        // The delayed boundary follows the uploaded size too: device budget
        // 4 + 36.0 × 0.3 + 30 ≈ 44.8 s, stale-origin budget would be
        // 4 + 24.0 × 0.3 + 30 ≈ 41.2 s — on-track at 43 s proves the
        // device bytes drive the boundary.
        for state in [job::STATE_SOURCE_MATCHED, job::STATE_PROBING] {
            record.phase_timestamps.insert(state.into(), now - 43);
        }
        assert_eq!(
            project(&record, 4, now).unwrap().status,
            EstimateStatus::OnTrack
        );
        for state in [job::STATE_SOURCE_MATCHED, job::STATE_PROBING] {
            record.phase_timestamps.insert(state.into(), now - 45);
        }
        assert_eq!(
            project(&record, 4, now).unwrap().status,
            EstimateStatus::Delayed
        );
    }

    /// The two widest measured calibration anchors (2026-08-05 bakeoff) in
    /// realistic first-probe shape — staged bytes plus device duration, no
    /// canonical truth yet. Derivations at elapsed 0 (scan = 4 + 0.3 × MB;
    /// AI = 2 + 26 × waves; final = 2 + 0.6 × chunks; width 4):
    ///
    /// | duration | bytes | chunks | waves | scan | AI | final | ETA |
    /// |---:|---:|---:|---:|---:|---:|---:|---:|
    /// | 3,180.0 | 25,447,863 | 11 | 3 | 11.63 | 80 | 8.6 | 101 |
    /// | 14,313.326 | 174,313,938 | 49 | 13 | 56.29 | 340 | 31.4 | 428 |
    #[test]
    fn widest_calibration_anchors_project_from_first_probe_records() {
        let now = 1_000;
        let three_waves = first_native_probe_record(Some(3_180.0), Some(3_180.0), 25_447_863, now);
        assert_eq!(self_remaining_seconds(&three_waves, 4, now), Some(101));

        let thirteen_waves =
            first_native_probe_record(Some(14_313.326), Some(14_313.326), 174_313_938, now);
        assert_eq!(self_remaining_seconds(&thirteen_waves, 4, now), Some(428));
    }

    /// A configured ceiling above four (the FAKE_AI override range) must
    /// not arrive pre-clamped by the container geometry: a low-bitrate
    /// source genuinely affords more than five lanes. 28,800,000 B /
    /// 3,600 s (64 kbps) projects 2,400,000 B chunks → the in-flight
    /// budget affords 10 lanes → the configured 8 stands. 13 chunks → 2
    /// waves: scan 4 + 8.64 = 12.64; AI 2 + 52 = 54; final 2 + 7.8 = 9.8
    /// → ceil(76.44) = 77. A pre-clamped ceiling (min(8, container 5) = 5)
    /// would take 3 waves and report 103 instead.
    #[test]
    fn configured_ceiling_above_four_is_clamped_once_by_projected_geometry() {
        let now = 1_000;
        let record = first_native_probe_record(Some(3_600.0), Some(3_600.0), 28_800_000, now);
        assert_eq!(
            projected_chunk_concurrency(&record, 8, 3_600.0, 28_800_000),
            8
        );
        assert_eq!(self_remaining_seconds(&record, 8, now), Some(77));
    }

    #[test]
    fn delayed_threshold_is_thirty_seconds_and_queued_wins() {
        let now = 1_000;
        let mut record = canonical_pipeline_record(900.0, 10_000_000, job::STATE_TRANSCRIBING, now);
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

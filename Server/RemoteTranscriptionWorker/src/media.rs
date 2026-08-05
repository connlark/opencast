//! Contract with `TranscriptionMediaWorker` (B6): probe then chunk, both POST
//! JSON over the service binding. The media worker only ever receives job ID
//! and object keys; validation decisions stay here.

use serde::{Deserialize, Serialize};

use crate::types::{ERROR_DURATION_TOO_LONG, ERROR_SOURCE_TOO_LARGE, ERROR_UNSUPPORTED_MEDIA_TYPE};

const MANIFEST_TIMING_TOLERANCE_SECONDS: f64 = 0.001;
const FINAL_COVERAGE_TOLERANCE_SECONDS: f64 = 0.1;

pub const MEDIA_BINDING: &str = "TRANSCRIPTION_MEDIA_WORKER";
pub const MEDIA_PROBE_PATH: &str = "/probe";
pub const MEDIA_CHUNK_PATH: &str = "/chunk";
/// Create-time wake ping (pass 0.5 A3): starts the container without waiting
/// for readiness so its cold start overlaps staging and the hash-match wait.
pub const MEDIA_WAKE_PATH: &str = "/wake";
pub const MEDIA_INTERNAL_ORIGIN: &str = "https://transcription-media.opencast.internal";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaProbeRequest {
    pub job_id: String,
    pub source_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaProbeResponse {
    pub duration_seconds: f64,
    pub codec: String,
    pub audio_stream_count: u32,
    pub byte_count: i64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaChunkRequest {
    pub job_id: String,
    pub source_key: String,
    pub chunk_prefix: String,
    pub chunk_seconds: f64,
    pub overlap_seconds: f64,
    pub max_chunk_raw_bytes: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaChunkEntry {
    pub index: u32,
    pub key: String,
    pub requested_start_seconds: f64,
    pub requested_duration_seconds: f64,
    pub actual_duration_seconds: f64,
    pub byte_count: i64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaChunkResponse {
    pub chunks: Vec<MediaChunkEntry>,
    pub manifest_sha256: String,
    #[serde(default)]
    pub chunk_audio_profile: Option<String>,
}

/// Media worker calls fail in two ways: contract rejections (fatal, mapped to
/// stable app error codes) and infrastructure hiccups (retryable — container
/// cold starts, R2 read lag, 5xx). Fatal-vs-retryable must be explicit so a
/// cold-starting container never kills a job.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaCallFailure {
    Fatal(&'static str),
    Retryable,
}

pub const MEDIA_MAX_ATTEMPTS: u32 = 10;
pub const MEDIA_RETRY_SECONDS: u64 = 20;

pub fn classify_media_failure(status: u16, error_code: Option<&str>) -> MediaCallFailure {
    match (status, error_code) {
        (422, _) => MediaCallFailure::Fatal(ERROR_UNSUPPORTED_MEDIA_TYPE),
        (413, Some("source_too_large")) => MediaCallFailure::Fatal(ERROR_SOURCE_TOO_LARGE),
        // The media worker normalizes supported MP3 before enforcing the
        // model envelope. Any remaining chunk overflow is an internal
        // contract/configuration failure, not an unsupported customer file.
        (413, _) => MediaCallFailure::Fatal(crate::types::ERROR_INTERNAL),
        (400, _) => MediaCallFailure::Fatal(crate::types::ERROR_INTERNAL),
        _ => MediaCallFailure::Retryable,
    }
}

/// Post-probe validation (parent plan): exact identity recomputation, MP3
/// only in pass 0, one audio stream, caps. Returns a stable error code.
pub fn validate_probe(
    probe: &MediaProbeResponse,
    expected_sha256: &str,
    expected_byte_count: i64,
    max_duration_seconds: f64,
    max_source_bytes: i64,
) -> Result<(), &'static str> {
    if !probe.sha256.eq_ignore_ascii_case(expected_sha256)
        || probe.byte_count != expected_byte_count
    {
        return Err(crate::types::ERROR_SOURCE_MISMATCH);
    }
    if !probe.codec.eq_ignore_ascii_case("mp3") || probe.audio_stream_count != 1 {
        return Err(ERROR_UNSUPPORTED_MEDIA_TYPE);
    }
    if probe.byte_count > max_source_bytes {
        return Err(ERROR_SOURCE_TOO_LARGE);
    }
    if !probe.duration_seconds.is_finite()
        || probe.duration_seconds <= 0.0
        || probe.duration_seconds > max_duration_seconds
    {
        return Err(ERROR_DURATION_TOO_LONG);
    }
    Ok(())
}

/// Names the exact predicate that rejected a chunk manifest. The wire error
/// stays the opaque stable `internal_error` (`code()`); the reason/detail
/// exist so the call site can log which chunk and which contract failed —
/// a bare `internal_error` cost a full telemetry bisect to localize
/// (2026-08-04 short-episode bug).
#[derive(Debug, Clone, PartialEq)]
pub struct ChunkRejection {
    pub position: Option<usize>,
    pub reason: &'static str,
    pub detail: String,
}

impl ChunkRejection {
    pub fn code(&self) -> &'static str {
        crate::types::ERROR_INTERNAL
    }

    fn at(position: usize, reason: &'static str, detail: String) -> Self {
        Self {
            position: Some(position),
            reason,
            detail,
        }
    }

    fn manifest(reason: &'static str, detail: String) -> Self {
        Self {
            position: None,
            reason,
            detail,
        }
    }
}

impl std::fmt::Display for ChunkRejection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.position {
            Some(position) => write!(f, "{} at chunk {}: {}", self.reason, position, self.detail),
            None => write!(f, "{}: {}", self.reason, self.detail),
        }
    }
}

/// The chunk manifest is authenticated service output, so malformed entries
/// are an internal contract failure rather than unsupported customer media.
pub fn validate_chunks(
    chunks: &[MediaChunkEntry],
    max_chunk_raw_bytes: i64,
    canonical_duration_seconds: f64,
    chunk_seconds: f64,
    step_seconds: f64,
) -> Result<(), ChunkRejection> {
    if chunks.is_empty()
        || !canonical_duration_seconds.is_finite()
        || canonical_duration_seconds <= 0.0
        || !chunk_seconds.is_finite()
        || chunk_seconds <= 0.0
        || !step_seconds.is_finite()
        || step_seconds <= 0.0
        || step_seconds > chunk_seconds
    {
        return Err(ChunkRejection::manifest(
            "invalid_manifest_contract",
            format!(
                "chunks {} canonical {canonical_duration_seconds} chunk_seconds {chunk_seconds} step_seconds {step_seconds}",
                chunks.len()
            ),
        ));
    }
    let overlap_seconds = chunk_seconds - step_seconds;
    let mut previous_valid_end = 0.0;
    for (position, chunk) in chunks.iter().enumerate() {
        let expected_start = position as f64 * step_seconds;
        let Some((valid_start, valid_end)) =
            valid_chunk_interval(chunk, canonical_duration_seconds)
        else {
            return Err(ChunkRejection::at(
                position,
                "invalid_chunk_interval",
                format!(
                    "requested_start {} requested_duration {} actual_duration {} canonical {canonical_duration_seconds}",
                    chunk.requested_start_seconds,
                    chunk.requested_duration_seconds,
                    chunk.actual_duration_seconds
                ),
            ));
        };
        let ownership_boundary =
            (valid_start + overlap_seconds / 2.0).min(canonical_duration_seconds);
        if chunk.index as usize != position {
            return Err(ChunkRejection::at(
                position,
                "index_out_of_order",
                format!("manifest index {}", chunk.index),
            ));
        }
        if chunk.byte_count <= 0 || chunk.byte_count > max_chunk_raw_bytes {
            return Err(ChunkRejection::at(
                position,
                "byte_count_out_of_bounds",
                format!("byte_count {} max {max_chunk_raw_bytes}", chunk.byte_count),
            ));
        }
        if !chunk.requested_start_seconds.is_finite()
            || chunk.requested_start_seconds < 0.0
            || (chunk.requested_start_seconds - expected_start).abs()
                > MANIFEST_TIMING_TOLERANCE_SECONDS
        {
            return Err(ChunkRejection::at(
                position,
                "requested_start_off_grid",
                format!(
                    "requested_start {} expected {expected_start}",
                    chunk.requested_start_seconds
                ),
            ));
        }
        if !chunk.requested_duration_seconds.is_finite()
            || chunk.requested_duration_seconds <= 0.0
            || (chunk.requested_duration_seconds - chunk_seconds).abs()
                > MANIFEST_TIMING_TOLERANCE_SECONDS
        {
            return Err(ChunkRejection::at(
                position,
                "requested_duration_off_contract",
                format!(
                    "requested_duration {} expected {chunk_seconds}",
                    chunk.requested_duration_seconds
                ),
            ));
        }
        if !chunk.actual_duration_seconds.is_finite() || chunk.actual_duration_seconds <= 0.0 {
            return Err(ChunkRejection::at(
                position,
                "actual_duration_invalid",
                format!("actual_duration {}", chunk.actual_duration_seconds),
            ));
        }
        if position > 0
            && previous_valid_end + MANIFEST_TIMING_TOLERANCE_SECONDS < ownership_boundary
        {
            return Err(ChunkRejection::at(
                position,
                "seam_coverage_gap",
                format!(
                    "previous_valid_end {previous_valid_end} ownership_boundary {ownership_boundary}"
                ),
            ));
        }
        if chunk.sha256.len() != 64 || !chunk.sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(ChunkRejection::at(
                position,
                "sha256_malformed",
                format!("length {}", chunk.sha256.len()),
            ));
        }
        previous_valid_end = valid_end;
    }
    if canonical_duration_seconds - previous_valid_end > FINAL_COVERAGE_TOLERANCE_SECONDS {
        return Err(ChunkRejection::manifest(
            "final_coverage_gap",
            format!(
                "canonical {canonical_duration_seconds} previous_valid_end {previous_valid_end} tolerance {FINAL_COVERAGE_TOLERANCE_SECONDS}"
            ),
        ));
    }
    Ok(())
}

/// Intersect the encoded chunk's measured span with both its requested source
/// span and the canonical source duration. MP3 frame padding can make the
/// encoded duration slightly longer than either source interval, so it never
/// expands what model timestamps are allowed to claim.
pub fn valid_chunk_interval(
    chunk: &MediaChunkEntry,
    canonical_duration_seconds: f64,
) -> Option<(f64, f64)> {
    let start = chunk.requested_start_seconds;
    let requested_end = start + chunk.requested_duration_seconds;
    let measured_end = start + chunk.actual_duration_seconds;
    let end = requested_end
        .min(measured_end)
        .min(canonical_duration_seconds);
    if !start.is_finite()
        || !requested_end.is_finite()
        || !measured_end.is_finite()
        || !end.is_finite()
        || start < 0.0
        || end <= start
    {
        return None;
    }
    Some((start, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe() -> MediaProbeResponse {
        MediaProbeResponse {
            duration_seconds: 2040.0,
            codec: "mp3".to_string(),
            audio_stream_count: 1,
            byte_count: 16_328_368,
            sha256: "DA26A00F".to_string(),
        }
    }

    #[test]
    fn probe_validation_matrix() {
        let max_duration = 7200.0;
        let max_bytes = 268_435_456;
        assert!(validate_probe(&probe(), "da26a00f", 16_328_368, max_duration, max_bytes).is_ok());

        assert_eq!(
            validate_probe(&probe(), "other", 16_328_368, max_duration, max_bytes),
            Err(crate::types::ERROR_SOURCE_MISMATCH)
        );
        assert_eq!(
            validate_probe(&probe(), "da26a00f", 1, max_duration, max_bytes),
            Err(crate::types::ERROR_SOURCE_MISMATCH)
        );

        let mut aac = probe();
        aac.codec = "aac".to_string();
        assert_eq!(
            validate_probe(&aac, "da26a00f", 16_328_368, max_duration, max_bytes),
            Err(ERROR_UNSUPPORTED_MEDIA_TYPE)
        );

        let mut multi = probe();
        multi.audio_stream_count = 2;
        assert_eq!(
            validate_probe(&multi, "da26a00f", 16_328_368, max_duration, max_bytes),
            Err(ERROR_UNSUPPORTED_MEDIA_TYPE)
        );

        let mut long = probe();
        long.duration_seconds = 7201.0;
        assert_eq!(
            validate_probe(&long, "da26a00f", 16_328_368, max_duration, max_bytes),
            Err(ERROR_DURATION_TOO_LONG)
        );

        let mut big = probe();
        big.byte_count = max_bytes + 1;
        assert_eq!(
            validate_probe(&big, "da26a00f", big.byte_count, max_duration, max_bytes),
            Err(ERROR_SOURCE_TOO_LARGE)
        );
    }

    #[test]
    fn media_failures_classify_fatal_vs_retryable() {
        assert_eq!(
            classify_media_failure(422, Some("probe_failed")),
            MediaCallFailure::Fatal(ERROR_UNSUPPORTED_MEDIA_TYPE)
        );
        assert_eq!(
            classify_media_failure(413, Some("source_too_large")),
            MediaCallFailure::Fatal(crate::types::ERROR_SOURCE_TOO_LARGE)
        );
        assert_eq!(
            classify_media_failure(413, Some("chunk_too_large")),
            MediaCallFailure::Fatal(crate::types::ERROR_INTERNAL)
        );
        assert_eq!(
            classify_media_failure(413, Some("normalized_chunk_too_large")),
            MediaCallFailure::Fatal(crate::types::ERROR_INTERNAL)
        );
        // Cold starts, missing propagation, stub 501s, 5xx: retryable.
        for status in [404u16, 500, 501, 502, 503] {
            assert_eq!(
                classify_media_failure(status, None),
                MediaCallFailure::Retryable
            );
        }
    }

    #[test]
    fn chunk_validation_requires_sequential_bounded_chunks() {
        let entry = MediaChunkEntry {
            index: 0,
            key: "chunks/job/0.mp3".to_string(),
            requested_start_seconds: 0.0,
            requested_duration_seconds: 300.0,
            actual_duration_seconds: 300.042,
            byte_count: 2_400_339,
            sha256: "a".repeat(64),
        };
        assert!(validate_chunks(
            std::slice::from_ref(&entry),
            5 * 1024 * 1024,
            300.0,
            300.0,
            298.0,
        )
        .is_ok());
        let empty = validate_chunks(&[], 5 * 1024 * 1024, 300.0, 300.0, 298.0).unwrap_err();
        assert_eq!(empty.reason, "invalid_manifest_contract");
        assert_eq!(empty.code(), crate::types::ERROR_INTERNAL);

        let mut oversized = entry.clone();
        oversized.byte_count = 6 * 1024 * 1024;
        assert_eq!(
            validate_chunks(&[oversized], 5 * 1024 * 1024, 300.0, 300.0, 298.0)
                .unwrap_err()
                .reason,
            "byte_count_out_of_bounds"
        );

        let mut out_of_order = entry;
        out_of_order.index = 1;
        assert_eq!(
            validate_chunks(&[out_of_order], 5 * 1024 * 1024, 300.0, 300.0, 298.0)
                .unwrap_err()
                .reason,
            "index_out_of_order"
        );

        let gap = MediaChunkEntry {
            index: 1,
            key: "chunks/job/1.mp3".to_string(),
            requested_start_seconds: 298.0,
            requested_duration_seconds: 300.0,
            actual_duration_seconds: 2.0,
            byte_count: 20_000,
            sha256: "b".repeat(64),
        };
        let insufficient_seam_coverage = MediaChunkEntry {
            actual_duration_seconds: 298.998,
            ..MediaChunkEntry {
                index: 0,
                key: "chunks/job/0.mp3".to_string(),
                requested_start_seconds: 0.0,
                requested_duration_seconds: 300.0,
                actual_duration_seconds: 300.042,
                byte_count: 2_400_339,
                sha256: "a".repeat(64),
            }
        };
        assert_eq!(
            validate_chunks(
                &[insufficient_seam_coverage.clone(), gap.clone()],
                5 * 1024 * 1024,
                300.0,
                300.0,
                298.0,
            )
            .unwrap_err()
            .reason,
            "seam_coverage_gap"
        );

        let sufficient_seam_coverage = MediaChunkEntry {
            actual_duration_seconds: 299.0,
            ..insufficient_seam_coverage
        };
        assert!(validate_chunks(
            &[sufficient_seam_coverage, gap],
            5 * 1024 * 1024,
            300.0,
            300.0,
            298.0,
        )
        .is_ok());

        let short_terminal_overlap = MediaChunkEntry {
            actual_duration_seconds: 0.5,
            ..MediaChunkEntry {
                index: 1,
                key: "chunks/job/1.mp3".to_string(),
                requested_start_seconds: 298.0,
                requested_duration_seconds: 300.0,
                actual_duration_seconds: 300.0,
                byte_count: 20_000,
                sha256: "b".repeat(64),
            }
        };
        let full_first = MediaChunkEntry {
            index: 0,
            key: "chunks/job/0.mp3".to_string(),
            requested_start_seconds: 0.0,
            requested_duration_seconds: 300.0,
            actual_duration_seconds: 300.042,
            byte_count: 2_400_339,
            sha256: "a".repeat(64),
        };
        assert!(validate_chunks(
            &[full_first, short_terminal_overlap],
            5 * 1024 * 1024,
            298.5,
            300.0,
            298.0,
        )
        .is_ok());

        let interval = valid_chunk_interval(
            &MediaChunkEntry {
                requested_start_seconds: 298.0,
                requested_duration_seconds: 300.0,
                actual_duration_seconds: 300.042,
                ..MediaChunkEntry {
                    index: 1,
                    key: "chunks/job/1.mp3".to_string(),
                    requested_start_seconds: 0.0,
                    requested_duration_seconds: 300.0,
                    actual_duration_seconds: 300.0,
                    byte_count: 20_000,
                    sha256: "b".repeat(64),
                }
            },
            500.0,
        )
        .expect("valid interval");
        assert_eq!(interval, (298.0, 500.0));
    }

    /// Real manifest numbers from developing_perspective_225.mp3 (VBR,
    /// canonical 885.943 s, 3 chunks; 2026-08-04 short-episode bug). The
    /// container's stream-copied chunks carry no Xing header, so ffprobe's
    /// format.duration was a filesize/bitrate estimate — off by ±10% on VBR
    /// media — and the final chunk's underestimate (281.343 vs 289.954
    /// measured exactly) tripped the coverage gate. The container now
    /// reports exact packet-sum durations; both facts stay pinned here.
    #[test]
    fn dp225_vbr_manifest_regression() {
        let canonical = 885.943;
        let chunk = |index: u32, actual: f64, byte_count: i64| MediaChunkEntry {
            index,
            key: format!("chunks/job/{index}.mp3"),
            requested_start_seconds: f64::from(index) * 298.0,
            requested_duration_seconds: 300.0,
            actual_duration_seconds: actual,
            byte_count,
            sha256: "c".repeat(64),
        };

        let bitrate_estimated = [
            chunk(0, 330.929, 3_259_112),
            chunk(1, 318.791, 3_263_100),
            chunk(2, 281.343, 3_152_871),
        ];
        let rejection =
            validate_chunks(&bitrate_estimated, 5 * 1024 * 1024, canonical, 300.0, 298.0)
                .unwrap_err();
        assert_eq!(rejection.reason, "final_coverage_gap");
        assert_eq!(rejection.code(), crate::types::ERROR_INTERNAL);

        let packet_sum_exact = [
            chunk(0, 300.011, 3_259_112),
            chunk(1, 300.037, 3_263_100),
            chunk(2, 289.954, 3_152_871),
        ];
        assert!(
            validate_chunks(&packet_sum_exact, 5 * 1024 * 1024, canonical, 300.0, 298.0,).is_ok()
        );
    }
}

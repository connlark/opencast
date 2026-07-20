//! Contract with `TranscriptionMediaWorker` (B6): probe then chunk, both POST
//! JSON over the service binding. The media worker only ever receives job ID
//! and object keys; validation decisions stay here.

use serde::{Deserialize, Serialize};

use crate::types::{
    ERROR_DURATION_TOO_LONG, ERROR_SOURCE_TOO_LARGE, ERROR_UNSUPPORTED_MEDIA_TYPE,
};

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
        // chunk_too_large: an oversized stream-copy chunk rejects to local
        // fallback rather than widening the proven AI envelope.
        (413, _) => MediaCallFailure::Fatal(ERROR_UNSUPPORTED_MEDIA_TYPE),
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

pub fn validate_chunks(
    chunks: &[MediaChunkEntry],
    max_chunk_raw_bytes: i64,
) -> Result<(), &'static str> {
    if chunks.is_empty() {
        return Err(ERROR_UNSUPPORTED_MEDIA_TYPE);
    }
    for (position, chunk) in chunks.iter().enumerate() {
        if chunk.index as usize != position
            || chunk.byte_count <= 0
            || chunk.byte_count > max_chunk_raw_bytes
            || !chunk.actual_duration_seconds.is_finite()
            || chunk.actual_duration_seconds <= 0.0
            || chunk.sha256.len() != 64
        {
            return Err(ERROR_UNSUPPORTED_MEDIA_TYPE);
        }
    }
    Ok(())
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
            MediaCallFailure::Fatal(ERROR_UNSUPPORTED_MEDIA_TYPE)
        );
        // Cold starts, missing propagation, stub 501s, 5xx: retryable.
        for status in [404u16, 500, 501, 502, 503] {
            assert_eq!(classify_media_failure(status, None), MediaCallFailure::Retryable);
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
        assert!(validate_chunks(std::slice::from_ref(&entry), 5 * 1024 * 1024).is_ok());
        assert!(validate_chunks(&[], 5 * 1024 * 1024).is_err());

        let mut oversized = entry.clone();
        oversized.byte_count = 6 * 1024 * 1024;
        assert!(validate_chunks(&[oversized], 5 * 1024 * 1024).is_err());

        let mut out_of_order = entry;
        out_of_order.index = 1;
        assert!(validate_chunks(&[out_of_order], 5 * 1024 * 1024).is_err());
    }
}

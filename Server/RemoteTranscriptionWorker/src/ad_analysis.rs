//! Contract with `AdAnalysisWorker`'s internal surface (cloud detect-ads):
//! submit the stitched transcript for server-side ad detection over the
//! service binding, poll the fingerprint-keyed job, and merge the outcome
//! into the result envelope. The crates are not shared, so the wire types
//! here mirror AdAnalysisWorker's snake_case shapes field for field.
//!
//! The ad phase never fails the job: every terminal outcome is either a
//! validated success block or a stable failure marker, and the transcript
//! subtree of the envelope stays byte-identical either way.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::job::{self, JobRecord};

pub const AD_ANALYSIS_BINDING: &str = "AD_ANALYSIS_WORKER";
pub const AD_ANALYSIS_INTERNAL_ORIGIN: &str = "https://opencast-ad-analysis.internal";
pub const AD_ANALYSIS_ANALYZE_PATH: &str = "/internal/v1/analyze";

pub fn ad_analysis_poll_path(ad_job_id: &str) -> String {
    format!("/internal/v1/jobs/{ad_job_id}/poll")
}

// Stable failure-marker codes surfaced in the envelope's `ad_analysis`
// block; the app maps any of them to its automatic device-analysis fallback.
pub const MARKER_CAPACITY: &str = "ad_analysis_capacity";
pub const MARKER_TIMEOUT: &str = "ad_analysis_timeout";
pub const MARKER_FAILED: &str = "ad_analysis_failed";
pub const MARKER_UNAVAILABLE: &str = "ad_analysis_unavailable";

/// Size bound on the serialized success block: far above any plausible span
/// set, far below anything that could bloat the envelope read path.
pub const MAX_AD_BLOCK_BYTES: usize = 256 * 1024;
pub const MAX_SPANS: usize = 64;
/// Mirror of AdAnalysisWorker's segment ceiling: submitting past it would
/// only 400 at `validate_request`, so short-circuit locally.
pub const MAX_SEGMENTS: usize = 6_000;
/// Span timing slack past the canonical duration (model rounding).
pub const SPAN_END_TOLERANCE_SECONDS: f64 = 0.5;
pub const AD_WIRE_SCHEMA_VERSION: u16 = 1;

/// The `AdAnalysisJob` DO key for a transcription job's chained analysis.
/// Deterministic per job so submit retries attach to the running analysis
/// instead of re-running Gemini. Deliberately NOT the device formula
/// (`EpisodeAdAnalysisFileStore.transcriptFingerprint` mixes in the
/// import-time `updatedAt`, which does not exist server-side).
pub fn ad_job_fingerprint(job_id: &str) -> String {
    hex::encode(Sha256::digest(format!("ad-analysis|{job_id}").as_bytes()))
}

// --- Wire mirrors of AdAnalysisWorker's internal analyze contract ---

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WireInternalAnalyzeRequest {
    pub schema_version: u16,
    pub account_id: String,
    /// Diagnostics only on the AdAnalysis side; never keyed on.
    pub transcription_job_id: Option<String>,
    pub request: WireAdAnalysisRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WireAdAnalysisRequest {
    pub schema_version: u16,
    pub async_supported: bool,
    pub request_id: String,
    pub episode_id: String,
    pub podcast_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub podcast_title: Option<String>,
    pub transcript: WireTranscriptMetadata,
    pub segments: Vec<WireTranscriptSegment>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WireTranscriptMetadata {
    pub language_code: String,
    pub audio_duration: f64,
    pub model_identifier: Option<String>,
    pub fingerprint: String,
    pub updated_at: String,
    pub state: String,
    pub segment_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WireTranscriptSegment {
    pub id: i64,
    pub start: f64,
    pub end: f64,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WireAnalysisSuccess {
    pub schema_version: u16,
    pub request_id: String,
    pub model: String,
    pub policy: String,
    pub spans: Vec<WireAdSpan>,
    pub warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<WireGeminiUsage>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WireAdSpan {
    pub kind: String,
    pub label: String,
    pub start_segment_id: i64,
    pub end_segment_id: i64,
    pub start_time: f64,
    pub end_time: f64,
    pub confidence: f64,
    pub evidence_quote: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WireGeminiUsage {
    pub prompt_token_count: u64,
    pub candidates_token_count: u64,
    pub total_token_count: u64,
}

// --- Request construction ---

/// The subset of the stitched result envelope the ad phase reads.
#[derive(Debug, Deserialize)]
struct EnvelopeDocument {
    result: EnvelopeResult,
}

#[derive(Debug, Deserialize)]
struct EnvelopeResult {
    language_code: String,
    segments: Vec<WireTranscriptSegment>,
}

/// Clamp segment ranges the exact way the app's import normalizer
/// (`OpenCastTranscriptSegmentNormalizer`) does: pull each start forward to
/// the previous segment's clamped end, and never let an end precede its own
/// start. The stitcher orders starts but lets a segment's end (its last
/// owned word's end) spill past the next segment's start, which
/// AdAnalysisWorker rejects as `non_monotonic_segments`. Clamping the wire
/// copy — never the fixture-pinned envelope — keeps the analyzed timeline
/// identical to the transcript the app imports, so span ids and times map
/// back exactly.
fn normalize_segment_timings(segments: &mut [WireTranscriptSegment]) {
    let mut previous_end: Option<f64> = None;
    for segment in segments {
        let raw_start = segment.start.max(0.0);
        let raw_end = segment.end.max(raw_start);
        segment.start = previous_end.map_or(raw_start, |end| raw_start.max(end));
        segment.end = raw_end.max(segment.start);
        previous_end = Some(segment.end);
    }
}

/// Build the internal analyze request from the durable record plus the
/// stitched envelope bytes. Words are dropped and overlapping timings are
/// clamped to the app's import normalization; segment ids pass through
/// unchanged so span segment ids map back onto the imported transcript.
/// Failures map to the `ad_analysis_failed` marker.
pub fn build_request(
    record: &JobRecord,
    envelope_bytes: &[u8],
    model: &str,
    now: i64,
) -> Result<WireInternalAnalyzeRequest, &'static str> {
    let envelope: EnvelopeDocument =
        serde_json::from_slice(envelope_bytes).map_err(|_| "envelope_decode")?;
    let podcast_id = record
        .podcast_id
        .clone()
        .filter(|id| !id.is_empty())
        .ok_or("missing_podcast_id")?;
    let audio_duration = record
        .canonical_duration_seconds
        .filter(|duration| duration.is_finite() && *duration > 0.0)
        .ok_or("missing_duration")?;
    if envelope.result.segments.is_empty() || envelope.result.segments.len() > MAX_SEGMENTS {
        return Err("segment_count");
    }
    let mut segments = envelope.result.segments;
    normalize_segment_timings(&mut segments);
    let segment_count = segments.len();
    Ok(WireInternalAnalyzeRequest {
        schema_version: AD_WIRE_SCHEMA_VERSION,
        account_id: record.account_id.clone(),
        transcription_job_id: Some(record.job_id.clone()),
        request: WireAdAnalysisRequest {
            schema_version: AD_WIRE_SCHEMA_VERSION,
            async_supported: true,
            request_id: record.job_id.clone(),
            episode_id: record.episode_id.clone(),
            podcast_id,
            episode_title: record.episode_title.clone(),
            podcast_title: record.podcast_title.clone(),
            transcript: WireTranscriptMetadata {
                language_code: envelope.result.language_code.clone(),
                audio_duration,
                model_identifier: Some(model.to_string()),
                fingerprint: ad_job_fingerprint(&record.job_id),
                updated_at: job::iso8601(now),
                state: "completed".to_string(),
                segment_count,
            },
            segments,
        },
    })
}

// --- Response classification ---

#[derive(Debug, Clone, PartialEq)]
pub enum AnalyzeOutcome {
    /// 200 with a decodable analysis body (submit attach-served or poll).
    Completed(WireAnalysisSuccess),
    /// 202: the fingerprint-keyed job is running (fresh or attached).
    Running,
    /// 429: a spend cap; terminal for this job (capacity marker).
    Capacity,
    /// Contract rejection (4xx) or an undecodable success body: terminal
    /// failure marker, never a retry.
    Rejected,
    /// 404 on poll: the internal record was purged; clear the job id and
    /// resubmit (bounded by the submit-attempt cap).
    NotFound,
    /// Transport errors and 5xx: retry on the alarm loop until the phase
    /// deadline or the attempt cap ends the wait.
    Retryable,
}

pub fn classify_analyze_response(status: u16, body: &[u8]) -> AnalyzeOutcome {
    match status {
        200 => match serde_json::from_slice::<WireAnalysisSuccess>(body) {
            Ok(success) => AnalyzeOutcome::Completed(success),
            Err(_) => AnalyzeOutcome::Rejected,
        },
        202 => AnalyzeOutcome::Running,
        404 => AnalyzeOutcome::NotFound,
        429 => AnalyzeOutcome::Capacity,
        400..=499 => AnalyzeOutcome::Rejected,
        _ => AnalyzeOutcome::Retryable,
    }
}

// --- Result validation and envelope blocks ---

/// Validate a completed analysis against the envelope it analyzed: bounded
/// span count, finite timings inside the transcript, segment ids that exist,
/// clamped confidence, bounded serialized size. Anything invalid becomes the
/// `ad_analysis_failed` marker — never a malformed block in the envelope.
pub fn validate_analysis(
    success: &mut WireAnalysisSuccess,
    envelope_bytes: &[u8],
    canonical_duration_seconds: f64,
) -> Result<(), &'static str> {
    let envelope: EnvelopeDocument =
        serde_json::from_slice(envelope_bytes).map_err(|_| "envelope_decode")?;
    if success.spans.len() > MAX_SPANS {
        return Err("too_many_spans");
    }
    let segment_ids: std::collections::BTreeSet<i64> = envelope
        .result
        .segments
        .iter()
        .map(|segment| segment.id)
        .collect();
    let max_end = canonical_duration_seconds + SPAN_END_TOLERANCE_SECONDS;
    for span in &mut success.spans {
        if !span.start_time.is_finite()
            || !span.end_time.is_finite()
            || span.start_time < 0.0
            || span.end_time <= span.start_time
            || span.end_time > max_end
        {
            return Err("span_timing");
        }
        if span.start_segment_id > span.end_segment_id
            || !segment_ids.contains(&span.start_segment_id)
            || !segment_ids.contains(&span.end_segment_id)
        {
            return Err("span_segment_ids");
        }
        if !span.confidence.is_finite() {
            return Err("span_confidence");
        }
        span.confidence = span.confidence.clamp(0.0, 1.0);
    }
    let serialized = serde_json::to_vec(&success).map_err(|_| "block_serialize")?;
    if serialized.len() > MAX_AD_BLOCK_BYTES {
        return Err("block_too_large");
    }
    Ok(())
}

pub fn success_block(success: &WireAnalysisSuccess) -> Result<serde_json::Value, &'static str> {
    let mut value = serde_json::to_value(success).map_err(|_| "block_serialize")?;
    let object = value.as_object_mut().ok_or("block_serialize")?;
    object.insert(
        "state".to_string(),
        serde_json::Value::String("completed".to_string()),
    );
    Ok(value)
}

pub fn failure_block(error_code: &str) -> serde_json::Value {
    serde_json::json!({
        "state": "failed",
        "error_code": error_code,
    })
}

/// Insert the top-level `ad_analysis` key into the stored envelope.
/// Idempotent: an envelope that already carries the key returns `None`.
/// serde_json's sorted maps plus `float_roundtrip` keep the `result`
/// subtree byte-identical through the parse → insert → serialize cycle.
pub fn inject_ad_analysis(
    envelope_bytes: &[u8],
    block: &serde_json::Value,
) -> Result<Option<Vec<u8>>, &'static str> {
    let mut envelope: serde_json::Value =
        serde_json::from_slice(envelope_bytes).map_err(|_| "envelope_decode")?;
    let object = envelope.as_object_mut().ok_or("envelope_decode")?;
    if object.contains_key("ad_analysis") {
        return Ok(None);
    }
    object.insert("ad_analysis".to_string(), block.clone());
    serde_json::to_vec(&envelope)
        .map(Some)
        .map_err(|_| "envelope_serialize")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record() -> JobRecord {
        let mut record = JobRecord::created(
            "job-ad-1".into(),
            "acct-1".into(),
            "ep-1".into(),
            Some("en".into()),
            Some(2040.0),
            None,
            None,
            1_784_000_000,
        );
        record.ad_analysis_requested = true;
        record.podcast_id = Some("https://example.com/feed.xml".into());
        record.episode_title = Some("Episode 42".into());
        record.podcast_title = Some("The Example Show".into());
        record.canonical_duration_seconds = Some(2040.0);
        record
    }

    fn envelope() -> serde_json::Value {
        serde_json::json!({
            "schema_version": 1,
            "result": {
                "schema_version": 1,
                "source_identity": {
                    "sha256": "da26a00f",
                    "byte_count": 16_328_368,
                    "duration_seconds": 2040.0,
                },
                "language_code": "en",
                "duration_seconds": 2040.0,
                "text": "hello world again",
                "segments": [
                    {
                        "id": 0,
                        "start": 0.0,
                        "end": 2.5,
                        "text": "hello world",
                        "words": [
                            { "start": 0.1, "end": 0.9, "text": "hello" },
                            { "start": 1.0, "end": 2.4, "text": "world" },
                        ],
                    },
                    { "id": 1, "start": 2.5, "end": 5.041, "text": "again", "words": [] },
                ],
                "provenance": {
                    "provider": "cloudflare-workers-ai",
                    "model_identifier": "@cf/openai/whisper-large-v3-turbo",
                    "serving_contract_version": "1",
                    "request_settings_sha256": "aa",
                    "chunk_manifest_sha256": "bb",
                    "chunk_audio_profile": "mp3-stream-copy-v1",
                    "normalized_transcript_sha256": "cc",
                    "pipeline_version": "pass0",
                    "source_match_mode": "server_device_hash_match",
                },
                "warnings": [],
            },
        })
    }

    fn success() -> WireAnalysisSuccess {
        WireAnalysisSuccess {
            schema_version: 1,
            request_id: "job-ad-1".into(),
            model: "gemini-3.5-flash".into(),
            policy: "promo_ad_breaks_v2".into(),
            spans: vec![WireAdSpan {
                kind: "host_read_ad".into(),
                label: "Sponsor".into(),
                start_segment_id: 0,
                end_segment_id: 1,
                start_time: 0.0,
                end_time: 5.0,
                confidence: 0.9,
                evidence_quote: "brought to you by".into(),
            }],
            warnings: vec![],
            usage: None,
        }
    }

    #[test]
    fn fingerprint_is_deterministic_hex_and_job_scoped() {
        let fingerprint = ad_job_fingerprint("job-ad-1");
        assert_eq!(fingerprint.len(), 64);
        assert!(fingerprint.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_eq!(fingerprint, ad_job_fingerprint("job-ad-1"));
        assert_ne!(fingerprint, ad_job_fingerprint("job-ad-2"));
    }

    #[test]
    fn build_request_maps_record_and_envelope() {
        let bytes = serde_json::to_vec(&envelope()).expect("serialize");
        let request = build_request(&record(), &bytes, "@cf/openai/whisper-large-v3-turbo", 1_784_000_100)
            .expect("build");
        assert_eq!(request.schema_version, 1);
        assert_eq!(request.account_id, "acct-1");
        assert_eq!(request.transcription_job_id.as_deref(), Some("job-ad-1"));
        let inner = &request.request;
        assert!(inner.async_supported);
        assert_eq!(inner.request_id, "job-ad-1");
        assert_eq!(inner.episode_id, "ep-1");
        assert_eq!(inner.podcast_id, "https://example.com/feed.xml");
        assert_eq!(inner.episode_title.as_deref(), Some("Episode 42"));
        assert_eq!(inner.transcript.language_code, "en");
        assert_eq!(inner.transcript.audio_duration, 2040.0);
        assert_eq!(inner.transcript.fingerprint, ad_job_fingerprint("job-ad-1"));
        assert_eq!(inner.transcript.state, "completed");
        assert_eq!(inner.transcript.segment_count, 2);
        assert_eq!(inner.segments.len(), 2);
        assert_eq!(inner.segments[1].id, 1);
        assert_eq!(inner.segments[1].text, "again");
        // Words are dropped from the wire shape entirely.
        let serialized = serde_json::to_string(&request).expect("serialize");
        assert!(!serialized.contains("\"words\""));
    }

    #[test]
    fn build_request_clamps_overlapping_segment_ranges() {
        // Real stitch-v3 shape (job-j7wsXCwsrYBAWc1hqmeWMw): starts ordered,
        // but a segment's end spills past the next segment's start. The wire
        // copy must clamp exactly like the app's import normalizer so the
        // AdAnalysis validator (`start + 0.001 < previous_end` rejects)
        // accepts it and span ids/times map onto the imported transcript.
        let mut envelope = envelope();
        envelope["result"]["segments"] = serde_json::json!([
            { "id": 0, "start": 0.0, "end": 5.2, "text": "hello", "words": [] },
            { "id": 1, "start": 4.8, "end": 9.0, "text": "world", "words": [] },
            // Fully swallowed by the previous clamped end.
            { "id": 2, "start": 8.5, "end": 8.9, "text": "again", "words": [] },
            { "id": 3, "start": 9.4, "end": 11.0, "text": "tail", "words": [] },
        ]);
        let bytes = serde_json::to_vec(&envelope).expect("serialize");
        let request =
            build_request(&record(), &bytes, "m", 1_784_000_100).expect("build");

        let clamped: Vec<(i64, f64, f64)> = request
            .request
            .segments
            .iter()
            .map(|segment| (segment.id, segment.start, segment.end))
            .collect();
        assert_eq!(
            clamped,
            vec![
                (0, 0.0, 5.2),
                (1, 5.2, 9.0),
                (2, 9.0, 9.0),
                (3, 9.4, 11.0),
            ]
        );
        let mut previous_end = f64::NEG_INFINITY;
        for segment in &request.request.segments {
            assert!(segment.start + 0.001 >= previous_end);
            assert!(segment.end >= segment.start);
            previous_end = segment.end;
        }
    }

    #[test]
    fn build_request_keeps_monotonic_segments_untouched() {
        let bytes = serde_json::to_vec(&envelope()).expect("serialize");
        let request = build_request(&record(), &bytes, "m", 1_784_000_100).expect("build");
        let timings: Vec<(f64, f64)> = request
            .request
            .segments
            .iter()
            .map(|segment| (segment.start, segment.end))
            .collect();
        assert_eq!(timings, vec![(0.0, 2.5), (2.5, 5.041)]);
    }

    #[test]
    fn build_request_requires_podcast_id_and_duration() {
        let bytes = serde_json::to_vec(&envelope()).expect("serialize");
        let mut missing_podcast = record();
        missing_podcast.podcast_id = None;
        assert!(build_request(&missing_podcast, &bytes, "m", 0).is_err());

        let mut missing_duration = record();
        missing_duration.canonical_duration_seconds = None;
        assert!(build_request(&missing_duration, &bytes, "m", 0).is_err());
    }

    #[test]
    fn classification_matrix() {
        let success_body = serde_json::to_vec(&success()).expect("serialize");
        assert!(matches!(
            classify_analyze_response(200, &success_body),
            AnalyzeOutcome::Completed(_)
        ));
        // A 200 with an undecodable body is a rejection, never a block.
        assert_eq!(
            classify_analyze_response(200, b"not json"),
            AnalyzeOutcome::Rejected
        );
        assert_eq!(classify_analyze_response(202, b"{}"), AnalyzeOutcome::Running);
        assert_eq!(classify_analyze_response(404, b"{}"), AnalyzeOutcome::NotFound);
        assert_eq!(classify_analyze_response(429, b"{}"), AnalyzeOutcome::Capacity);
        for status in [400u16, 401, 403, 411, 413, 422] {
            assert_eq!(classify_analyze_response(status, b"{}"), AnalyzeOutcome::Rejected);
        }
        for status in [500u16, 502, 503] {
            assert_eq!(classify_analyze_response(status, b"{}"), AnalyzeOutcome::Retryable);
        }
    }

    #[test]
    fn validation_bounds_spans_and_clamps_confidence() {
        let bytes = serde_json::to_vec(&envelope()).expect("serialize");

        let mut valid = success();
        valid.spans[0].confidence = 1.4;
        assert!(validate_analysis(&mut valid, &bytes, 2040.0).is_ok());
        assert_eq!(valid.spans[0].confidence, 1.0);

        let mut bad_ids = success();
        bad_ids.spans[0].end_segment_id = 7;
        assert!(validate_analysis(&mut bad_ids, &bytes, 2040.0).is_err());

        let mut reversed = success();
        reversed.spans[0].end_time = reversed.spans[0].start_time;
        assert!(validate_analysis(&mut reversed, &bytes, 2040.0).is_err());

        let mut past_end = success();
        past_end.spans[0].end_time = 2041.0;
        assert!(validate_analysis(&mut past_end, &bytes, 2040.0).is_err());
        past_end.spans[0].end_time = 2040.4;
        assert!(validate_analysis(&mut past_end, &bytes, 2040.0).is_ok());

        let mut too_many = success();
        too_many.spans = vec![success().spans[0].clone(); MAX_SPANS + 1];
        assert!(validate_analysis(&mut too_many, &bytes, 2040.0).is_err());

        let mut oversized = success();
        oversized.spans[0].evidence_quote = "x".repeat(MAX_AD_BLOCK_BYTES + 1);
        assert!(validate_analysis(&mut oversized, &bytes, 2040.0).is_err());
    }

    #[test]
    fn blocks_carry_the_state_discriminator() {
        let block = success_block(&success()).expect("block");
        assert_eq!(block["state"], "completed");
        assert_eq!(block["policy"], "promo_ad_breaks_v2");
        assert_eq!(block["spans"][0]["kind"], "host_read_ad");

        let marker = failure_block(MARKER_CAPACITY);
        assert_eq!(marker["state"], "failed");
        assert_eq!(marker["error_code"], "ad_analysis_capacity");
    }

    #[test]
    fn injection_is_idempotent_and_keeps_the_result_subtree_byte_identical() {
        let before = serde_json::to_vec(&envelope()).expect("serialize");
        let block = failure_block(MARKER_TIMEOUT);
        let after = inject_ad_analysis(&before, &block)
            .expect("inject")
            .expect("first injection writes");

        // Idempotent: a second injection is a no-op.
        assert_eq!(inject_ad_analysis(&after, &block).expect("inject"), None);

        // Removing the injected key reproduces the original bytes exactly —
        // the sorted-map + float_roundtrip pin that keeps `result` stable.
        let mut reparsed: serde_json::Value =
            serde_json::from_slice(&after).expect("decode");
        reparsed
            .as_object_mut()
            .expect("object")
            .remove("ad_analysis")
            .expect("key present");
        assert_eq!(serde_json::to_vec(&reparsed).expect("serialize"), before);

        // And the block itself decodes back out.
        let decoded: serde_json::Value = serde_json::from_slice(&after).expect("decode");
        assert_eq!(decoded["ad_analysis"]["state"], "failed");
        assert_eq!(decoded["ad_analysis"]["error_code"], MARKER_TIMEOUT);
    }
}

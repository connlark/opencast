//! Pure job state machine pieces: persisted record shape, state vocabulary,
//! deadlines, identity matching, and the retry-audio ceiling. Everything here
//! is host-testable; the Durable Object in `job_do.rs` executes it.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::types::SourceIdentity;

pub const JOB_BINDING: &str = "TRANSCRIPTION_JOB";

pub const STATE_CREATED: &str = "created";
pub const STATE_STAGING_ORIGIN: &str = "staging_origin";
pub const STATE_WAITING_FOR_DEVICE_SOURCE: &str = "waiting_for_device_source";
pub const STATE_SOURCE_MATCHED: &str = "source_matched";
pub const STATE_EXACT_UPLOAD_REQUIRED: &str = "exact_upload_required";
pub const STATE_EXACT_UPLOADING: &str = "exact_uploading";
pub const STATE_PROBING: &str = "probing";
pub const STATE_AWAITING_CREDITS: &str = "awaiting_credits";
pub const STATE_RESERVED: &str = "reserved";
pub const STATE_CHUNKING: &str = "chunking";
pub const STATE_TRANSCRIBING: &str = "transcribing";
pub const STATE_STITCHING: &str = "stitching";
pub const STATE_RESULT_READY: &str = "result_ready";
pub const STATE_DELIVERED: &str = "delivered";
pub const STATE_ACKNOWLEDGED: &str = "acknowledged";
pub const STATE_CANCELLING: &str = "cancelling";
pub const STATE_CANCELLED: &str = "cancelled";
pub const STATE_FAILED: &str = "failed";

pub const CHUNK_SECONDS: f64 = 300.0;
pub const OVERLAP_SECONDS: f64 = 2.0;
pub const STEP_SECONDS: f64 = 298.0;
pub const MAX_CHUNK_RAW_BYTES: i64 = 5 * 1024 * 1024;

/// Bounded presigned-URL batches (pass 2 decision 3).
pub const UPLOAD_MAX_PARTS_PER_BATCH: usize = 8;
/// R2's S3 surface caps multipart uploads at 10,000 parts; the 512 MiB cap
/// with 16 MiB parts stays ≤ 32, so anything past u16 is malformed.
pub const UPLOAD_MAX_PART_COUNT: i64 = 10_000;

/// Uniform-part geometry for the exact-device upload (pass 2 decision 4):
/// every non-final part is exactly `part_bytes`; the final part is the
/// remainder. Returns None when the byte count can't form a valid upload.
pub fn upload_part_count(byte_count: i64, part_bytes: i64) -> Option<u16> {
    if byte_count <= 0 || part_bytes <= 0 {
        return None;
    }
    let count = (byte_count + part_bytes - 1) / part_bytes;
    if count > UPLOAD_MAX_PART_COUNT {
        return None;
    }
    u16::try_from(count).ok()
}

/// Exact byte range of one 1-based part under the uniform geometry.
pub fn upload_part_range(
    byte_count: i64,
    part_bytes: i64,
    part_number: u16,
) -> Option<(i64, i64)> {
    let count = upload_part_count(byte_count, part_bytes)?;
    if part_number == 0 || part_number > count {
        return None;
    }
    let start = (i64::from(part_number) - 1) * part_bytes;
    let end = (start + part_bytes).min(byte_count);
    Some((start, end))
}

pub fn is_terminal(state: &str) -> bool {
    matches!(state, STATE_ACKNOWLEDGED | STATE_CANCELLED | STATE_FAILED)
}

pub fn is_cancellable(state: &str) -> bool {
    !is_terminal(state) && state != STATE_CANCELLING
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChunkRef {
    pub index: u32,
    pub key: String,
    pub requested_start_seconds: f64,
    pub actual_duration_seconds: f64,
    pub byte_count: i64,
    pub sha256: String,
}

/// Per-chunk fan-out state (pass 0.5): scheduling truth for the bounded wave
/// driver plus content-free AI timing telemetry (indices and epoch seconds
/// only). Pass-0 records carry none of this; `init_chunk_work` migrates
/// their `next_chunk_index` walk position.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChunkWork {
    pub index: u32,
    #[serde(default)]
    pub completed: bool,
    /// Failed AI attempts so far; a success never increments this.
    #[serde(default)]
    pub failed_attempts: u32,
    /// First AI attempt start / successful attempt end, epoch seconds.
    #[serde(default)]
    pub ai_started_at: Option<i64>,
    #[serde(default)]
    pub ai_ended_at: Option<i64>,
    /// Per-chunk retry backoff: the chunk sits out waves until this passes,
    /// without blocking its siblings.
    #[serde(default)]
    pub retry_not_before: Option<i64>,
}

/// Overlap-driver selection (pass 0.5 lever 2): chunks the container has
/// already written to R2, minus everything excluded (completed, in flight,
/// or already attempted this turn), capacity-capped and budgeted against the
/// retry-audio ceiling at the requested chunk duration — actual durations
/// arrive only with the final manifest, so the estimate is conservative.
pub fn select_overlap(
    discovered: &std::collections::BTreeSet<u32>,
    excluded: &std::collections::BTreeSet<u32>,
    capacity: u32,
    budgeted_audio_seconds: f64,
    ceiling_seconds: f64,
) -> Vec<u32> {
    let mut issue = Vec::new();
    let mut budgeted = budgeted_audio_seconds;
    for &index in discovered {
        if issue.len() as u32 >= capacity {
            break;
        }
        if excluded.contains(&index) {
            continue;
        }
        if budgeted + CHUNK_SECONDS > ceiling_seconds {
            break;
        }
        budgeted += CHUNK_SECONDS;
        issue.push(index);
    }
    issue
}

/// Fresh per-chunk work state; indices below `completed_below` are marked
/// done so an in-flight pass-0 record (sequential `next_chunk_index` walk)
/// resumes exactly where it stopped.
pub fn init_chunk_work(chunk_count: u32, completed_below: u32) -> Vec<ChunkWork> {
    (0..chunk_count)
        .map(|index| ChunkWork {
            index,
            completed: index < completed_below,
            failed_attempts: 0,
            ai_started_at: None,
            ai_ended_at: None,
            retry_not_before: None,
        })
        .collect()
}

/// What the wave driver should do this alarm turn.
#[derive(Debug, Clone, PartialEq)]
pub enum WaveSelection {
    /// Every chunk is transcribed; move to stitching.
    Complete,
    /// Issue these chunk indices now (lowest first, at most `concurrency`).
    Issue(Vec<u32>),
    /// All pending chunks are backing off; re-run the alarm at this time.
    WaitUntil(i64),
    /// The next runnable chunk cannot fit under the retry-audio ceiling:
    /// the service-spend cap ends the job (never a customer charge).
    ExceedsRetryCeiling,
}

/// Pure wave selection (A2): pick up to `concurrency` pending chunks whose
/// backoff has elapsed, budgeting `requested_audio_seconds` plus everything
/// issued in this wave against the retry-audio ceiling. `concurrency` 1
/// reproduces the pass-0 sequential walk: lowest pending index, one at a
/// time, identical ceiling arithmetic.
pub fn select_wave(
    chunk_work: &[ChunkWork],
    chunk_durations: &[f64],
    concurrency: u32,
    requested_audio_seconds: f64,
    ceiling_seconds: f64,
    now: i64,
) -> WaveSelection {
    let pending: Vec<&ChunkWork> = chunk_work.iter().filter(|work| !work.completed).collect();
    if pending.is_empty() {
        return WaveSelection::Complete;
    }
    let runnable: Vec<&ChunkWork> = pending
        .iter()
        .copied()
        .filter(|work| work.retry_not_before.is_none_or(|at| at <= now))
        .collect();
    if runnable.is_empty() {
        let earliest = pending
            .iter()
            .filter_map(|work| work.retry_not_before)
            .min()
            .unwrap_or(now);
        return WaveSelection::WaitUntil(earliest);
    }

    let mut issue = Vec::new();
    let mut budgeted = requested_audio_seconds;
    for work in runnable {
        if issue.len() as u32 >= concurrency.max(1) {
            break;
        }
        let duration = chunk_durations
            .get(work.index as usize)
            .copied()
            .unwrap_or_default();
        if budgeted + duration > ceiling_seconds {
            // Same rule as the pass-0 walk: the chunk that would cross the
            // ceiling is never issued. If it is the first runnable chunk the
            // job cannot finish; otherwise the trimmed wave runs and the next
            // turn re-evaluates with real (not estimated) spend.
            if issue.is_empty() {
                return WaveSelection::ExceedsRetryCeiling;
            }
            break;
        }
        budgeted += duration;
        issue.push(work.index);
    }
    WaveSelection::Issue(issue)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobRecord {
    pub job_id: String,
    pub account_id: String,
    pub episode_id: String,
    pub state: String,
    pub created_at: i64,
    pub updated_at: i64,
    #[serde(default)]
    pub language_code: Option<String>,
    #[serde(default)]
    pub declared_duration_seconds: Option<f64>,
    /// AES-GCM ciphertext (base64 nonce||ct) of the enclosure URL; cleared as
    /// soon as backend staging finishes. Only the keyed URL hash survives in
    /// diagnostics.
    #[serde(default)]
    pub enclosure_url_ciphertext: Option<String>,
    #[serde(default)]
    pub device_identity: Option<SourceIdentity>,
    #[serde(default)]
    pub server_sha256: Option<String>,
    #[serde(default)]
    pub server_byte_count: Option<i64>,
    #[serde(default)]
    pub canonical_duration_seconds: Option<f64>,
    #[serde(default)]
    pub reserved_seconds: Option<i64>,
    #[serde(default)]
    pub chunks: Vec<ChunkRef>,
    #[serde(default)]
    pub chunk_manifest_sha256: Option<String>,
    /// Pass-0 walk position, kept as a completed-count mirror so old records
    /// decode and old readers stay coherent; `chunk_work` is the pass-0.5
    /// scheduling truth.
    #[serde(default)]
    pub next_chunk_index: u32,
    /// Pass-0 per-current-chunk retry counter; superseded by
    /// `chunk_work[i].failed_attempts` but kept for record compatibility.
    #[serde(default)]
    pub current_chunk_attempts: u32,
    #[serde(default)]
    pub chunk_work: Vec<ChunkWork>,
    /// Content-free phase telemetry (pass 0.5 decision 4): first entry into
    /// each state, epoch seconds. Never URLs, titles, hashes, or text.
    #[serde(default)]
    pub phase_timestamps: BTreeMap<String, i64>,
    /// Retryable media-worker attempts (probe or chunk) for the current step;
    /// covers container cold starts without burning the job.
    #[serde(default)]
    pub media_attempts: u32,
    /// Audio seconds requested from the model so far, including retries; the
    /// per-job ceiling caps service spend without ever charging the customer.
    #[serde(default)]
    pub requested_audio_seconds: f64,
    /// Last durable queue snapshot returned by the global limiter. Polling
    /// only reads these fields; one denied alarm turn writes them together.
    #[serde(default)]
    pub queued_since: Option<i64>,
    #[serde(default)]
    pub queue_position: Option<u32>,
    #[serde(default)]
    pub queue_wait_seconds: Option<u32>,
    #[serde(default)]
    pub result_key: Option<String>,
    #[serde(default)]
    pub normalized_transcript_sha256: Option<String>,
    #[serde(default)]
    pub error_code: Option<String>,
    #[serde(default)]
    pub error_message: Option<String>,
    #[serde(default)]
    pub state_deadline_at: Option<i64>,
    #[serde(default)]
    pub cleanup_complete: bool,
    /// Create-time policy rejection of the enclosure URL (http, userinfo,
    /// IP-literal, unusual port, forbidden host): the server never fetches;
    /// the job goes straight to the exact-device upload path (pass 2
    /// decision 1).
    #[serde(default)]
    pub origin_unsafe: bool,
    /// R2 multipart upload id for `uploads/<job>/source`; present from
    /// upload/start until complete/abort.
    #[serde(default)]
    pub upload_id: Option<String>,
    #[serde(default)]
    pub upload_part_size_bytes: Option<i64>,
    #[serde(default)]
    pub upload_part_count: Option<u16>,
    /// The multipart complete succeeded and the object is awaiting (or has
    /// passed) identity re-verification; the probe/chunk pipeline reads the
    /// `uploads/` key instead of `raw/`.
    #[serde(default)]
    pub upload_completed: bool,
}

impl JobRecord {
    #[allow(clippy::too_many_arguments)]
    pub fn created(
        job_id: String,
        account_id: String,
        episode_id: String,
        language_code: Option<String>,
        declared_duration_seconds: Option<f64>,
        enclosure_url_ciphertext: Option<String>,
        device_identity: Option<SourceIdentity>,
        now: i64,
    ) -> Self {
        Self {
            job_id,
            account_id,
            episode_id,
            state: STATE_CREATED.to_string(),
            created_at: now,
            updated_at: now,
            language_code,
            declared_duration_seconds,
            enclosure_url_ciphertext,
            device_identity,
            server_sha256: None,
            server_byte_count: None,
            canonical_duration_seconds: None,
            reserved_seconds: None,
            chunks: Vec::new(),
            chunk_manifest_sha256: None,
            next_chunk_index: 0,
            current_chunk_attempts: 0,
            chunk_work: Vec::new(),
            phase_timestamps: BTreeMap::from([(STATE_CREATED.to_string(), now)]),
            media_attempts: 0,
            requested_audio_seconds: 0.0,
            queued_since: None,
            queue_position: None,
            queue_wait_seconds: None,
            result_key: None,
            normalized_transcript_sha256: None,
            error_code: None,
            error_message: None,
            state_deadline_at: None,
            cleanup_complete: false,
            origin_unsafe: false,
            upload_id: None,
            upload_part_size_bytes: None,
            upload_part_count: None,
            upload_completed: false,
        }
    }

    /// Where the verified source bytes live: the exact-device upload key once
    /// a completed upload owns the job's source, the staged raw key otherwise.
    pub fn source_object_key(&self) -> String {
        if self.upload_completed {
            r2_upload_key(&self.job_id)
        } else {
            r2_raw_key(&self.job_id)
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentityComparison {
    Waiting,
    Matched,
    Mismatched,
}

/// Exact-byte rule: equal SHA-256 and equal byte count, nothing less. Headers
/// never substitute for the hash.
pub fn compare_identities(
    device: Option<&SourceIdentity>,
    server_sha256: Option<&str>,
    server_byte_count: Option<i64>,
) -> IdentityComparison {
    let (Some(device), Some(server_sha256), Some(server_byte_count)) =
        (device, server_sha256, server_byte_count)
    else {
        return IdentityComparison::Waiting;
    };
    if device.sha256.eq_ignore_ascii_case(server_sha256) && device.byte_count == server_byte_count
    {
        IdentityComparison::Matched
    } else {
        IdentityComparison::Mismatched
    }
}

/// Billing unit: exact canonical duration rounded up to the next whole second.
pub fn reserved_seconds_for_duration(canonical_duration_seconds: f64) -> Option<i64> {
    if !canonical_duration_seconds.is_finite() || canonical_duration_seconds <= 0.0 {
        return None;
    }
    Some(canonical_duration_seconds.ceil() as i64)
}

/// Per-job requested-audio ceiling including retries:
/// `max(1.20 × canonical, canonical + 2 × chunk duration)` plus the planned
/// overlap baseline. The floor exists because one fully retried chunk on a
/// short episode legitimately exceeds a bare 1.20 multiplier.
pub fn retry_audio_ceiling_seconds(canonical_duration_seconds: f64, chunk_count: u32) -> f64 {
    let overlap_baseline = OVERLAP_SECONDS * chunk_count.saturating_sub(1) as f64;
    (1.20 * canonical_duration_seconds)
        .max(canonical_duration_seconds + 2.0 * CHUNK_SECONDS)
        + overlap_baseline
}

/// Per-state deadline in seconds, if the state has one (parent plan decision:
/// every waiting state drives normal cancellation on expiry). The two upload
/// states carry their own deadlines (pass 2 decision 2) and take them from
/// config at the transition site.
pub fn state_deadline_seconds(
    state: &str,
    staging_origin_deadline: i64,
    waiting_for_device_source_deadline: i64,
    awaiting_credits_deadline: i64,
) -> Option<i64> {
    match state {
        STATE_CREATED | STATE_STAGING_ORIGIN => Some(staging_origin_deadline),
        STATE_WAITING_FOR_DEVICE_SOURCE => Some(waiting_for_device_source_deadline),
        STATE_AWAITING_CREDITS => Some(awaiting_credits_deadline),
        _ => None,
    }
}

/// Minimal UTC epoch-to-ISO8601 (no external time dependency); Howard
/// Hinnant's civil_from_days.
pub fn iso8601(epoch_seconds: i64) -> String {
    let days = epoch_seconds.div_euclid(86_400);
    let secs = epoch_seconds.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60
    )
}

pub fn r2_raw_key(job_id: &str) -> String {
    format!("raw/{job_id}/source")
}

pub fn r2_upload_key(job_id: &str) -> String {
    format!("uploads/{job_id}/source")
}

pub fn r2_chunk_prefix(job_id: &str) -> String {
    format!("chunks/{job_id}/")
}

pub fn r2_response_key(job_id: &str, index: u32) -> String {
    format!("responses/{job_id}/{index}.json")
}

pub fn r2_response_prefix(job_id: &str) -> String {
    format!("responses/{job_id}/")
}

pub fn r2_result_key(job_id: &str) -> String {
    format!("results/{job_id}/transcript.json")
}

pub fn job_prefixes(job_id: &str) -> [String; 4] {
    [
        format!("raw/{job_id}/"),
        format!("uploads/{job_id}/"),
        r2_chunk_prefix(job_id),
        r2_response_prefix(job_id),
    ]
}

/// R2 rejects a multipart `complete` unless every non-final part is
/// byte-identical in size, so parts must be sliced to exactly `part_bytes`
/// — flushing the buffer at whatever size the stream crossed the threshold
/// passes `upload_part` but fails `complete` once there are 3+ parts.
pub fn take_full_part(buffer: &mut Vec<u8>, part_bytes: usize) -> Option<Vec<u8>> {
    if buffer.len() < part_bytes {
        return None;
    }
    let rest = buffer.split_off(part_bytes);
    Some(std::mem::replace(buffer, rest))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(sha256: &str, byte_count: i64) -> SourceIdentity {
        SourceIdentity {
            sha256: sha256.to_string(),
            byte_count,
            duration_seconds: None,
            entity_tag: None,
            last_modified: None,
            final_url_sha256: None,
        }
    }

    #[test]
    fn identity_comparison_requires_both_sides() {
        assert_eq!(
            compare_identities(None, Some("aa"), Some(10)),
            IdentityComparison::Waiting
        );
        assert_eq!(
            compare_identities(Some(&identity("aa", 10)), None, None),
            IdentityComparison::Waiting
        );
        assert_eq!(
            compare_identities(Some(&identity("aa", 10)), Some("AA"), Some(10)),
            IdentityComparison::Matched
        );
        assert_eq!(
            compare_identities(Some(&identity("aa", 10)), Some("aa"), Some(11)),
            IdentityComparison::Mismatched
        );
        assert_eq!(
            compare_identities(Some(&identity("aa", 10)), Some("bb"), Some(10)),
            IdentityComparison::Mismatched
        );
    }

    #[test]
    fn reserved_seconds_round_up() {
        assert_eq!(reserved_seconds_for_duration(2040.0), Some(2040));
        assert_eq!(reserved_seconds_for_duration(2039.001), Some(2040));
        assert_eq!(reserved_seconds_for_duration(0.5), Some(1));
        assert_eq!(reserved_seconds_for_duration(0.0), None);
        assert_eq!(reserved_seconds_for_duration(f64::NAN), None);
    }

    #[test]
    fn retry_ceiling_uses_floor_for_short_episodes() {
        // Short episode: floor dominates (canonical + 2 chunks).
        let short = retry_audio_ceiling_seconds(400.0, 2);
        assert!((short - (400.0 + 600.0 + 2.0)).abs() < 1e-9);
        // Long episode: 1.2x dominates.
        let long = retry_audio_ceiling_seconds(12_000.0, 41);
        assert!((long - (14_400.0 + 80.0)).abs() < 1e-9);
    }

    #[test]
    fn deadlines_only_for_waiting_states() {
        assert_eq!(state_deadline_seconds(STATE_STAGING_ORIGIN, 1, 2, 3), Some(1));
        assert_eq!(
            state_deadline_seconds(STATE_WAITING_FOR_DEVICE_SOURCE, 1, 2, 3),
            Some(2)
        );
        assert_eq!(state_deadline_seconds(STATE_AWAITING_CREDITS, 1, 2, 3), Some(3));
        assert_eq!(state_deadline_seconds(STATE_TRANSCRIBING, 1, 2, 3), None);
        assert_eq!(state_deadline_seconds(STATE_RESULT_READY, 1, 2, 3), None);
    }

    #[test]
    fn terminal_states() {
        for state in [STATE_ACKNOWLEDGED, STATE_CANCELLED, STATE_FAILED] {
            assert!(is_terminal(state));
            assert!(!is_cancellable(state));
        }
        assert!(!is_terminal(STATE_TRANSCRIBING));
        assert!(is_cancellable(STATE_TRANSCRIBING));
        assert!(!is_cancellable(STATE_CANCELLING));
    }

    #[test]
    fn record_roundtrips_serde_with_defaults() {
        let record = JobRecord::created(
            "job-1".into(),
            "acct-1".into(),
            "ep-1".into(),
            Some("en".into()),
            Some(2040.0),
            None,
            None,
            1_784_000_000,
        );
        let json = serde_json::to_string(&record).expect("serialize");
        let decoded: JobRecord = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded.state, STATE_CREATED);
        assert_eq!(decoded.next_chunk_index, 0);
        assert!(!decoded.cleanup_complete);

        // Older records without new fields still decode.
        let minimal = serde_json::json!({
            "job_id": "job-2",
            "account_id": "acct-1",
            "episode_id": "ep-2",
            "state": "created",
            "created_at": 1,
            "updated_at": 1,
        });
        let decoded: JobRecord = serde_json::from_value(minimal).expect("decode minimal");
        assert_eq!(decoded.chunks.len(), 0);
    }

    #[test]
    fn init_chunk_work_migrates_pass0_walk_position() {
        let fresh = init_chunk_work(3, 0);
        assert_eq!(fresh.len(), 3);
        assert!(fresh.iter().all(|work| !work.completed && work.failed_attempts == 0));

        // An in-flight pass-0 record with next_chunk_index = 2 resumes at 2.
        let migrated = init_chunk_work(3, 2);
        assert!(migrated[0].completed);
        assert!(migrated[1].completed);
        assert!(!migrated[2].completed);
    }

    fn work(index: u32, completed: bool, retry_not_before: Option<i64>) -> ChunkWork {
        ChunkWork {
            index,
            completed,
            failed_attempts: 0,
            ai_started_at: None,
            ai_ended_at: None,
            retry_not_before,
        }
    }

    #[test]
    fn select_wave_complete_when_all_chunks_done() {
        let chunks = vec![work(0, true, None), work(1, true, None)];
        assert_eq!(
            select_wave(&chunks, &[300.0, 300.0], 4, 600.0, 1500.0, 100),
            WaveSelection::Complete
        );
    }

    #[test]
    fn select_wave_caps_at_concurrency_lowest_index_first() {
        let chunks = vec![
            work(0, true, None),
            work(1, false, None),
            work(2, false, None),
            work(3, false, None),
        ];
        let durations = [300.0, 300.0, 300.0, 6.0];
        assert_eq!(
            select_wave(&chunks, &durations, 2, 0.0, 1500.0, 100),
            WaveSelection::Issue(vec![1, 2])
        );
        // Concurrency 1 is the pass-0 walk: one chunk, lowest pending index.
        assert_eq!(
            select_wave(&chunks, &durations, 1, 0.0, 1500.0, 100),
            WaveSelection::Issue(vec![1])
        );
        // A zero from a bad config still issues one chunk.
        assert_eq!(
            select_wave(&chunks, &durations, 0, 0.0, 1500.0, 100),
            WaveSelection::Issue(vec![1])
        );
    }

    #[test]
    fn select_wave_backoff_skips_chunk_without_blocking_siblings() {
        let chunks = vec![
            work(0, false, Some(200)),
            work(1, false, None),
            work(2, false, None),
        ];
        let durations = [300.0, 300.0, 300.0];
        // Chunk 0 is backing off; its siblings run now.
        assert_eq!(
            select_wave(&chunks, &durations, 4, 0.0, 1500.0, 100),
            WaveSelection::Issue(vec![1, 2])
        );
        // Backoff elapsed: chunk 0 rejoins.
        assert_eq!(
            select_wave(&chunks, &durations, 4, 0.0, 1500.0, 200),
            WaveSelection::Issue(vec![0, 1, 2])
        );
    }

    #[test]
    fn select_wave_waits_for_earliest_backoff_when_nothing_runnable() {
        let chunks = vec![work(0, false, Some(250)), work(1, false, Some(180))];
        assert_eq!(
            select_wave(&chunks, &[300.0, 300.0], 4, 0.0, 1500.0, 100),
            WaveSelection::WaitUntil(180)
        );
    }

    #[test]
    fn select_wave_budgets_the_whole_wave_against_the_retry_ceiling() {
        let chunks = vec![work(0, false, None), work(1, false, None), work(2, false, None)];
        let durations = [300.0, 300.0, 300.0];
        // 700 already requested, ceiling 1400: chunks 0 and 1 fit (1300),
        // chunk 2 would cross — the wave is trimmed, never failed.
        assert_eq!(
            select_wave(&chunks, &durations, 4, 700.0, 1400.0, 100),
            WaveSelection::Issue(vec![0, 1])
        );
        // The first runnable chunk crossing the ceiling is the pass-0 fatal.
        assert_eq!(
            select_wave(&chunks, &durations, 4, 1200.0, 1400.0, 100),
            WaveSelection::ExceedsRetryCeiling
        );
        // Boundary: exactly reaching the ceiling is allowed (pass-0 used
        // strict greater-than).
        assert_eq!(
            select_wave(&chunks, &durations, 1, 1100.0, 1400.0, 100),
            WaveSelection::Issue(vec![0])
        );
    }

    #[test]
    fn select_overlap_caps_excludes_and_budgets() {
        use std::collections::BTreeSet;
        let discovered: BTreeSet<u32> = [0, 1, 2, 3, 4].into();
        let none = BTreeSet::new();

        // Capacity cap, lowest index first.
        assert_eq!(select_overlap(&discovered, &none, 2, 0.0, 10_000.0), vec![0, 1]);
        // Exclusions (completed / in-flight / already attempted) are skipped.
        let excluded: BTreeSet<u32> = [0, 2].into();
        assert_eq!(select_overlap(&discovered, &excluded, 4, 0.0, 10_000.0), vec![1, 3, 4]);
        // Zero capacity issues nothing.
        assert_eq!(select_overlap(&discovered, &none, 0, 0.0, 10_000.0), Vec::<u32>::new());
        // Ceiling budgeting at the requested chunk duration: 700 budgeted,
        // ceiling 1400 fits two more 300 s estimates, not three.
        assert_eq!(select_overlap(&discovered, &none, 4, 700.0, 1400.0), vec![0, 1]);
    }

    #[test]
    fn chunk_work_and_phase_timestamps_roundtrip_and_default() {
        // Pass-0 records (no chunk_work / phase_timestamps) still decode.
        let pass0 = serde_json::json!({
            "job_id": "job-3",
            "account_id": "acct-1",
            "episode_id": "ep-3",
            "state": "transcribing",
            "created_at": 1,
            "updated_at": 2,
            "next_chunk_index": 2,
        });
        let decoded: JobRecord = serde_json::from_value(pass0).expect("decode pass-0 record");
        assert!(decoded.chunk_work.is_empty());
        assert!(decoded.phase_timestamps.is_empty());
        assert_eq!(decoded.next_chunk_index, 2);

        let record = JobRecord::created(
            "job-4".into(),
            "acct-1".into(),
            "ep-4".into(),
            None,
            None,
            None,
            None,
            1_784_000_000,
        );
        assert_eq!(record.phase_timestamps.get(STATE_CREATED), Some(&1_784_000_000));
        let json = serde_json::to_string(&record).expect("serialize");
        let decoded: JobRecord = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded.phase_timestamps.len(), 1);
    }

    #[test]
    fn upload_part_geometry_is_uniform_with_smaller_tail() {
        const PART: i64 = 16 * 1024 * 1024;
        // Exactly one part for anything at or under the part size.
        assert_eq!(upload_part_count(1, PART), Some(1));
        assert_eq!(upload_part_count(PART, PART), Some(1));
        assert_eq!(upload_part_count(PART + 1, PART), Some(2));
        // 512 MiB cap → 32 uniform parts.
        assert_eq!(upload_part_count(512 * 1024 * 1024, PART), Some(32));
        assert_eq!(upload_part_count(0, PART), None);
        assert_eq!(upload_part_count(-5, PART), None);
        assert_eq!(upload_part_count(PART, 0), None);
        // Part-count ceiling (R2's 10,000-part S3 limit).
        assert_eq!(upload_part_count(10_001, 1), None);

        // Ranges: uniform non-final parts, exact remainder tail.
        let total = PART * 2 + 12_345;
        assert_eq!(upload_part_range(total, PART, 1), Some((0, PART)));
        assert_eq!(upload_part_range(total, PART, 2), Some((PART, 2 * PART)));
        assert_eq!(
            upload_part_range(total, PART, 3),
            Some((2 * PART, 2 * PART + 12_345))
        );
        assert_eq!(upload_part_range(total, PART, 4), None);
        assert_eq!(upload_part_range(total, PART, 0), None);
    }

    #[test]
    fn source_object_key_follows_upload_completion() {
        let mut record = JobRecord::created(
            "job-k".into(),
            "acct-1".into(),
            "ep-k".into(),
            None,
            None,
            None,
            None,
            1,
        );
        assert_eq!(record.source_object_key(), "raw/job-k/source");
        record.upload_completed = true;
        assert_eq!(record.source_object_key(), "uploads/job-k/source");
    }

    #[test]
    fn upload_fields_default_off_for_old_records() {
        let minimal = serde_json::json!({
            "job_id": "job-old",
            "account_id": "acct-1",
            "episode_id": "ep-old",
            "state": "created",
            "created_at": 1,
            "updated_at": 1,
        });
        let decoded: JobRecord = serde_json::from_value(minimal).expect("decode");
        assert!(!decoded.origin_unsafe);
        assert!(!decoded.upload_completed);
        assert_eq!(decoded.upload_id, None);
        assert_eq!(decoded.upload_part_count, None);
    }

    #[test]
    fn take_full_part_slices_exact_uniform_parts() {
        const PART: usize = 1000;
        // Varying chunk sizes reproduce the live failure shape: a stream
        // whose reads never align with the part boundary.
        let chunk_sizes = [700usize, 700, 700, 700, 350, 900, 13, 800];
        let total: usize = chunk_sizes.iter().sum();
        let mut buffer = Vec::new();
        let mut parts = Vec::new();
        let mut next_byte: u8 = 0;
        for size in chunk_sizes {
            let chunk: Vec<u8> = (0..size)
                .map(|_| {
                    let byte = next_byte;
                    next_byte = next_byte.wrapping_add(1);
                    byte
                })
                .collect();
            buffer.extend_from_slice(&chunk);
            while let Some(part) = take_full_part(&mut buffer, PART) {
                parts.push(part);
            }
        }
        assert_eq!(parts.len(), total / PART);
        for part in &parts {
            assert_eq!(part.len(), PART);
        }
        assert_eq!(buffer.len(), total % PART);
        // Order and content survive the slicing.
        let mut reassembled: Vec<u8> = parts.into_iter().flatten().collect();
        reassembled.extend_from_slice(&buffer);
        let mut expected_byte: u8 = 0;
        for byte in reassembled {
            assert_eq!(byte, expected_byte);
            expected_byte = expected_byte.wrapping_add(1);
        }
    }
}

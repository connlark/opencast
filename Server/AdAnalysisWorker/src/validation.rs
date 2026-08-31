use std::collections::{HashMap, HashSet};

use serde::Deserialize;

use crate::prompt::{segment_framing_chars, PROMPT_OVERHEAD_CHAR_ALLOWANCE};
use crate::types::{
    AdAnalysisRequest, AdSpanKind, GeminiUsage, TranscriptSegment, ValidatedAdSpan,
    APP_ATTEST_KEY_DAILY_ESTIMATED_INPUT_TOKEN_CAP, APP_ATTEST_KEY_DAILY_REQUEST_CAP,
    BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP, BEARER_DAILY_REQUEST_CAP,
    GLOBAL_DAILY_ESTIMATED_INPUT_TOKEN_CAP, GLOBAL_DAILY_REQUEST_CAP, MAX_BODY_BYTES,
    MAX_EPISODE_ID_CHARS, MAX_ESTIMATED_INPUT_TOKENS_PER_REQUEST, MAX_LANGUAGE_CODE_CHARS,
    MAX_PODCAST_ID_CHARS, MAX_REQUEST_ID_CHARS, MAX_SEGMENTS, MAX_SEGMENT_TEXT_CHARS,
    MAX_TITLE_CHARS, MAX_TRANSCRIPT_TEXT_CHARS, SCHEMA_VERSION,
    TRANSCRIPTION_ACCOUNT_DAILY_ESTIMATED_INPUT_TOKEN_CAP, TRANSCRIPTION_ACCOUNT_DAILY_REQUEST_CAP,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidationError {
    BodyTooLarge,
    MalformedJson,
    UnsupportedSchemaVersion,
    EmptyRequestID,
    EmptyEpisodeID,
    EmptyPodcastID,
    TranscriptNotCompleted,
    InvalidTranscriptMetadata,
    SegmentCountMismatch,
    SegmentCountExceeded,
    EmptySegments,
    DuplicateSegmentID(i64),
    EmptySegmentText(i64),
    SegmentTextTooLarge(i64),
    InvalidSegmentTiming(i64),
    NonMonotonicSegments(i64),
    TranscriptTextTooLarge,
    EstimatedInputTooLarge,
    MetadataFieldTooLarge,
}

impl ValidationError {
    pub fn code(&self) -> &'static str {
        match self {
            ValidationError::BodyTooLarge => "body_too_large",
            ValidationError::MalformedJson => "malformed_json",
            ValidationError::UnsupportedSchemaVersion => "unsupported_schema_version",
            ValidationError::EmptyRequestID => "empty_request_id",
            ValidationError::EmptyEpisodeID => "empty_episode_id",
            ValidationError::EmptyPodcastID => "empty_podcast_id",
            ValidationError::TranscriptNotCompleted => "transcript_not_completed",
            ValidationError::InvalidTranscriptMetadata => "invalid_transcript_metadata",
            ValidationError::SegmentCountMismatch => "segment_count_mismatch",
            ValidationError::SegmentCountExceeded => "segment_count_exceeded",
            ValidationError::EmptySegments => "empty_segments",
            ValidationError::DuplicateSegmentID(_) => "duplicate_segment_id",
            ValidationError::EmptySegmentText(_) => "empty_segment_text",
            ValidationError::SegmentTextTooLarge(_) => "segment_text_too_large",
            ValidationError::InvalidSegmentTiming(_) => "invalid_segment_timing",
            ValidationError::NonMonotonicSegments(_) => "non_monotonic_segments",
            ValidationError::TranscriptTextTooLarge => "transcript_text_too_large",
            ValidationError::EstimatedInputTooLarge => "estimated_input_too_large",
            ValidationError::MetadataFieldTooLarge => "metadata_field_too_large",
        }
    }

    pub fn http_status(&self) -> u16 {
        match self {
            ValidationError::BodyTooLarge => 413,
            _ => 400,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContentLengthError {
    Missing,
    Invalid,
    TooLarge,
}

impl ContentLengthError {
    pub fn code(&self) -> &'static str {
        match self {
            ContentLengthError::Missing => "content_length_required",
            ContentLengthError::Invalid => "invalid_content_length",
            ContentLengthError::TooLarge => "body_too_large",
        }
    }

    pub fn http_status(&self) -> u16 {
        match self {
            ContentLengthError::Missing => 411,
            ContentLengthError::Invalid => 400,
            ContentLengthError::TooLarge => 413,
        }
    }
}

pub fn validate_content_length(raw: Option<&str>) -> Result<usize, ContentLengthError> {
    let Some(raw) = raw else {
        return Err(ContentLengthError::Missing);
    };
    let length = raw
        .trim()
        .parse::<usize>()
        .map_err(|_| ContentLengthError::Invalid)?;
    if length > MAX_BODY_BYTES {
        return Err(ContentLengthError::TooLarge);
    }
    Ok(length)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestEstimate {
    pub transcript_text_chars: usize,
    pub estimated_input_tokens: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ValidatedRequest {
    pub request: AdAnalysisRequest,
    pub estimate: RequestEstimate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapError {
    DailyRequestsExceeded,
    DailyEstimatedInputTokensExceeded,
    GlobalCapacityExhausted,
}

impl CapError {
    pub fn code(&self) -> &'static str {
        match self {
            CapError::DailyRequestsExceeded => "daily_request_cap_exceeded",
            CapError::DailyEstimatedInputTokensExceeded => "daily_input_token_cap_exceeded",
            CapError::GlobalCapacityExhausted => "global_capacity_exhausted",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UsageLimits {
    pub request_cap: u64,
    pub estimated_input_token_cap: u64,
    pub request_error: CapError,
    pub estimated_input_token_error: CapError,
}

impl UsageLimits {
    pub const BEARER: Self = Self {
        request_cap: BEARER_DAILY_REQUEST_CAP,
        estimated_input_token_cap: BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP,
        request_error: CapError::DailyRequestsExceeded,
        estimated_input_token_error: CapError::DailyEstimatedInputTokensExceeded,
    };

    pub const APP_ATTEST_KEY: Self = Self {
        request_cap: APP_ATTEST_KEY_DAILY_REQUEST_CAP,
        estimated_input_token_cap: APP_ATTEST_KEY_DAILY_ESTIMATED_INPUT_TOKEN_CAP,
        request_error: CapError::DailyRequestsExceeded,
        estimated_input_token_error: CapError::DailyEstimatedInputTokensExceeded,
    };

    pub const TRANSCRIPTION_ACCOUNT: Self = Self {
        request_cap: TRANSCRIPTION_ACCOUNT_DAILY_REQUEST_CAP,
        estimated_input_token_cap: TRANSCRIPTION_ACCOUNT_DAILY_ESTIMATED_INPUT_TOKEN_CAP,
        request_error: CapError::DailyRequestsExceeded,
        estimated_input_token_error: CapError::DailyEstimatedInputTokensExceeded,
    };

    pub const GLOBAL: Self = Self {
        request_cap: GLOBAL_DAILY_REQUEST_CAP,
        estimated_input_token_cap: GLOBAL_DAILY_ESTIMATED_INPUT_TOKEN_CAP,
        request_error: CapError::GlobalCapacityExhausted,
        estimated_input_token_error: CapError::GlobalCapacityExhausted,
    };
}

#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
pub struct DailyUsage {
    pub request_count: u64,
    pub estimated_input_tokens: u64,
}

impl DailyUsage {
    pub fn admitting(&self, estimated_input_tokens: u64) -> Result<Self, CapError> {
        self.admitting_with_limits(estimated_input_tokens, UsageLimits::BEARER)
    }

    pub fn admitting_with_limits(
        &self,
        estimated_input_tokens: u64,
        limits: UsageLimits,
    ) -> Result<Self, CapError> {
        let next_requests = self.request_count.saturating_add(1);
        if next_requests > limits.request_cap {
            return Err(limits.request_error);
        }

        let next_tokens = self
            .estimated_input_tokens
            .saturating_add(estimated_input_tokens);
        if next_tokens > limits.estimated_input_token_cap {
            return Err(limits.estimated_input_token_error);
        }

        Ok(Self {
            request_count: next_requests,
            estimated_input_tokens: next_tokens,
        })
    }
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct ModelSpan {
    pub kind: String,
    pub label: String,
    pub start_segment_id: i64,
    pub end_segment_id: i64,
    pub confidence: f64,
    #[serde(default)]
    pub evidence_quote: String,
}

#[derive(Debug, Clone)]
pub struct ModelOutput {
    pub spans: Vec<ModelSpan>,
    pub malformed_span_count: usize,
}

impl ModelOutput {
    pub fn from_spans(spans: Vec<ModelSpan>) -> Self {
        Self {
            spans,
            malformed_span_count: 0,
        }
    }
}

impl<'de> Deserialize<'de> for ModelOutput {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let raw = RawModelOutput::deserialize(deserializer)?;
        let mut spans = Vec::new();
        let mut malformed_span_count = 0usize;

        for span in raw.spans {
            match serde_json::from_value(span) {
                Ok(span) => spans.push(span),
                Err(_) => malformed_span_count = malformed_span_count.saturating_add(1),
            }
        }

        Ok(Self {
            spans,
            malformed_span_count,
        })
    }
}

#[derive(Debug, Clone, Deserialize)]
struct RawModelOutput {
    // No `#[serde(default)]`: a response missing `spans` entirely (`{}` or a
    // wrong-shape object) must be a deserialize error so it takes the
    // malformed → retry → warning path, not read as an authoritative empty
    // result indistinguishable from a genuine `{"spans": []}` (AA-7).
    spans: Vec<serde_json::Value>,
}

pub fn decode_and_validate_request(body: &[u8]) -> Result<ValidatedRequest, ValidationError> {
    if body.len() > MAX_BODY_BYTES {
        return Err(ValidationError::BodyTooLarge);
    }

    let request: AdAnalysisRequest =
        serde_json::from_slice(body).map_err(|_| ValidationError::MalformedJson)?;
    validate_request(request)
}

pub fn validate_request(request: AdAnalysisRequest) -> Result<ValidatedRequest, ValidationError> {
    if request.schema_version != SCHEMA_VERSION {
        return Err(ValidationError::UnsupportedSchemaVersion);
    }
    if request.request_id.trim().is_empty() {
        return Err(ValidationError::EmptyRequestID);
    }
    if request.episode_id.trim().is_empty() {
        return Err(ValidationError::EmptyEpisodeID);
    }
    if request.podcast_id.trim().is_empty() {
        return Err(ValidationError::EmptyPodcastID);
    }
    if request.transcript.state != "completed" {
        return Err(ValidationError::TranscriptNotCompleted);
    }
    // Header fields enter the prompt; bound them so an oversized title or
    // feed-derived GUID cannot inflate the prompt past the spend caps it
    // escapes (AA-2). Titles are optional; when absent build_prompt falls
    // back to the id, which is itself bounded here.
    if request.request_id.chars().count() > MAX_REQUEST_ID_CHARS
        || request.episode_id.chars().count() > MAX_EPISODE_ID_CHARS
        || request.podcast_id.chars().count() > MAX_PODCAST_ID_CHARS
        || request.transcript.language_code.chars().count() > MAX_LANGUAGE_CODE_CHARS
        || request
            .episode_title
            .as_deref()
            .is_some_and(|title| title.chars().count() > MAX_TITLE_CHARS)
        || request
            .podcast_title
            .as_deref()
            .is_some_and(|title| title.chars().count() > MAX_TITLE_CHARS)
    {
        return Err(ValidationError::MetadataFieldTooLarge);
    }
    if request.transcript.language_code.trim().is_empty()
        || request.transcript.fingerprint.trim().is_empty()
        || request.transcript.updated_at.trim().is_empty()
        || !valid_positive_f64(request.transcript.audio_duration)
    {
        return Err(ValidationError::InvalidTranscriptMetadata);
    }
    if request.transcript.segment_count != request.segments.len() {
        return Err(ValidationError::SegmentCountMismatch);
    }
    if request.segments.is_empty() {
        return Err(ValidationError::EmptySegments);
    }
    if request.segments.len() > MAX_SEGMENTS {
        return Err(ValidationError::SegmentCountExceeded);
    }

    let mut seen = HashSet::new();
    let mut previous_end = None;
    let mut transcript_text_chars = 0usize;
    let mut segment_framing_chars_total = 0usize;
    for segment in &request.segments {
        if !seen.insert(segment.id) {
            return Err(ValidationError::DuplicateSegmentID(segment.id));
        }
        let text_len = segment.text.chars().count();
        if segment.text.trim().is_empty() {
            return Err(ValidationError::EmptySegmentText(segment.id));
        }
        if text_len > MAX_SEGMENT_TEXT_CHARS {
            return Err(ValidationError::SegmentTextTooLarge(segment.id));
        }
        if !valid_segment_timing(segment) {
            return Err(ValidationError::InvalidSegmentTiming(segment.id));
        }
        if let Some(previous_end) = previous_end {
            if segment.start + 0.001 < previous_end {
                return Err(ValidationError::NonMonotonicSegments(segment.id));
            }
        }
        previous_end = Some(segment.end);
        transcript_text_chars = transcript_text_chars.saturating_add(text_len);
        segment_framing_chars_total =
            segment_framing_chars_total.saturating_add(segment_framing_chars(segment));
    }
    if transcript_text_chars > MAX_TRANSCRIPT_TEXT_CHARS {
        return Err(ValidationError::TranscriptTextTooLarge);
    }

    // The fixed allowance stands in for build_prompt's invariant header/block;
    // the per-segment framing (`[id | s-e] ` + newline) scales with the
    // transcript and is added explicitly (AA-3), so a segment-dense request no
    // longer under-counts the ~30 % of the prompt the framing occupies.
    let prompt_overhead_chars =
        PROMPT_OVERHEAD_CHAR_ALLOWANCE.saturating_add(segment_framing_chars_total);
    let estimated_input_tokens =
        estimate_tokens_for_chars(transcript_text_chars + prompt_overhead_chars);
    if estimated_input_tokens > MAX_ESTIMATED_INPUT_TOKENS_PER_REQUEST {
        return Err(ValidationError::EstimatedInputTooLarge);
    }

    Ok(ValidatedRequest {
        request,
        estimate: RequestEstimate {
            transcript_text_chars,
            estimated_input_tokens,
        },
    })
}

// --- promo_ad_breaks_v2 structural validation. Keep the external evaluation
// harness aligned with these executable rules. ---

pub const MAX_SPAN_DURATION_SECONDS: f64 = 600.0;
pub const MIN_BREAK_DURATION_SECONDS: f64 = 15.0;
pub const MAX_SPAN_REQUEST_COVERAGE: f64 = 0.8;
pub const AD_BUDGET_EPISODE_FRACTION: f64 = 0.25;
pub const AD_BUDGET_FLOOR_SECONDS: f64 = 600.0;
pub const EVIDENCE_PROBE_WORDS: usize = 6;
pub const EVIDENCE_MIN_WORDS_ACCEPT: usize = 2;
pub const EVIDENCE_MIN_WORDS_REANCHOR: usize = 3;
pub const MAX_RAW_SPANS_PER_WINDOW: usize = 32;

/// AA-6 pre-merge gate: the degeneracy cap is per WINDOW — the documented
/// contract — so one degenerate window contributes nothing instead of
/// spending the whole request's combined span budget
/// (`validate_model_output`'s request-wide check stays as belt). Counts
/// well-formed and malformed spans together, mirroring the combined check.
pub fn window_output_within_span_cap(span_count: usize, malformed_span_count: usize) -> bool {
    span_count.saturating_add(malformed_span_count) <= MAX_RAW_SPANS_PER_WINDOW
}

/// Lowercase; non-alphanumeric -> boundary; collapse runs.
pub fn normalize_words(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    for ch in text.chars() {
        for lowered in ch.to_lowercase() {
            if lowered.is_alphanumeric() {
                current.push(lowered);
            } else if !current.is_empty() {
                words.push(std::mem::take(&mut current));
            }
        }
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

struct TranscriptIndex {
    words: Vec<String>,
    segment_of_word: Vec<usize>,
}

impl TranscriptIndex {
    fn new(segments: &[TranscriptSegment]) -> Self {
        let mut words = Vec::new();
        let mut segment_of_word = Vec::new();
        for (index, segment) in segments.iter().enumerate() {
            for word in normalize_words(&segment.text) {
                words.push(word);
                segment_of_word.push(index);
            }
        }
        Self {
            words,
            segment_of_word,
        }
    }

    fn occurrences(&self, probe: &[String]) -> Vec<usize> {
        if probe.is_empty() || probe.len() > self.words.len() {
            return Vec::new();
        }
        (0..=self.words.len() - probe.len())
            .filter(|&start| self.words[start..start + probe.len()] == *probe)
            .collect()
    }
}

enum AnchorResult {
    Accepted,
    Reanchored {
        start_index: usize,
        end_index: usize,
    },
    Missing,
    OutOfSpan,
}

/// Reinterpret a span whose boundary IDs are BOTH unknown as second offsets —
/// the measured §4c ID/seconds confusion, observed deterministically from the
/// Gemini serving region behind the production domain (bugged-tiny midroll
/// returned as start 1263 for the pod at 1262-1385 s). Rescue only when every
/// independent signal agrees: plausible times within the audio, a mappable
/// segment window, and the evidence quote anchoring at exactly one transcript
/// location inside that window. Anything weaker drops as before.
fn rescue_seconds_span(
    transcript: &TranscriptIndex,
    segments: &[TranscriptSegment],
    start_seconds: f64,
    end_seconds: f64,
    evidence_quote: &str,
    audio_duration: f64,
) -> Option<(usize, usize)> {
    if !(start_seconds >= 0.0
        && start_seconds < end_seconds
        && end_seconds <= audio_duration + 60.0)
    {
        return None;
    }

    let start_index = segments
        .iter()
        .position(|segment| segment.start <= start_seconds && start_seconds < segment.end)
        .or_else(|| {
            segments
                .iter()
                .position(|segment| segment.start >= start_seconds)
        })?;
    // Conservative end: the last segment fully finished by end_seconds (+1 s
    // tolerance) — undershoot leaves a sliver of ad audio, overshoot would
    // eat show content.
    let end_index = segments
        .iter()
        .rposition(|segment| segment.end <= end_seconds + 1.0)?;
    if end_index < start_index {
        return None;
    }

    let quote_words = normalize_words(evidence_quote);
    if quote_words.len() < EVIDENCE_MIN_WORDS_REANCHOR {
        return None;
    }
    let probe: Vec<String> = quote_words
        .iter()
        .take(EVIDENCE_PROBE_WORDS)
        .cloned()
        .collect();
    let occurrences = transcript.occurrences(&probe);
    if occurrences.len() != 1 {
        return None;
    }
    let occurrence = occurrences[0];
    if transcript.segment_of_word[occurrence] >= start_index
        && transcript.segment_of_word[occurrence + probe.len() - 1] <= end_index
    {
        Some((start_index, end_index))
    } else {
        None
    }
}

/// Evidence anchoring: accept when the probe (first 6 normalized words of the
/// quote) occurs inside the span; when it occurs at exactly one location
/// elsewhere, shift the span (length-preserving) onto that anchor — this
/// exactly repairs the measured uniform segment-ID drift (research §4c);
/// otherwise drop. Quotes under 2 normalized words carry no anchor. The
/// riskier re-anchor path additionally requires a 3-word quote.
fn anchor_evidence(
    transcript: &TranscriptIndex,
    evidence_quote: &str,
    start_index: usize,
    end_index: usize,
    segment_count: usize,
) -> AnchorResult {
    let quote_words = normalize_words(evidence_quote);
    if quote_words.len() < EVIDENCE_MIN_WORDS_ACCEPT {
        return AnchorResult::Missing;
    }
    let probe: Vec<String> = quote_words
        .iter()
        .take(EVIDENCE_PROBE_WORDS)
        .cloned()
        .collect();
    let occurrences = transcript.occurrences(&probe);
    for &occurrence in &occurrences {
        if transcript.segment_of_word[occurrence] >= start_index
            && transcript.segment_of_word[occurrence + probe.len() - 1] <= end_index
        {
            return AnchorResult::Accepted;
        }
    }
    if occurrences.len() == 1 && quote_words.len() >= EVIDENCE_MIN_WORDS_REANCHOR {
        let occurrence = occurrences[0];
        let anchor_segment = transcript.segment_of_word[occurrence];
        let delta = anchor_segment as i64 - start_index as i64;
        let new_start = start_index as i64 + delta;
        let new_end = end_index as i64 + delta;
        if new_start >= 0
            && new_end >= 0
            && (new_start as usize) < segment_count
            && (new_end as usize) < segment_count
            && transcript.segment_of_word[occurrence] >= new_start as usize
            && transcript.segment_of_word[occurrence + probe.len() - 1] <= new_end as usize
        {
            return AnchorResult::Reanchored {
                start_index: new_start as usize,
                end_index: new_end as usize,
            };
        }
    }
    AnchorResult::OutOfSpan
}

pub fn validate_model_output(
    request: &AdAnalysisRequest,
    model_output: ModelOutput,
) -> (Vec<ValidatedAdSpan>, Vec<String>) {
    // Degenerate-output cap: every real run across 8 models x 3 prompts
    // returned <= 16 raw spans (serving-config max 8); the measured
    // span-per-segment degeneration returned 90. Anything above the cap is
    // model degeneration — contribute nothing rather than junk skip zones.
    let returned_span_count = model_output
        .spans
        .len()
        .saturating_add(model_output.malformed_span_count);
    let span_cap = MAX_RAW_SPANS_PER_WINDOW
        .saturating_mul(crate::windowing::window_count(request.segments.len()));
    if returned_span_count > span_cap {
        return (
            Vec::new(),
            vec![format!("degenerate_span_count:{returned_span_count}")],
        );
    }

    let index_by_id: HashMap<i64, usize> = request
        .segments
        .iter()
        .enumerate()
        .map(|(index, segment)| (segment.id, index))
        .collect();
    let transcript = TranscriptIndex::new(&request.segments);

    let mut warnings = Vec::new();
    let mut spans = Vec::new();
    let mut seen = HashSet::new();
    for _ in 0..model_output.malformed_span_count {
        warnings.push("dropped malformed span".to_string());
    }

    for span in model_output.spans {
        let Some(kind) = AdSpanKind::from_model_value(span.kind.as_str()) else {
            warnings.push(format!("dropped span with unknown kind {}", span.kind));
            continue;
        };

        let key = (
            kind.as_str(),
            span.start_segment_id,
            span.end_segment_id,
            span.label.trim().to_string(),
        );
        if !seen.insert(key) {
            warnings.push(format!(
                "dropped duplicate span {}-{}",
                span.start_segment_id, span.end_segment_id
            ));
            continue;
        }

        let known_start = index_by_id.get(&span.start_segment_id).copied();
        let known_end = index_by_id.get(&span.end_segment_id).copied();
        let (start_index, end_index) = match (known_start, known_end) {
            (Some(start_index), Some(end_index)) => (start_index, end_index),
            (None, None) => {
                let Some((start_index, end_index)) = rescue_seconds_span(
                    &transcript,
                    &request.segments,
                    span.start_segment_id as f64,
                    span.end_segment_id as f64,
                    span.evidence_quote.trim(),
                    request.transcript.audio_duration,
                ) else {
                    warnings.push(format!(
                        "dropped span with unknown start segment {}",
                        span.start_segment_id
                    ));
                    continue;
                };
                warnings.push(format!(
                    "ids_reinterpreted_as_seconds:{}-{}->{}-{}",
                    span.start_segment_id,
                    span.end_segment_id,
                    request.segments[start_index].id,
                    request.segments[end_index].id
                ));
                (start_index, end_index)
            }
            (None, Some(_)) => {
                warnings.push(format!(
                    "dropped span with unknown start segment {}",
                    span.start_segment_id
                ));
                continue;
            }
            (Some(_), None) => {
                warnings.push(format!(
                    "dropped span with unknown end segment {}",
                    span.end_segment_id
                ));
                continue;
            }
        };
        if end_index < start_index {
            warnings.push(format!(
                "dropped reversed span {}-{}",
                span.start_segment_id, span.end_segment_id
            ));
            continue;
        }
        if span.label.trim().is_empty() {
            warnings.push(format!(
                "dropped unlabeled span {}-{}",
                span.start_segment_id, span.end_segment_id
            ));
            continue;
        }
        if !span.confidence.is_finite() {
            warnings.push(format!(
                "dropped span with invalid confidence {}-{}",
                span.start_segment_id, span.end_segment_id
            ));
            continue;
        }

        let confidence = span.confidence.clamp(0.0, 1.0);
        if (confidence - span.confidence).abs() > f64::EPSILON {
            warnings.push(format!(
                "clamped confidence for span {}-{}",
                span.start_segment_id, span.end_segment_id
            ));
        }

        let (start_index, end_index) = match anchor_evidence(
            &transcript,
            span.evidence_quote.trim(),
            start_index,
            end_index,
            request.segments.len(),
        ) {
            AnchorResult::Accepted => (start_index, end_index),
            AnchorResult::Reanchored {
                start_index: new_start,
                end_index: new_end,
            } => {
                warnings.push(format!(
                    "evidence_reanchored:{}-{}->{}-{}",
                    span.start_segment_id,
                    span.end_segment_id,
                    request.segments[new_start].id,
                    request.segments[new_end].id
                ));
                (new_start, new_end)
            }
            AnchorResult::Missing => {
                warnings.push(format!(
                    "evidence_missing:{}-{}",
                    span.start_segment_id, span.end_segment_id
                ));
                continue;
            }
            AnchorResult::OutOfSpan => {
                warnings.push(format!(
                    "evidence_out_of_span:{}-{}",
                    span.start_segment_id, span.end_segment_id
                ));
                continue;
            }
        };

        let start_segment = &request.segments[start_index];
        let end_segment = &request.segments[end_index];
        let duration = end_segment.end - start_segment.start;
        if duration > MAX_SPAN_DURATION_SECONDS {
            warnings.push(format!(
                "span_too_long:{}-{}",
                start_segment.id, end_segment.id
            ));
            continue;
        }
        if (end_index - start_index + 1) as f64
            > MAX_SPAN_REQUEST_COVERAGE * request.segments.len() as f64
        {
            warnings.push(format!(
                "span_covers_request:{}-{}",
                start_segment.id, end_segment.id
            ));
            continue;
        }

        spans.push(IndexedSpan {
            start_index,
            end_index,
            span: ValidatedAdSpan {
                kind,
                label: span.label.trim().to_string(),
                start_segment_id: start_segment.id,
                end_segment_id: end_segment.id,
                start_time: start_segment.start,
                end_time: end_segment.end,
                confidence,
                evidence_quote: span.evidence_quote.trim().to_string(),
            },
        });
    }

    spans.sort_by(|lhs, rhs| {
        lhs.start_index
            .cmp(&rhs.start_index)
            .then(lhs.end_index.cmp(&rhs.end_index))
    });

    let merged = merge_same_kind_spans(spans, request, &mut warnings);

    // Post-merge structural caps: a complete ad break is never shorter than
    // 15 s (measured junk: 1-12 s self-quoting singles; shortest real break in
    // any fixture: 37 s), and the 600 s duration AND 80 % coverage caps both
    // re-apply to merged spans so a contiguous degenerate chain cannot dodge
    // either via fragmentation. The coverage re-check is what stops ~30 small
    // same-kind fragments from merging into one whole-short-episode span the
    // client would auto-skip; the pre-merge check only
    // bounds individual raw spans.
    let mut survivors: Vec<IndexedSpan> = Vec::new();
    for span in merged {
        let duration = span.span.end_time - span.span.start_time;
        if duration < MIN_BREAK_DURATION_SECONDS {
            warnings.push(format!(
                "span_too_short:{}-{}",
                span.span.start_segment_id, span.span.end_segment_id
            ));
            continue;
        }
        if duration > MAX_SPAN_DURATION_SECONDS {
            warnings.push(format!(
                "span_too_long:{}-{}",
                span.span.start_segment_id, span.span.end_segment_id
            ));
            continue;
        }
        if (span.end_index - span.start_index + 1) as f64
            > MAX_SPAN_REQUEST_COVERAGE * request.segments.len() as f64
        {
            warnings.push(format!(
                "span_covers_request:{}-{}",
                span.span.start_segment_id, span.span.end_segment_id
            ));
            continue;
        }
        survivors.push(span);
    }

    // Episode ad budget: drop lowest-confidence merged spans (largest first on
    // ties) until total ad time fits max(25% of audio, 600 s).
    let budget = (AD_BUDGET_EPISODE_FRACTION * request.transcript.audio_duration)
        .max(AD_BUDGET_FLOOR_SECONDS);
    let mut total: f64 = survivors
        .iter()
        .map(|span| span.span.end_time - span.span.start_time)
        .sum();
    while total > budget && !survivors.is_empty() {
        let victim_position = (0..survivors.len())
            .min_by(|&a, &b| {
                let sa = &survivors[a];
                let sb = &survivors[b];
                sa.span
                    .confidence
                    .partial_cmp(&sb.span.confidence)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then(
                        (sb.span.end_time - sb.span.start_time)
                            .partial_cmp(&(sa.span.end_time - sa.span.start_time))
                            .unwrap_or(std::cmp::Ordering::Equal),
                    )
                    .then(sb.start_index.cmp(&sa.start_index))
            })
            .expect("survivors is non-empty");
        let victim = survivors.remove(victim_position);
        total -= victim.span.end_time - victim.span.start_time;
        warnings.push(format!(
            "ad_budget_exceeded:{}-{}",
            victim.span.start_segment_id, victim.span.end_segment_id
        ));
    }

    (
        survivors.into_iter().map(|span| span.span).collect(),
        warnings,
    )
}

pub fn combine_warnings(
    mut validation_warnings: Vec<String>,
    gemini_warnings: Vec<String>,
) -> Vec<String> {
    validation_warnings.extend(gemini_warnings);
    validation_warnings
}

pub fn usage_from_counts(prompt: u64, candidates: u64, total: u64) -> GeminiUsage {
    GeminiUsage {
        prompt_token_count: prompt,
        candidates_token_count: candidates,
        total_token_count: total,
    }
}

fn valid_positive_f64(value: f64) -> bool {
    value.is_finite() && value > 0.0
}

fn valid_segment_timing(segment: &TranscriptSegment) -> bool {
    segment.start.is_finite()
        && segment.end.is_finite()
        && segment.start >= 0.0
        && segment.end >= segment.start
}

fn estimate_tokens_for_chars(chars: usize) -> u64 {
    ((chars as u64).saturating_add(3)) / 4
}

#[derive(Debug, Clone)]
struct IndexedSpan {
    start_index: usize,
    end_index: usize,
    span: ValidatedAdSpan,
}

fn merge_same_kind_spans(
    spans: Vec<IndexedSpan>,
    request: &AdAnalysisRequest,
    warnings: &mut Vec<String>,
) -> Vec<IndexedSpan> {
    let mut merged: Vec<IndexedSpan> = Vec::new();
    for span in spans {
        if let Some(current) = merged
            .iter_mut()
            .rev()
            .find(|current| current.span.kind == span.span.kind)
        {
            let is_adjacent_or_overlapping =
                span.start_index <= current.end_index.saturating_add(1);
            if is_adjacent_or_overlapping {
                merge_span(current, span, request, warnings);
                continue;
            }
        }
        merged.push(span);
    }

    merged
}

fn merge_span(
    current: &mut IndexedSpan,
    span: IndexedSpan,
    request: &AdAnalysisRequest,
    warnings: &mut Vec<String>,
) {
    if !current
        .span
        .label
        .eq_ignore_ascii_case(span.span.label.as_str())
    {
        current.span.label = merged_label(&current.span.label, &span.span.label);
    }
    current.end_index = current.end_index.max(span.end_index);
    let end_segment = &request.segments[current.end_index];
    current.span.end_segment_id = end_segment.id;
    current.span.end_time = end_segment.end;
    current.span.confidence = current.span.confidence.max(span.span.confidence);
    if current.span.evidence_quote.is_empty() {
        current.span.evidence_quote = span.span.evidence_quote;
    }
    warnings.push(format!(
        "merged adjacent or overlapping {} span ending at segment {}",
        current.span.kind.as_str(),
        current.span.end_segment_id
    ));
}

fn merged_label(first: &str, second: &str) -> String {
    if first.is_empty() {
        second.to_string()
    } else if second.is_empty() || first.contains(second) {
        first.to_string()
    } else if second.contains(first) {
        second.to_string()
    } else {
        format!("{first} / {second}")
    }
}

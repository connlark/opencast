use std::collections::{HashMap, HashSet};

use serde::Deserialize;

use crate::coalescing::{
    prepare_analysis_request, CoalescingError, PreparedAnalysisRequest, UnitRemap,
};
use crate::prompt::{segment_framing_chars, PROMPT_OVERHEAD_CHAR_ALLOWANCE};
use crate::types::{
    GeminiUsage, TranscriptAnalysisRequest, TranscriptSegment, ValidatedChapter, ValidatedClaim,
    ValidatedSummary, APP_ATTEST_KEY_DAILY_ESTIMATED_INPUT_TOKEN_CAP,
    APP_ATTEST_KEY_DAILY_REQUEST_CAP, BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP,
    BEARER_DAILY_REQUEST_CAP, GLOBAL_DAILY_ESTIMATED_INPUT_TOKEN_CAP, GLOBAL_DAILY_REQUEST_CAP,
    MAX_BODY_BYTES, MAX_EPISODE_ID_CHARS, MAX_ESTIMATED_INPUT_TOKENS_PER_REQUEST,
    MAX_LANGUAGE_CODE_CHARS, MAX_PODCAST_ID_CHARS, MAX_REQUEST_ID_CHARS, MAX_SEGMENT_TEXT_CHARS,
    MAX_TITLE_CHARS, MAX_TRANSCRIPT_TEXT_CHARS, SCHEMA_VERSION,
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
    /// The model-facing cap: after worker-side coalescing, more than 2,400
    /// units is refused with a typed error the client can distinguish from
    /// abuse rejections.
    TranscriptTooLong,
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
            ValidationError::TranscriptTooLong => "transcript_too_long",
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
    pub estimated_input_tokens: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ValidatedRequest {
    pub request: TranscriptAnalysisRequest,
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

pub fn decode_and_validate_request(body: &[u8]) -> Result<ValidatedRequest, ValidationError> {
    if body.len() > MAX_BODY_BYTES {
        return Err(ValidationError::BodyTooLarge);
    }

    let request: TranscriptAnalysisRequest =
        serde_json::from_slice(body).map_err(|_| ValidationError::MalformedJson)?;
    validate_request(request)
}

pub fn validate_request(
    request: TranscriptAnalysisRequest,
) -> Result<ValidatedRequest, ValidationError> {
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
    // escapes. Titles are optional; when absent build_prompt
    // falls back to the id, which is itself bounded here.
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
    let mut seen = HashSet::new();
    let mut previous_end = None;
    let mut transcript_text_chars = 0usize;
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
    }
    if transcript_text_chars > MAX_TRANSCRIPT_TEXT_CHARS {
        return Err(ValidationError::TranscriptTextTooLarge);
    }

    // Keep the raw request for fingerprint/share identity, but enforce the
    // id ceiling and spend estimate over the exact segment view the model
    // will receive. Admission and run_analysis intentionally derive this view
    // independently: the Durable Object must hash and receive the raw request,
    // while serializing both views would roughly double its internal payload.
    let prepared = prepare_analysis_request(&request).map_err(|error| match error {
        CoalescingError::TooManyUnits => ValidationError::TranscriptTooLong,
    })?;
    let analysis_text_chars = prepared
        .model_request
        .segments
        .iter()
        .fold(0usize, |total, segment| {
            total.saturating_add(segment.text.chars().count())
        });
    let segment_framing_chars_total = prepared
        .model_request
        .segments
        .iter()
        .fold(0usize, |total, segment| {
            total.saturating_add(segment_framing_chars(segment))
        });

    // The fixed allowance stands in for build_prompt's invariant header/block;
    // the per-segment framing (`[id | s-e] ` + newline) scales with the
    // transcript and is added explicitly, so a segment-dense
    // request cannot under-count the share of the prompt the framing occupies.
    let prompt_overhead_chars =
        PROMPT_OVERHEAD_CHAR_ALLOWANCE.saturating_add(segment_framing_chars_total);
    let estimated_input_tokens =
        estimate_tokens_for_chars(analysis_text_chars + prompt_overhead_chars);
    if estimated_input_tokens > MAX_ESTIMATED_INPUT_TOKENS_PER_REQUEST {
        return Err(ValidationError::EstimatedInputTooLarge);
    }

    Ok(ValidatedRequest {
        request,
        estimate: RequestEstimate {
            estimated_input_tokens,
        },
    })
}

// --- transcript_analysis_v2 model-output validation ---
//
// Port of the external evaluation harness's executable spec. Two severity
// classes, exactly as there: HARD violations fail the output (chapters are a
// partition — a single bad chapter invalidates the whole navigation, unlike
// ad spans which drop individually), SOFT violations become response
// warnings and never fail a run (the warnings-never-502 rule). Notably
// `coverage_gap` stays soft on purpose: evaluation observed the model
// declining to start chapter 1 on a pre-roll ad pod, which
// is defensible output the client must render, not reject.

pub const CHAPTER_TITLE_MAX_CHARS: usize = 60;
pub const CHAPTER_TITLE_MAX_WORDS: usize = 12; // prompt asks <= 8; structural slack above that
pub const SUMMARY_MAX_CHARS: usize = 1_200; // prompt asks <= 120 words (~700-800 chars)
pub const ONE_LINE_MAX_CHARS: usize = 140; // prompt asks <= 90
pub const CLAIM_TEXT_MAX_CHARS: usize = 220;
pub const MIN_CLAIMS: usize = 1;
pub const MAX_CLAIMS: usize = 12;
// Hard ceiling against catastrophic over-segmentation: one chapter per 4
// minutes of audio, floor of 3 for very short episodes.
pub const MIN_CHAPTERS_FLOOR: usize = 3;
pub const CHAPTER_SECONDS_PER_CHAPTER: f64 = 240.0;

pub fn max_chapters(duration_s: f64) -> usize {
    MIN_CHAPTERS_FLOOR.max((duration_s / CHAPTER_SECONDS_PER_CHAPTER).ceil() as usize)
}

// Model output types carry no `#[serde(default)]`: a response missing a
// required field must be a deserialize error so it takes the malformed →
// retry path, never read as authoritative partial output.
// serde_json also rejects floats in the i64 id fields, which routes the
// float-id failure class through the same retry path. Unknown extra keys are
// tolerated — a deliberate relaxation of contract.py's exact-key check;
// `responseJsonSchema` constrains the real model, and tolerating extras
// keeps a benign provider-side addition from bricking every run.

#[derive(Debug, Clone, Deserialize)]
pub struct ModelChapter {
    pub title: String,
    pub start_segment_id: i64,
    pub end_segment_id: i64,
    pub confidence: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ModelClaim {
    pub text: String,
    pub evidence_segment_id: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ModelSummary {
    pub summary: String,
    pub one_line_description: String,
    pub claims: Vec<ModelClaim>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ModelOutput {
    pub chapters: Vec<ModelChapter>,
    pub summary: ModelSummary,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HardViolation {
    pub rule: &'static str,
    pub detail: String,
}

impl HardViolation {
    fn new(rule: &'static str, detail: impl Into<String>) -> Self {
        Self {
            rule,
            detail: detail.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ValidatedAnalysis {
    pub chapters: Vec<ValidatedChapter>,
    pub summary: ValidatedSummary,
    pub warnings: Vec<String>,
}

/// Raw requests take the original single validation path unchanged. A
/// coalesced request must first satisfy every rule against submitted unit ids;
/// only then are ids translated and the complete contract run again against
/// the raw segments.
#[cfg_attr(not(any(target_arch = "wasm32", test)), allow(dead_code))]
pub(crate) fn validate_and_remap_model_output(
    original: &TranscriptAnalysisRequest,
    prepared: &PreparedAnalysisRequest<'_>,
    output: ModelOutput,
) -> Result<ValidatedAnalysis, Vec<HardViolation>> {
    let Some(remap) = prepared.remap.as_deref() else {
        return validate_model_output(original, output);
    };

    // Deliberately discard unit-space warnings and derived values so no
    // internal unit id can reach the response; only raw-space validation wins.
    let _unit_space_analysis =
        validate_model_output(prepared.model_request.as_ref(), output.clone())?;
    let mapped = remap_model_output(output, remap).ok_or_else(|| {
        vec![HardViolation::new(
            "id_discipline",
            "validated unit id could not be remapped",
        )]
    })?;
    validate_model_output(original, mapped)
}

#[cfg_attr(not(any(target_arch = "wasm32", test)), allow(dead_code))]
fn remap_model_output(output: ModelOutput, remap: &[UnitRemap]) -> Option<ModelOutput> {
    let chapters = output
        .chapters
        .into_iter()
        .map(|chapter| {
            let start = remap.get(usize::try_from(chapter.start_segment_id).ok()?)?;
            let end = remap.get(usize::try_from(chapter.end_segment_id).ok()?)?;
            Some(ModelChapter {
                title: chapter.title,
                start_segment_id: start.original_start_id,
                end_segment_id: end.original_end_id,
                confidence: chapter.confidence,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    let claims = output
        .summary
        .claims
        .into_iter()
        .map(|claim| {
            let evidence = remap.get(usize::try_from(claim.evidence_segment_id).ok()?)?;
            Some(ModelClaim {
                text: claim.text,
                // A claim has one anchor rather than a range. The first raw
                // id is the stable seek/context anchor for its submitted unit.
                evidence_segment_id: evidence.original_start_id,
            })
        })
        .collect::<Option<Vec<_>>>()?;

    Some(ModelOutput {
        chapters,
        summary: ModelSummary {
            summary: output.summary.summary,
            one_line_description: output.summary.one_line_description,
            claims,
        },
    })
}

pub fn validate_model_output(
    request: &TranscriptAnalysisRequest,
    output: ModelOutput,
) -> Result<ValidatedAnalysis, Vec<HardViolation>> {
    let mut hard: Vec<HardViolation> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();

    let index_by_id: HashMap<i64, usize> = request
        .segments
        .iter()
        .enumerate()
        .map(|(index, segment)| (segment.id, index))
        .collect();
    let last_index = request.segments.len() - 1;

    if output.chapters.is_empty() {
        hard.push(HardViolation::new("chapters_shape", "chapters empty"));
    }
    let chapter_cap = max_chapters(request.transcript.audio_duration);
    if output.chapters.len() > chapter_cap {
        hard.push(HardViolation::new(
            "chapter_count_cap",
            format!(
                "{} chapters exceeds cap {chapter_cap} for {:.0}s",
                output.chapters.len(),
                request.transcript.audio_duration
            ),
        ));
    }

    let mut chapters: Vec<ValidatedChapter> = Vec::new();
    let mut previous_end_index: Option<usize> = None;
    for (index, chapter) in output.chapters.iter().enumerate() {
        // Ids must exist among the submitted segments — the id-discipline
        // class (seconds or invented ids in id fields) is a hard DQ, the
        // evaluation's observed cliff failure mode.
        let start_index = index_by_id.get(&chapter.start_segment_id).copied();
        let end_index = index_by_id.get(&chapter.end_segment_id).copied();
        if start_index.is_none() {
            hard.push(HardViolation::new(
                "id_discipline",
                format!(
                    "chapter {index} start_segment_id {} is not a submitted id",
                    chapter.start_segment_id
                ),
            ));
        }
        if end_index.is_none() {
            hard.push(HardViolation::new(
                "id_discipline",
                format!(
                    "chapter {index} end_segment_id {} is not a submitted id",
                    chapter.end_segment_id
                ),
            ));
        }
        if let (Some(start_index), Some(end_index)) = (start_index, end_index) {
            if end_index < start_index {
                hard.push(HardViolation::new(
                    "chapter_order",
                    format!("chapter {index} ends before it starts"),
                ));
            } else {
                match previous_end_index {
                    Some(previous) if start_index <= previous => {
                        hard.push(HardViolation::new(
                            "chapter_overlap",
                            format!(
                                "chapter {index} starts at segment {}, chapter {} ended at segment {}",
                                chapter.start_segment_id,
                                index - 1,
                                request.segments[previous].id
                            ),
                        ));
                    }
                    Some(previous) if start_index != previous + 1 => {
                        warnings.push(format!(
                            "coverage_gap: gap of {} segments before chapter {index}",
                            start_index - previous - 1
                        ));
                    }
                    None if start_index != 0 => {
                        warnings.push(format!(
                            "coverage_gap: first chapter starts at segment {}, not {}",
                            chapter.start_segment_id, request.segments[0].id
                        ));
                    }
                    _ => {}
                }
                previous_end_index = Some(end_index);
            }
        }

        if chapter.title.trim().is_empty() {
            hard.push(HardViolation::new(
                "chapter_title",
                format!("chapter {index} title missing or empty"),
            ));
        } else {
            let title_chars = chapter.title.chars().count();
            if title_chars > CHAPTER_TITLE_MAX_CHARS {
                warnings.push(format!(
                    "chapter_title_length: chapter {index} title is {title_chars} chars"
                ));
            }
            let word_count = chapter.title.split_whitespace().count();
            if word_count > CHAPTER_TITLE_MAX_WORDS {
                warnings.push(format!(
                    "chapter_title_words: chapter {index} title is {word_count} words"
                ));
            }
            check_free_text(
                &chapter.title,
                &format!("chapter {index} title"),
                &mut hard,
                &mut warnings,
            );
        }
        if !chapter.confidence.is_finite() || !(0.0..=1.0).contains(&chapter.confidence) {
            hard.push(HardViolation::new(
                "chapter_confidence",
                format!("chapter {index} confidence {}", chapter.confidence),
            ));
        }

        if let (Some(start_index), Some(end_index)) = (start_index, end_index) {
            if end_index >= start_index {
                chapters.push(ValidatedChapter {
                    title: chapter.title.trim().to_string(),
                    start_segment_id: chapter.start_segment_id,
                    end_segment_id: chapter.end_segment_id,
                    start_time: request.segments[start_index].start,
                    end_time: request.segments[end_index].end,
                    confidence: chapter.confidence,
                });
            }
        }
    }
    if let Some(previous) = previous_end_index {
        if previous != last_index {
            warnings.push(format!(
                "coverage_gap: last chapter ends at segment {}, transcript ends at segment {}",
                request.segments[previous].id, request.segments[last_index].id
            ));
        }
    }

    let summary = &output.summary;
    if summary.summary.trim().is_empty() {
        hard.push(HardViolation::new(
            "summary_text",
            "summary missing or empty",
        ));
    } else {
        let summary_chars = summary.summary.chars().count();
        if summary_chars > SUMMARY_MAX_CHARS {
            hard.push(HardViolation::new(
                "summary_length",
                format!("summary is {summary_chars} chars"),
            ));
        }
        check_free_text(&summary.summary, "summary", &mut hard, &mut warnings);
    }
    if summary.one_line_description.trim().is_empty() {
        hard.push(HardViolation::new(
            "one_line_text",
            "one_line_description missing or empty",
        ));
    } else {
        let one_line_chars = summary.one_line_description.chars().count();
        if one_line_chars > ONE_LINE_MAX_CHARS {
            hard.push(HardViolation::new(
                "one_line_length",
                format!("one_line_description is {one_line_chars} chars"),
            ));
        }
        check_free_text(
            &summary.one_line_description,
            "one_line_description",
            &mut hard,
            &mut warnings,
        );
    }
    if !(MIN_CLAIMS..=MAX_CLAIMS).contains(&summary.claims.len()) {
        hard.push(HardViolation::new(
            "claims_count",
            format!("claims count {}", summary.claims.len()),
        ));
    } else {
        for (index, claim) in summary.claims.iter().enumerate() {
            if !index_by_id.contains_key(&claim.evidence_segment_id) {
                hard.push(HardViolation::new(
                    "id_discipline",
                    format!(
                        "claim {index} evidence_segment_id {} is not a submitted id",
                        claim.evidence_segment_id
                    ),
                ));
            }
            if claim.text.trim().is_empty() {
                hard.push(HardViolation::new(
                    "claim_text",
                    format!("claim {index} text missing or empty"),
                ));
            } else {
                let claim_chars = claim.text.chars().count();
                if claim_chars > CLAIM_TEXT_MAX_CHARS {
                    warnings.push(format!(
                        "claim_text_length: claim {index} text is {claim_chars} chars"
                    ));
                }
                check_free_text(
                    &claim.text,
                    &format!("claim {index} text"),
                    &mut hard,
                    &mut warnings,
                );
            }
        }
    }

    if !hard.is_empty() {
        return Err(hard);
    }
    Ok(ValidatedAnalysis {
        chapters,
        summary: ValidatedSummary {
            summary: summary.summary.trim().to_string(),
            one_line_description: summary.one_line_description.trim().to_string(),
            claims: summary
                .claims
                .iter()
                .map(|claim| ValidatedClaim {
                    text: claim.text.trim().to_string(),
                    evidence_segment_id: claim.evidence_segment_id,
                })
                .collect(),
        },
        warnings,
    })
}

fn check_free_text(
    text: &str,
    field: &str,
    hard: &mut Vec<HardViolation>,
    warnings: &mut Vec<String>,
) {
    if contains_url_shape(text) {
        hard.push(HardViolation::new(
            "no_urls",
            format!("{field} contains a URL-shaped string"),
        ));
    }
    if contains_emoji(text) {
        warnings.push(format!("no_emoji: {field} contains emoji"));
    }
    if contains_hashtag(text) {
        warnings.push(format!("no_hashtags: {field} contains a hashtag"));
    }
    if text.contains('\n') {
        warnings.push(format!("no_newlines: {field} contains a newline"));
    }
}

/// Port of contract URL_PATTERN: scheme prefixes, `www.`, or a bare
/// domain-with-path (`label.tld/` where the label character before the dot
/// is alphanumeric or a hyphen). The transcript is attacker-controlled and
/// summaries render in-app, so URL-shaped output is a hard violation.
pub fn contains_url_shape(text: &str) -> bool {
    let lower = text.to_lowercase();
    if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") {
        return true;
    }
    for suffix in [".com/", ".net/", ".org/", ".io/", ".co/", ".ly/", ".gg/"] {
        let mut search_from = 0;
        while let Some(position) = lower[search_from..].find(suffix) {
            let absolute = search_from + position;
            if lower[..absolute]
                .chars()
                .next_back()
                .is_some_and(|ch| ch.is_ascii_alphanumeric() || ch == '-')
            {
                return true;
            }
            search_from = absolute + suffix.len();
        }
    }
    false
}

fn contains_emoji(text: &str) -> bool {
    text.chars().any(|ch| {
        let code = ch as u32;
        (0x1F000..=0x1FAFF).contains(&code)
            || (0x2700..=0x27BF).contains(&code)
            || (0x2600..=0x26FF).contains(&code)
    })
}

fn contains_hashtag(text: &str) -> bool {
    let mut characters = text.chars().peekable();
    while let Some(ch) = characters.next() {
        if ch == '#'
            && characters
                .peek()
                .is_some_and(|next| next.is_alphanumeric() || *next == '_')
        {
            return true;
        }
    }
    false
}

pub fn combine_warnings(
    mut validation_warnings: Vec<String>,
    gemini_warnings: Vec<String>,
) -> Vec<String> {
    validation_warnings.extend(gemini_warnings);
    validation_warnings
}

pub fn usage_from_counts(prompt: u64, candidates: u64, thoughts: u64, total: u64) -> GeminiUsage {
    GeminiUsage {
        prompt_token_count: prompt,
        candidates_token_count: candidates,
        thoughts_token_count: thoughts,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn dense_request() -> TranscriptAnalysisRequest {
        let segments = (0..1_400)
            .map(|index| TranscriptSegment {
                id: 10_000 + index as i64 * 2,
                start: index as f64,
                end: (index + 1) as f64,
                text: format!("word-{index}"),
            })
            .collect();
        TranscriptAnalysisRequest {
            schema_version: SCHEMA_VERSION,
            async_supported: false,
            request_id: "remap-test".to_string(),
            episode_id: "episode".to_string(),
            podcast_id: "podcast".to_string(),
            episode_title: Some("Episode".to_string()),
            podcast_title: Some("Podcast".to_string()),
            transcript: crate::types::TranscriptMetadata {
                language_code: "en".to_string(),
                audio_duration: 1_400.0,
                model_identifier: None,
                model_version: None,
                model_tree_sha256: None,
                fingerprint: "fingerprint".to_string(),
                updated_at: "2026-08-25T00:00:00Z".to_string(),
                state: "completed".to_string(),
                segment_count: 1_400,
            },
            segments,
        }
    }

    fn valid_unit_output() -> ModelOutput {
        ModelOutput {
            chapters: vec![
                ModelChapter {
                    title: "First half".to_string(),
                    start_segment_id: 0,
                    end_segment_id: 139,
                    confidence: 0.9,
                },
                ModelChapter {
                    title: "Second half".to_string(),
                    start_segment_id: 140,
                    end_segment_id: 279,
                    confidence: 0.8,
                },
            ],
            summary: ModelSummary {
                summary: "The episode unfolds in two halves.".to_string(),
                one_line_description: "A two-part episode".to_string(),
                claims: vec![
                    ModelClaim {
                        text: "The first half begins the episode.".to_string(),
                        evidence_segment_id: 0,
                    },
                    ModelClaim {
                        text: "The second half changes direction.".to_string(),
                        evidence_segment_id: 140,
                    },
                    ModelClaim {
                        text: "The final unit closes the episode.".to_string(),
                        evidence_segment_id: 279,
                    },
                ],
            },
        }
    }

    #[test]
    fn original_raw_id_out_of_range_in_unit_space_fails_before_remapping() {
        let original = dense_request();
        let prepared = prepare_analysis_request(&original).expect("request coalesces");
        let mut output = valid_unit_output();
        output.chapters[0].start_segment_id = original.segments[10].id;

        let violations = validate_and_remap_model_output(&original, &prepared, output)
            .expect_err("raw id must not bypass unit-space validation");

        assert!(violations
            .iter()
            .any(|violation| violation.rule == "id_discipline"));
    }

    #[test]
    fn valid_unit_output_maps_all_ids_and_validates_in_original_space() {
        let original = dense_request();
        let prepared = prepare_analysis_request(&original).expect("request coalesces");

        let validated = validate_and_remap_model_output(&original, &prepared, valid_unit_output())
            .expect("mapped output validates");

        assert_eq!(validated.chapters[0].start_segment_id, 10_000);
        assert_eq!(validated.chapters[0].end_segment_id, 11_398);
        assert_eq!(validated.chapters[1].start_segment_id, 11_400);
        assert_eq!(validated.chapters[1].end_segment_id, 12_798);
        assert_eq!(validated.chapters[0].start_time, 0.0);
        assert_eq!(validated.chapters[1].end_time, 1_400.0);
        assert_eq!(
            validated
                .summary
                .claims
                .iter()
                .map(|claim| claim.evidence_segment_id)
                .collect::<Vec<_>>(),
            vec![10_000, 11_400, 12_790]
        );
        assert!(validated.warnings.is_empty());
    }

    #[test]
    fn defensive_remap_length_mismatch_fails_id_discipline() {
        let original = dense_request();
        let mut prepared = prepare_analysis_request(&original).expect("request coalesces");
        prepared.remap.as_mut().expect("remap exists").pop();

        let violations = validate_and_remap_model_output(&original, &prepared, valid_unit_output())
            .expect_err("short remap must fail closed");

        assert!(violations
            .iter()
            .any(|violation| violation.rule == "id_discipline"));
    }
}

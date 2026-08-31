//! Deterministic worker-side segment coalescing for dense, long transcripts.
//!
//! The model's id-discipline cliff keys on the number of ids in the prompt,
//! not transcript duration or token count. Evaluation validated this greedy forward
//! pass on the 2,370-segment cbb fixture: 746 units cleared the cliff without
//! changing the byte-pinned prompt template. The raw request remains the
//! source of identity and returned artifacts; this module only prepares the
//! internal model-facing request and its unit-to-original-id remap.

use std::borrow::Cow;

use crate::types::{
    TranscriptAnalysisRequest, TranscriptMetadata, TranscriptSegment, MAX_MODEL_UNITS,
};

pub const COALESCING_TRIGGER_SEGMENT_COUNT: usize = 1_399;
pub const MIN_UNIT_SPAN_BEFORE_CLOSE: f64 = 5.0;
pub const UNIT_JOIN_CHAR_LIMIT: usize = 700;
pub const GAP_BREAK_SECONDS: f64 = 1.5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UnitRemap {
    pub original_start_id: i64,
    pub original_end_id: i64,
}

#[derive(Debug, PartialEq)]
pub struct PreparedAnalysisRequest<'a> {
    pub model_request: Cow<'a, TranscriptAnalysisRequest>,
    /// `None` is the byte-identical raw path. `Some` means model ids are
    /// zero-based unit indexes and must never escape responses.
    pub remap: Option<Vec<UnitRemap>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoalescingError {
    TooManyUnits,
}

/// Preserve the validated raw prompt exactly through the coalescing trigger.
/// Above it, replace only the segment list with deterministic units and
/// keep the original ids in a private remap.
pub fn prepare_analysis_request(
    original: &TranscriptAnalysisRequest,
) -> Result<PreparedAnalysisRequest<'_>, CoalescingError> {
    if original.segments.len() <= COALESCING_TRIGGER_SEGMENT_COUNT {
        return Ok(PreparedAnalysisRequest {
            model_request: Cow::Borrowed(original),
            remap: None,
        });
    }

    // Coalesce every request above 1,399 model-facing segments. The raw form
    // failed ID-discipline evaluation even with high thinking, while the
    // coalesced form restored every representative case at medium.
    let (segments, remap) = coalesce_segments(&original.segments);
    if segments.len() > MAX_MODEL_UNITS {
        return Err(CoalescingError::TooManyUnits);
    }

    let segment_count = segments.len();
    let request = TranscriptAnalysisRequest {
        schema_version: original.schema_version,
        async_supported: original.async_supported,
        request_id: original.request_id.clone(),
        episode_id: original.episode_id.clone(),
        podcast_id: original.podcast_id.clone(),
        episode_title: original.episode_title.clone(),
        podcast_title: original.podcast_title.clone(),
        transcript: TranscriptMetadata {
            language_code: original.transcript.language_code.clone(),
            audio_duration: original.transcript.audio_duration,
            model_identifier: original.transcript.model_identifier.clone(),
            model_version: original.transcript.model_version.clone(),
            model_tree_sha256: original.transcript.model_tree_sha256.clone(),
            fingerprint: original.transcript.fingerprint.clone(),
            updated_at: original.transcript.updated_at.clone(),
            state: original.transcript.state.clone(),
            segment_count,
        },
        segments,
    };
    Ok(PreparedAnalysisRequest {
        model_request: Cow::Owned(request),
        remap: Some(remap),
    })
}

struct OpenUnit {
    segment: TranscriptSegment,
    joined_character_count: usize,
    first_original_id: i64,
    last_original_id: i64,
    last_raw_end: f64,
}

impl OpenUnit {
    fn starting(segment: &TranscriptSegment) -> Self {
        Self {
            segment: TranscriptSegment {
                id: 0,
                start: segment.start,
                end: segment.end,
                text: segment.text.clone(),
            },
            joined_character_count: segment.text.chars().count(),
            first_original_id: segment.id,
            last_original_id: segment.id,
            last_raw_end: segment.end,
        }
    }

    fn closes_before(&self, next: &TranscriptSegment) -> bool {
        let spans_minimum = self.last_raw_end - self.segment.start >= MIN_UNIT_SPAN_BEFORE_CLOSE;
        let would_exceed_join_limit = self
            .joined_character_count
            .saturating_add(1)
            .saturating_add(next.text.chars().count())
            > UNIT_JOIN_CHAR_LIMIT;
        let breaks_on_gap = next.start - self.last_raw_end > GAP_BREAK_SECONDS;
        spans_minimum || would_exceed_join_limit || breaks_on_gap
    }

    fn extend(&mut self, segment: &TranscriptSegment) {
        self.last_original_id = segment.id;
        self.last_raw_end = segment.end;
        self.segment.end = segment.end;
        self.segment.text.push(' ');
        self.segment.text.push_str(&segment.text);
        self.joined_character_count = self
            .joined_character_count
            .saturating_add(1)
            .saturating_add(segment.text.chars().count());
    }

    fn close(mut self, unit_id: usize) -> (TranscriptSegment, UnitRemap) {
        self.segment.id = unit_id as i64;
        self.segment.end = self.segment.end.max(self.segment.start);
        (
            self.segment,
            UnitRemap {
                original_start_id: self.first_original_id,
                original_end_id: self.last_original_id,
            },
        )
    }
}

/// Reference algorithm: before adding each next segment, close the current
/// unit when it already spans at least 5 seconds, joining would exceed 700
/// characters, or the silence gap is greater than 1.5 seconds.
fn coalesce_segments(segments: &[TranscriptSegment]) -> (Vec<TranscriptSegment>, Vec<UnitRemap>) {
    let mut units = Vec::new();
    let mut remap = Vec::new();
    let mut segments = segments.iter();
    let Some(first) = segments.next() else {
        return (units, remap);
    };
    let mut current = OpenUnit::starting(first);

    for segment in segments {
        if current.closes_before(segment) {
            let (closed, closed_remap) = current.close(units.len());
            units.push(closed);
            remap.push(closed_remap);
            current = OpenUnit::starting(segment);
        } else {
            current.extend(segment);
        }
    }

    let (closed, closed_remap) = current.close(units.len());
    units.push(closed);
    remap.push(closed_remap);
    (units, remap)
}

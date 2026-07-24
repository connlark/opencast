//! Final publication gate for remote transcript results. This intentionally
//! mirrors the iOS mapper's defense-in-depth checks so malformed model or
//! stitch output never becomes `result_ready` in the first place.

use crate::stitch::{self, StitchedTranscript};
use crate::types::SCHEMA_VERSION;

const TIMING_TOLERANCE_SECONDS: f64 = 0.5;

pub struct ResultVerificationContext<'a> {
    pub schema_version: u32,
    pub source_sha256: &'a str,
    pub source_byte_count: i64,
    pub expected_source_sha256: &'a str,
    pub expected_source_byte_count: i64,
    pub duration_seconds: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResultVerificationError {
    UnsupportedSchema,
    SourceIdentityMismatch,
    InvalidDuration,
    EmptyTranscript,
    InvalidTimings,
    SegmentTextMismatch,
    TranscriptTextMismatch,
    NormalizedHashMismatch,
}

pub fn verify(
    transcript: &StitchedTranscript,
    context: &ResultVerificationContext<'_>,
) -> Result<(), ResultVerificationError> {
    if context.schema_version > SCHEMA_VERSION {
        return Err(ResultVerificationError::UnsupportedSchema);
    }
    if !context
        .source_sha256
        .eq_ignore_ascii_case(context.expected_source_sha256)
        || context.source_byte_count != context.expected_source_byte_count
    {
        return Err(ResultVerificationError::SourceIdentityMismatch);
    }
    if !context.duration_seconds.is_finite() || context.duration_seconds <= 0.0 {
        return Err(ResultVerificationError::InvalidDuration);
    }
    if transcript.segments.is_empty() {
        return Err(ResultVerificationError::EmptyTranscript);
    }

    let upper_bound = context.duration_seconds + TIMING_TOLERANCE_SECONDS;
    let mut previous_segment_start = f64::NEG_INFINITY;
    let mut previous_word_start = f64::NEG_INFINITY;
    let mut words = Vec::new();
    for segment in &transcript.segments {
        if !segment.start.is_finite()
            || !segment.end.is_finite()
            || segment.start < 0.0
            || segment.end < segment.start
            || segment.end > upper_bound
            || segment.start + 0.001 < previous_segment_start
        {
            return Err(ResultVerificationError::InvalidTimings);
        }
        previous_segment_start = segment.start;
        let rebuilt_segment_text = segment
            .words
            .iter()
            .map(|word| word.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        if segment.text != rebuilt_segment_text {
            return Err(ResultVerificationError::SegmentTextMismatch);
        }
        for word in &segment.words {
            if word.text.trim().is_empty() {
                return Err(ResultVerificationError::EmptyTranscript);
            }
            if !word.start.is_finite()
                || !word.end.is_finite()
                || word.start < 0.0
                || word.end < word.start
                || word.end > upper_bound
                || word.start + 0.001 < previous_word_start
            {
                return Err(ResultVerificationError::InvalidTimings);
            }
            previous_word_start = word.start;
            words.push(word.text.as_str());
        }
    }
    if words.is_empty() {
        return Err(ResultVerificationError::EmptyTranscript);
    }

    let rebuilt_text = words.join(" ");
    if transcript.text != rebuilt_text {
        return Err(ResultVerificationError::TranscriptTextMismatch);
    }
    if stitch::normalized_transcript_sha256(&rebuilt_text)
        != transcript.normalized_transcript_sha256
    {
        return Err(ResultVerificationError::NormalizedHashMismatch);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stitch::{ModelWord, StitchedSegment};

    fn transcript() -> StitchedTranscript {
        let text = "hello world".to_string();
        StitchedTranscript {
            segments: vec![StitchedSegment {
                id: 0,
                start: 0.0,
                end: 1.0,
                text: text.clone(),
                words: vec![
                    ModelWord {
                        text: "hello".into(),
                        start: 0.0,
                        end: 0.4,
                    },
                    ModelWord {
                        text: "world".into(),
                        start: 0.5,
                        end: 1.0,
                    },
                ],
            }],
            normalized_transcript_sha256: stitch::normalized_transcript_sha256(&text),
            text,
            word_count: 2,
            deduplicated_word_count: 0,
            interval_trimmed_word_count: 0,
            empty_model_word_count: 0,
            reversed_timing_word_count: 0,
        }
    }

    fn context() -> ResultVerificationContext<'static> {
        ResultVerificationContext {
            schema_version: SCHEMA_VERSION,
            source_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            source_byte_count: 42,
            expected_source_sha256:
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            expected_source_byte_count: 42,
            duration_seconds: 2.0,
        }
    }

    #[test]
    fn accepts_a_complete_app_verifiable_result() {
        assert_eq!(verify(&transcript(), &context()), Ok(()));
    }

    #[test]
    fn rejects_identity_duration_and_schema_failures() {
        let mut invalid_context = context();
        invalid_context.source_byte_count += 1;
        assert_eq!(
            verify(&transcript(), &invalid_context),
            Err(ResultVerificationError::SourceIdentityMismatch)
        );

        invalid_context = context();
        invalid_context.duration_seconds = f64::NAN;
        assert_eq!(
            verify(&transcript(), &invalid_context),
            Err(ResultVerificationError::InvalidDuration)
        );

        invalid_context = context();
        invalid_context.schema_version = SCHEMA_VERSION + 1;
        assert_eq!(
            verify(&transcript(), &invalid_context),
            Err(ResultVerificationError::UnsupportedSchema)
        );
    }

    #[test]
    fn rejects_empty_nonmonotonic_and_out_of_bounds_words() {
        let mut invalid = transcript();
        invalid.segments.clear();
        assert_eq!(
            verify(&invalid, &context()),
            Err(ResultVerificationError::EmptyTranscript)
        );

        invalid = transcript();
        invalid.segments[0].words[1].start = -0.1;
        assert_eq!(
            verify(&invalid, &context()),
            Err(ResultVerificationError::InvalidTimings)
        );

        invalid = transcript();
        invalid.segments[0].words[1].end = 2.6;
        assert_eq!(
            verify(&invalid, &context()),
            Err(ResultVerificationError::InvalidTimings)
        );

        invalid = transcript();
        invalid.segments[0].words[0].text = " ".into();
        invalid.segments[0].text = "  world".into();
        invalid.text = "  world".into();
        assert_eq!(
            verify(&invalid, &context()),
            Err(ResultVerificationError::EmptyTranscript)
        );
    }

    #[test]
    fn rejects_nonmonotonic_segments() {
        let mut invalid = transcript();
        invalid.segments[0].start = 0.5;
        let mut second = invalid.segments[0].clone();
        second.id = 1;
        second.start = 0.4;
        second.words[0].start = 1.1;
        second.words[0].end = 1.3;
        second.words[1].start = 1.4;
        second.words[1].end = 1.6;
        invalid.segments.push(second);
        invalid.text = "hello world hello world".into();
        invalid.normalized_transcript_sha256 =
            stitch::normalized_transcript_sha256(&invalid.text);

        assert_eq!(
            verify(&invalid, &context()),
            Err(ResultVerificationError::InvalidTimings)
        );
    }

    #[test]
    fn rejects_text_and_hash_inconsistency() {
        let mut invalid = transcript();
        invalid.segments[0].text = "different".into();
        assert_eq!(
            verify(&invalid, &context()),
            Err(ResultVerificationError::SegmentTextMismatch)
        );

        invalid = transcript();
        invalid.text = "different".into();
        assert_eq!(
            verify(&invalid, &context()),
            Err(ResultVerificationError::TranscriptTextMismatch)
        );

        invalid = transcript();
        invalid.normalized_transcript_sha256 = "0".repeat(64);
        assert_eq!(
            verify(&invalid, &context()),
            Err(ResultVerificationError::NormalizedHashMismatch)
        );
    }

    #[test]
    fn every_accepted_adversarial_stitch_variant_passes_the_gate() {
        use crate::stitch::{ChunkTranscription, ModelSegment, ModelWord};

        let mut accepted = 0;
        for first_segment_start in [0.0, 0.8, 8.0] {
            for second_segment_start in [0.0, 0.7, 8.0] {
                for backward_drift in [0.0, 0.0005] {
                    let chunks = vec![ChunkTranscription {
                        requested_start_seconds: 0.0,
                        valid_end_seconds: 4.0,
                        segments: vec![
                            ModelSegment {
                                start: first_segment_start,
                                end: 0.6,
                                text: String::new(),
                                words: vec![
                                    ModelWord {
                                        text: "alpha".into(),
                                        start: 0.0,
                                        end: 0.4,
                                    },
                                    ModelWord {
                                        text: " \t ".into(),
                                        start: 0.45,
                                        end: 0.5,
                                    },
                                    ModelWord {
                                        text: "reversed".into(),
                                        start: 0.55,
                                        end: 0.5,
                                    },
                                ],
                            },
                            ModelSegment {
                                start: second_segment_start,
                                end: 1.0,
                                text: String::new(),
                                words: vec![ModelWord {
                                    text: "beta".into(),
                                    start: 0.4 - backward_drift,
                                    end: 1.0,
                                }],
                            },
                        ],
                    }];

                    if let Ok(stitched) = stitch::stitch(&chunks, 2.0, 4.0) {
                        accepted += 1;
                        let mut verification_context = context();
                        verification_context.duration_seconds = 4.0;
                        assert_eq!(
                            verify(&stitched, &verification_context),
                            Ok(()),
                            "first_segment_start={first_segment_start} second_segment_start={second_segment_start} backward_drift={backward_drift}"
                        );
                    }
                }
            }
        }
        assert_eq!(accepted, 18);
    }
}

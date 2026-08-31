use opencast_transcript_analysis_worker::coalescing::{
    prepare_analysis_request, CoalescingError, GAP_BREAK_SECONDS, MIN_UNIT_SPAN_BEFORE_CLOSE,
    UNIT_JOIN_CHAR_LIMIT,
};
use opencast_transcript_analysis_worker::prompt::build_prompt;
use opencast_transcript_analysis_worker::types::{
    TranscriptAnalysisRequest, TranscriptMetadata, TranscriptSegment,
};
use opencast_transcript_analysis_worker::validation::validate_request;

fn request_with(segments: Vec<TranscriptSegment>) -> TranscriptAnalysisRequest {
    let count = segments.len();
    let duration = segments.last().map_or(1.0, |segment| segment.end);
    TranscriptAnalysisRequest {
        schema_version: 1,
        async_supported: false,
        request_id: "coalescing-test".to_string(),
        episode_id: "episode".to_string(),
        podcast_id: "podcast".to_string(),
        episode_title: Some("Episode".to_string()),
        podcast_title: Some("Podcast".to_string()),
        transcript: TranscriptMetadata {
            language_code: "en".to_string(),
            audio_duration: duration,
            model_identifier: None,
            model_version: None,
            model_tree_sha256: None,
            fingerprint: "raw-fingerprint".to_string(),
            updated_at: "2026-08-23T00:00:00Z".to_string(),
            state: "completed".to_string(),
            segment_count: count,
        },
        segments,
    }
}

fn dense_segments(count: usize) -> Vec<TranscriptSegment> {
    (0..count)
        .map(|index| TranscriptSegment {
            id: 10_000 + index as i64 * 2,
            start: index as f64,
            end: (index + 1) as f64,
            text: format!("word-{index}"),
        })
        .collect()
}

#[test]
fn raw_envelope_is_byte_identical_and_has_no_remap() {
    let request = request_with(dense_segments(1_399));
    let prompt_before = build_prompt(&request);

    let prepared = prepare_analysis_request(&request).expect("raw request prepares");

    assert_eq!(prepared.model_request.as_ref(), &request);
    assert_eq!(build_prompt(prepared.model_request.as_ref()), prompt_before);
    assert!(prepared.remap.is_none());
}

#[test]
fn greedy_span_rule_coalesces_and_records_original_ids() {
    assert_eq!(MIN_UNIT_SPAN_BEFORE_CLOSE, 5.0);
    let request = request_with(dense_segments(1_400));

    let prepared = prepare_analysis_request(&request).expect("dense request coalesces");
    let remap = prepared.remap.expect("long request has remap");

    assert_eq!(prepared.model_request.segments.len(), 280);
    assert_eq!(remap.len(), prepared.model_request.segments.len());
    assert_eq!(prepared.model_request.transcript.segment_count, 280);
    assert_eq!(
        prepared.model_request.transcript.fingerprint,
        "raw-fingerprint"
    );
    assert_eq!(prepared.model_request.segments[0].id, 0);
    assert_eq!(prepared.model_request.segments[0].start, 0.0);
    assert_eq!(prepared.model_request.segments[0].end, 5.0);
    assert_eq!(
        prepared.model_request.segments[0].text,
        "word-0 word-1 word-2 word-3 word-4"
    );
    assert_eq!(remap[0].original_start_id, 10_000);
    assert_eq!(remap[0].original_end_id, 10_008);
    assert_eq!(remap[279].original_start_id, 12_790);
    assert_eq!(remap[279].original_end_id, 12_798);
    assert_eq!(
        remap.last().expect("tail mapping"),
        &opencast_transcript_analysis_worker::coalescing::UnitRemap {
            original_start_id: request.segments[1_395].id,
            original_end_id: request.segments[1_399].id,
        }
    );
    // Preparation never rewrites the caller's raw identity/content bytes.
    assert_eq!(request.segments.len(), 1_400);
    assert_eq!(request.transcript.segment_count, 1_400);
}

#[test]
fn character_and_silence_guards_close_before_the_next_segment() {
    assert_eq!(UNIT_JOIN_CHAR_LIMIT, 700);
    assert_eq!(GAP_BREAK_SECONDS, 1.5);
    let mut segments = dense_segments(1_400);
    // Keep the first unit below five seconds so the character guard is the
    // only reason segment 1 cannot join segment 0.
    segments[0].start = 0.0;
    segments[0].end = 0.5;
    segments[0].text = "x".repeat(699);
    segments[1].start = 0.5;
    segments[1].end = 1.0;
    segments[1].text = "y".to_string();
    // A gap of exactly 1.5 seconds stays mergeable; greater than 1.5 breaks.
    segments[2].start = 2.5;
    segments[2].end = 3.0;
    segments[3].start = 4.5001;
    segments[3].end = 5.0;
    for (index, segment) in segments.iter_mut().enumerate().skip(4) {
        segment.start = 5.0 + index as f64;
        segment.end = segment.start + 1.0;
    }

    let request = request_with(segments);
    let prepared = prepare_analysis_request(&request).expect("guard fixture coalesces");
    let remap = prepared.remap.expect("long request has remap");

    assert_eq!(remap[0].original_start_id, 10_000);
    assert_eq!(remap[0].original_end_id, 10_000);
    assert_eq!(remap[1].original_start_id, 10_002);
    assert_eq!(remap[1].original_end_id, 10_004);
    assert_eq!(remap[2].original_start_id, 10_006);
}

#[test]
fn exactly_2400_model_units_are_accepted_and_2401_are_typed_too_long() {
    let make_segments = |count| {
        (0..count)
            .map(|index| TranscriptSegment {
                id: index as i64,
                start: index as f64 * 10.0,
                end: index as f64 * 10.0 + 5.0,
                text: "one independently long segment".to_string(),
            })
            .collect::<Vec<_>>()
    };

    let accepted_request = request_with(make_segments(2_400));
    let accepted =
        prepare_analysis_request(&accepted_request).expect("2,400 model units are accepted");
    assert_eq!(accepted.model_request.segments.len(), 2_400);

    assert_eq!(
        prepare_analysis_request(&request_with(make_segments(2_401))),
        Err(CoalescingError::TooManyUnits)
    );
}

#[test]
fn prospective_join_limit_counts_unicode_scalars_not_utf8_bytes() {
    let mut segments = dense_segments(1_400);
    segments[0].start = 0.0;
    segments[0].end = 0.5;
    segments[0].text = "é".repeat(400);
    segments[1].start = 0.5;
    segments[1].end = 1.0;
    segments[1].text = "y".to_string();
    segments[2].start = 2.5001;
    segments[2].end = 3.0;

    let request = request_with(segments);
    let prepared = prepare_analysis_request(&request).expect("unicode request coalesces");
    let remap = prepared.remap.expect("long request has remap");

    assert_eq!(remap[0].original_start_id, 10_000);
    assert_eq!(remap[0].original_end_id, 10_002);
    assert_eq!(prepared.model_request.segments[0].text.chars().count(), 402);
    assert!(prepared.model_request.segments[0].text.len() > UNIT_JOIN_CHAR_LIMIT);
}

#[test]
fn legal_raw_segment_above_join_limit_stays_intact_and_unsplit() {
    let mut segments = dense_segments(1_400);
    let oversized_for_join = "界".repeat(701);
    segments[0].start = 0.0;
    segments[0].end = 0.5;
    segments[0].text = oversized_for_join.clone();
    segments[1].start = 0.5;
    segments[1].end = 1.0;

    let request = request_with(segments);
    let prepared = prepare_analysis_request(&request).expect("long segment remains legal");
    let remap = prepared.remap.expect("long request has remap");

    assert_eq!(prepared.model_request.segments[0].text, oversized_for_join);
    assert_eq!(prepared.model_request.segments[0].text.chars().count(), 701);
    assert_eq!(remap[0].original_start_id, 10_000);
    assert_eq!(remap[0].original_end_id, 10_000);
}

#[test]
fn backwards_drifting_legal_raw_times_never_invert_emitted_units() {
    let segments = (0..1_400)
        .map(|index| {
            let timestamp = 10.0 - index as f64 * 0.0005;
            TranscriptSegment {
                id: index as i64,
                start: timestamp,
                end: timestamp,
                text: "x".to_string(),
            }
        })
        .collect();

    let request = request_with(segments);
    assert!(validate_request(request.clone()).is_ok());
    let prepared =
        prepare_analysis_request(&request).expect("sub-millisecond overlap stays coalescible");
    let remap = prepared.remap.expect("long request has remap");

    assert_eq!(remap.len(), prepared.model_request.segments.len());
    assert!(prepared
        .model_request
        .segments
        .iter()
        .all(|unit| unit.end >= unit.start));
    assert_eq!(remap[0].original_start_id, 0);
    assert!(remap[0].original_end_id > 0);
}

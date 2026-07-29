use opencast_ad_analysis_worker::types::{
    AdAnalysisRequest, AdSpanKind, TranscriptMetadata, TranscriptSegment,
    APP_ATTEST_KEY_DAILY_ESTIMATED_INPUT_TOKEN_CAP, APP_ATTEST_KEY_DAILY_REQUEST_CAP,
    BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP, BEARER_DAILY_REQUEST_CAP,
    GLOBAL_DAILY_ESTIMATED_INPUT_TOKEN_CAP, GLOBAL_DAILY_REQUEST_CAP,
    MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES, MAX_BODY_BYTES, MAX_SEGMENTS, MAX_SEGMENT_TEXT_CHARS,
    MAX_TRANSCRIPT_TEXT_CHARS, SCHEMA_VERSION,
};
use opencast_ad_analysis_worker::usage::{
    global_usage_object_name, usage_object_name, UsageLimitProfile,
};
use opencast_ad_analysis_worker::validation::{
    decode_and_validate_request, validate_content_length, validate_model_output, validate_request,
    CapError, ContentLengthError, DailyUsage, ModelOutput, ModelSpan, ValidationError,
    AD_BUDGET_EPISODE_FRACTION, AD_BUDGET_FLOOR_SECONDS, EVIDENCE_MIN_WORDS_ACCEPT,
    EVIDENCE_MIN_WORDS_REANCHOR, EVIDENCE_PROBE_WORDS, MAX_RAW_SPANS_PER_WINDOW,
    MAX_SPAN_DURATION_SECONDS, MAX_SPAN_REQUEST_COVERAGE, MIN_BREAK_DURATION_SECONDS,
};

#[test]
fn validates_completed_segment_payload() {
    let request = sample_request();
    let validated = validate_request(request).expect("request should validate");

    assert_eq!(validated.estimate.transcript_text_chars, 56);
    assert!(validated.estimate.estimated_input_tokens > 0);
}

#[test]
fn async_supported_defaults_false_and_parses_true() {
    let mut value = serde_json::to_value(sample_request()).expect("request serializes");
    value
        .as_object_mut()
        .expect("request object")
        .remove("async_supported");
    let encoded = serde_json::to_vec(&value).expect("request encodes");
    let decoded = decode_and_validate_request(&encoded).expect("legacy request validates");
    assert!(!decoded.request.async_supported);

    value["async_supported"] = serde_json::Value::Bool(true);
    let encoded = serde_json::to_vec(&value).expect("request encodes");
    let decoded = decode_and_validate_request(&encoded).expect("opt-in request validates");
    assert!(decoded.request.async_supported);
}

#[test]
fn rejects_invalid_payloads_before_model_call() {
    let mut request = sample_request();
    request.transcript.state = "running".to_string();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::TranscriptNotCompleted
    );

    let mut request = sample_request();
    request.segments[1].id = request.segments[0].id;
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::DuplicateSegmentID(100)
    );

    let mut request = sample_request();
    request.segments[1].start = 0.5;
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::NonMonotonicSegments(101)
    );
}

#[test]
fn rejects_empty_identity_and_invalid_transcript_metadata_before_model_call() {
    let mut request = sample_request();
    request.episode_id = " \n\t ".to_string();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::EmptyEpisodeID
    );

    let mut request = sample_request();
    request.podcast_id = " ".to_string();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::EmptyPodcastID
    );

    let mut request = sample_request();
    request.transcript.language_code = " ".to_string();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::InvalidTranscriptMetadata
    );

    let mut request = sample_request();
    request.transcript.fingerprint = " ".to_string();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::InvalidTranscriptMetadata
    );

    let mut request = sample_request();
    request.transcript.updated_at = " ".to_string();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::InvalidTranscriptMetadata
    );

    let mut request = sample_request();
    request.transcript.audio_duration = 0.0;
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::InvalidTranscriptMetadata
    );

    let mut request = sample_request();
    request.transcript.audio_duration = f64::NAN;
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::InvalidTranscriptMetadata
    );
}

#[test]
fn rejects_contract_and_size_guardrails_before_model_call() {
    let mut request = sample_request();
    request.schema_version = SCHEMA_VERSION + 1;
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::UnsupportedSchemaVersion
    );

    let mut request = sample_request();
    request.request_id = "  ".to_string();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::EmptyRequestID
    );

    let mut request = sample_request();
    request.transcript.segment_count -= 1;
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::SegmentCountMismatch
    );

    let mut request = sample_request();
    request.segments.clear();
    request.transcript.segment_count = 0;
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::EmptySegments
    );

    let mut request = sample_request();
    request.segments = (0..=MAX_SEGMENTS)
        .map(|index| TranscriptSegment {
            id: index as i64,
            start: index as f64,
            end: index as f64 + 1.0,
            text: "promo".to_string(),
        })
        .collect();
    request.transcript.segment_count = request.segments.len();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::SegmentCountExceeded
    );

    let mut request = sample_request();
    request.segments[0].text = " \n\t ".to_string();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::EmptySegmentText(100)
    );

    let mut request = sample_request();
    request.segments[0].text = "a".repeat(MAX_SEGMENT_TEXT_CHARS + 1);
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::SegmentTextTooLarge(100)
    );

    let mut request = sample_request();
    request.segments[0].end = request.segments[0].start - 0.1;
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::InvalidSegmentTiming(100)
    );

    let mut request = sample_request();
    let segment_count = (MAX_TRANSCRIPT_TEXT_CHARS / MAX_SEGMENT_TEXT_CHARS) + 1;
    request.segments = (0..segment_count)
        .map(|index| TranscriptSegment {
            id: index as i64,
            start: index as f64,
            end: index as f64 + 1.0,
            text: "a".repeat(MAX_SEGMENT_TEXT_CHARS),
        })
        .collect();
    request.transcript.segment_count = request.segments.len();
    assert_eq!(
        validate_request(request).unwrap_err(),
        ValidationError::TranscriptTextTooLarge
    );
}

#[test]
fn envelope_body_cap_admits_any_bearer_size_payload_after_json_escaping() {
    assert!(MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES >= 2 * MAX_BODY_BYTES + 8 * 1024);
}

#[test]
fn oversized_body_maps_to_payload_too_large() {
    let body = vec![b' '; MAX_BODY_BYTES + 1];
    let error = decode_and_validate_request(&body).unwrap_err();

    assert_eq!(error, ValidationError::BodyTooLarge);
    assert_eq!(error.code(), "body_too_large");
    assert_eq!(error.http_status(), 413);
    assert_eq!(ValidationError::MalformedJson.http_status(), 400);
}

#[test]
fn malformed_json_is_rejected_before_model_call() {
    let error = decode_and_validate_request(br#"{"schema_version":"not-an-int"}"#).unwrap_err();

    assert_eq!(error, ValidationError::MalformedJson);
    assert_eq!(error.code(), "malformed_json");
    assert_eq!(error.http_status(), 400);
}

// ---------------------------------------------------------------------------
// promo_ad_breaks_v2 model-output validation
// ---------------------------------------------------------------------------

#[test]
fn structural_constants_match_the_step4_contract() {
    assert_eq!(MAX_SPAN_DURATION_SECONDS, 600.0);
    assert_eq!(MIN_BREAK_DURATION_SECONDS, 15.0);
    assert_eq!(MAX_SPAN_REQUEST_COVERAGE, 0.8);
    assert_eq!(AD_BUDGET_EPISODE_FRACTION, 0.25);
    assert_eq!(AD_BUDGET_FLOOR_SECONDS, 600.0);
    assert_eq!(EVIDENCE_PROBE_WORDS, 6);
    assert_eq!(EVIDENCE_MIN_WORDS_ACCEPT, 2);
    assert_eq!(EVIDENCE_MIN_WORDS_REANCHOR, 3);
    assert_eq!(MAX_RAW_SPANS_PER_WINDOW, 32);
}

#[test]
fn spend_caps_match_the_15_dollar_day_table() {
    assert_eq!(GLOBAL_DAILY_REQUEST_CAP, 300);
    assert_eq!(GLOBAL_DAILY_ESTIMATED_INPUT_TOKEN_CAP, 8_000_000);
    assert_eq!(BEARER_DAILY_REQUEST_CAP, 40);
    assert_eq!(BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP, 2_000_000);
    assert_eq!(APP_ATTEST_KEY_DAILY_REQUEST_CAP, 12);
    assert_eq!(APP_ATTEST_KEY_DAILY_ESTIMATED_INPUT_TOKEN_CAP, 1_500_000);
}

#[test]
fn anchored_spans_validate_and_adjacent_same_kind_spans_merge() {
    let request = output_request();
    let output = ModelOutput::from_spans(vec![
        span(
            AdSpanKind::HostReadAd,
            "Acme Mattress",
            101,
            102,
            0.9,
            "brought to you by Acme Mattress",
        ),
        span(
            AdSpanKind::HostReadAd,
            "Acme disclaimer",
            103,
            103,
            0.8,
            "ask your doctor",
        ),
        span(AdSpanKind::InsertedAd, "Unknown", 999, 999, 0.5, "bad"),
    ]);

    let (spans, warnings) = validate_model_output(&request, output);

    assert_eq!(spans.len(), 1);
    assert_eq!(spans[0].kind, AdSpanKind::HostReadAd);
    assert_eq!(spans[0].start_segment_id, 101);
    assert_eq!(spans[0].end_segment_id, 103);
    assert_eq!(spans[0].start_time, 10.0);
    assert_eq!(spans[0].end_time, 40.0);
    assert!(spans[0].label.contains("Acme Mattress"));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("unknown start")));
    assert!(warnings.iter().any(|warning| warning.contains("merged")));
}

#[test]
fn evidence_quote_anchors_within_the_span_or_the_span_is_dropped() {
    let request = output_request();

    // Quote appearing only outside the span at MULTIPLE locations: dropped.
    let (spans, warnings) = validate_model_output(
        &request,
        ModelOutput::from_spans(vec![span(
            AdSpanKind::HouseOrNetworkPromo,
            "Resume promo",
            101,
            102,
            0.9,
            "back to our regular discussion about the championship",
        )]),
    );
    assert!(spans.is_empty());
    assert!(warnings.contains(&"evidence_out_of_span:101-102".to_string()));

    // Quote under two normalized words carries no anchor: dropped.
    let (spans, warnings) = validate_model_output(
        &request,
        ModelOutput::from_spans(vec![span(
            AdSpanKind::HostReadAd,
            "One word",
            101,
            102,
            0.9,
            "Acme!",
        )]),
    );
    assert!(spans.is_empty());
    assert!(warnings.contains(&"evidence_missing:101-102".to_string()));

    // Two-word quotes accept in-span (measured: 3.5-flash quotes "gambling
    // problem" for a real disclaimer pod).
    let (spans, _) = validate_model_output(
        &request,
        ModelOutput::from_spans(vec![span(
            AdSpanKind::HostReadAd,
            "Acme",
            101,
            103,
            0.9,
            "Acme Mattress",
        )]),
    );
    assert_eq!(spans.len(), 1);
}

#[test]
fn uniquely_anchored_out_of_span_quote_shifts_the_span() {
    let request = output_request();
    // The model reported the Beta Coffee read with IDs drifted by -6 (the
    // measured 3.1-flash-lite uniform-drift failure mode).
    let output = ModelOutput::from_spans(vec![span(
        AdSpanKind::InsertedAd,
        "Beta Coffee",
        101,
        102,
        0.9,
        "Visit beta coffee dot com slash show for a free bag",
    )]);

    let (spans, warnings) = validate_model_output(&request, output);

    assert_eq!(spans.len(), 1);
    assert_eq!(spans[0].start_segment_id, 107);
    assert_eq!(spans[0].end_segment_id, 108);
    assert_eq!(spans[0].start_time, 70.0);
    assert_eq!(spans[0].end_time, 90.0);
    assert!(warnings.contains(&"evidence_reanchored:101-102->107-108".to_string()));
}

#[test]
fn both_unknown_ids_rescue_as_seconds_when_evidence_anchors_inside() {
    // Measured production failure (§4c ID/seconds confusion): the model
    // returns the break's start/end as SECONDS in the ID fields. output_request
    // has 10 x 10s segments (ids 100-109); the Beta Coffee read spans segments
    // 106-108 (60-90s). A span reported as 61-91 "seconds" with a uniquely
    // anchored quote must map back onto those segments.
    let request = output_request();
    let output = ModelOutput::from_spans(vec![span(
        AdSpanKind::InsertedAd,
        "Beta Coffee",
        61,
        91,
        0.9,
        "Visit beta coffee dot com slash show",
    )]);

    let (spans, warnings) = validate_model_output(&request, output);

    assert_eq!(spans.len(), 1);
    assert_eq!(spans[0].start_segment_id, 106);
    assert_eq!(spans[0].end_segment_id, 108);
    assert_eq!(spans[0].start_time, 60.0);
    assert_eq!(spans[0].end_time, 90.0);
    assert!(warnings.contains(&"ids_reinterpreted_as_seconds:61-91->106-108".to_string()));
}

#[test]
fn seconds_rescue_refuses_weak_signals() {
    let request = output_request();

    // Times beyond the audio duration: no rescue.
    let (spans, warnings) = validate_model_output(
        &request,
        ModelOutput::from_spans(vec![span(
            AdSpanKind::InsertedAd,
            "Garbage ids",
            5_000,
            6_000,
            0.9,
            "Visit beta coffee dot com slash show",
        )]),
    );
    assert!(spans.is_empty());
    assert!(warnings.contains(&"dropped span with unknown start segment 5000".to_string()));

    // Ambiguous quote (occurs twice): no rescue.
    let (spans, warnings) = validate_model_output(
        &request,
        ModelOutput::from_spans(vec![span(
            AdSpanKind::InsertedAd,
            "Ambiguous",
            61,
            91,
            0.9,
            "back to our regular discussion about the championship",
        )]),
    );
    assert!(spans.is_empty());
    assert!(warnings.contains(&"dropped span with unknown start segment 61".to_string()));

    // Quote anchoring outside the mapped window: no rescue.
    let (spans, warnings) = validate_model_output(
        &request,
        ModelOutput::from_spans(vec![span(
            AdSpanKind::InsertedAd,
            "Anchor outside window",
            61,
            91,
            0.9,
            "This episode is brought to you by Acme Mattress",
        )]),
    );
    assert!(spans.is_empty());
    assert!(warnings.contains(&"dropped span with unknown start segment 61".to_string()));

    // One unknown boundary: never rescued.
    let (spans, warnings) = validate_model_output(
        &request,
        ModelOutput::from_spans(vec![span(
            AdSpanKind::InsertedAd,
            "One unknown",
            106,
            9_999,
            0.9,
            "Visit beta coffee dot com slash show",
        )]),
    );
    assert!(spans.is_empty());
    assert!(warnings.contains(&"dropped span with unknown end segment 9999".to_string()));
}

#[test]
fn two_word_quotes_do_not_reanchor() {
    let request = output_request();
    // "free bag" occurs uniquely at segment 107, but a two-word probe must
    // never drive a shift — re-anchoring requires three normalized words.
    let output = ModelOutput::from_spans(vec![span(
        AdSpanKind::InsertedAd,
        "Free bag",
        100,
        100,
        0.9,
        "free bag",
    )]);

    let (spans, warnings) = validate_model_output(&request, output);

    assert!(spans.is_empty());
    assert!(warnings.contains(&"evidence_out_of_span:100-100".to_string()));
}

#[test]
fn overlong_spans_and_request_covering_spans_are_dropped() {
    // 64 segments x 20s: a 32-segment span is 640s > 600s.
    let request = wide_request(64, 20.0);
    let output = ModelOutput::from_spans(vec![span(
        AdSpanKind::InsertedAd,
        "Whole block",
        0,
        31,
        0.9,
        "segment 3 unique pepper marker three",
    )]);
    let (spans, warnings) = validate_model_output(&request, output);
    assert!(spans.is_empty());
    assert!(warnings.contains(&"span_too_long:0-31".to_string()));

    // 64 segments x 5s: a 60-segment span is 300s (under the duration cap)
    // but covers 94% of the request.
    let request = wide_request(64, 5.0);
    let output = ModelOutput::from_spans(vec![span(
        AdSpanKind::InsertedAd,
        "Whole window",
        0,
        59,
        0.9,
        "segment 3 unique pepper marker three",
    )]);
    let (spans, warnings) = validate_model_output(&request, output);
    assert!(spans.is_empty());
    assert!(warnings.contains(&"span_covers_request:0-59".to_string()));
}

#[test]
fn sub_15_second_merged_spans_are_dropped_as_too_short() {
    let request = output_request();
    // A single 10s segment cannot be a complete ad break (measured junk
    // class: 1-12s self-quoting banter singles).
    let output = ModelOutput::from_spans(vec![span(
        AdSpanKind::HostReadAd,
        "Tiny island",
        101,
        101,
        0.9,
        "brought to you by Acme Mattress",
    )]);

    let (spans, warnings) = validate_model_output(&request, output);

    assert!(spans.is_empty());
    assert!(warnings.contains(&"span_too_short:101-101".to_string()));
}

#[test]
fn episode_ad_budget_drops_lowest_confidence_spans_first() {
    // 200 segments x 20s = 4000s audio => budget max(1000, 600) = 1000s.
    // Four 300s spans total 1200s; the 0.7-confidence one must die.
    let request = wide_request(200, 20.0);
    let output = ModelOutput::from_spans(vec![
        span(
            AdSpanKind::HostReadAd,
            "First",
            0,
            14,
            0.9,
            "segment 0 unique pepper marker zero",
        ),
        span(
            AdSpanKind::InsertedAd,
            "Second",
            50,
            64,
            0.95,
            "segment 50 unique pepper marker fifty",
        ),
        span(
            AdSpanKind::HostReadAd,
            "Third",
            100,
            114,
            0.7,
            "segment 100 unique pepper marker hundred",
        ),
        span(
            AdSpanKind::InsertedAd,
            "Fourth",
            150,
            164,
            0.99,
            "segment 150 unique pepper marker onefifty",
        ),
    ]);

    let (spans, warnings) = validate_model_output(&request, output);

    assert_eq!(spans.len(), 3);
    assert!(spans.iter().all(|span| span.start_segment_id != 100));
    assert!(warnings.contains(&"ad_budget_exceeded:100-114".to_string()));
}

#[test]
fn degenerate_span_counts_yield_empty_results() {
    let request = output_request();
    let make_spans = |count: usize| {
        ModelOutput::from_spans(
            (0..count)
                .map(|index| {
                    span(
                        AdSpanKind::HostReadAd,
                        &format!("Span {index}"),
                        101,
                        102,
                        0.9,
                        "brought to you by Acme Mattress",
                    )
                })
                .collect(),
        )
    };

    let (spans, warnings) = validate_model_output(&request, make_spans(33));
    assert!(spans.is_empty());
    assert_eq!(warnings, vec!["degenerate_span_count:33".to_string()]);

    // Malformed spans count toward degeneracy.
    let mut output = make_spans(20);
    output.malformed_span_count = 13;
    let (spans, warnings) = validate_model_output(&request, output);
    assert!(spans.is_empty());
    assert_eq!(warnings, vec!["degenerate_span_count:33".to_string()]);

    // At the cap, validation proceeds normally (the 32 overlapping same-kind
    // spans merge into one).
    let (spans, warnings) = validate_model_output(&request, make_spans(32));
    assert_eq!(spans.len(), 1);
    assert!(!warnings
        .iter()
        .any(|warning| warning.starts_with("degenerate_span_count")));
}

#[test]
fn drops_unknown_model_kind_after_json_parsing() {
    let request = output_request();
    let output: ModelOutput = serde_json::from_str(
        r#"{
          "spans": [
            {
              "kind": "chapter_marker",
              "label": "Chapter",
              "start_segment_id": 101,
              "end_segment_id": 102,
              "confidence": 0.7,
              "evidence_quote": "brought to you by Acme Mattress"
            },
            {
              "kind": "inserted_ad",
              "label": "Beta Coffee",
              "start_segment_id": 106,
              "end_segment_id": 107,
              "confidence": 0.8,
              "evidence_quote": "Visit beta coffee dot com slash show"
            }
          ]
        }"#,
    )
    .expect("unknown model kinds should reach validation");

    let (spans, warnings) = validate_model_output(&request, output);

    assert_eq!(spans.len(), 1);
    assert_eq!(spans[0].kind, AdSpanKind::InsertedAd);
    assert_eq!(spans[0].label, "Beta Coffee");
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("unknown kind chapter_marker")));
}

#[test]
fn drops_malformed_model_spans_after_json_parsing() {
    let request = output_request();
    let output: ModelOutput = serde_json::from_str(
        r#"{
          "spans": [
            {
              "kind": "host_read_ad",
              "label": "Missing confidence",
              "start_segment_id": 101,
              "end_segment_id": 101,
              "evidence_quote": "missing"
            },
            {
              "kind": "inserted_ad",
              "label": "Beta Coffee",
              "start_segment_id": 106,
              "end_segment_id": 107,
              "confidence": 0.8,
              "evidence_quote": "Visit beta coffee dot com slash show"
            },
            {
              "kind": "house_or_network_promo",
              "label": "No Evidence",
              "start_segment_id": 102,
              "end_segment_id": 103,
              "confidence": 0.6
            }
          ]
        }"#,
    )
    .expect("malformed model spans should not reject valid sibling spans");

    let (spans, warnings) = validate_model_output(&request, output);

    assert_eq!(spans.len(), 1);
    assert_eq!(spans[0].kind, AdSpanKind::InsertedAd);
    assert_eq!(spans[0].label, "Beta Coffee");
    assert_eq!(
        warnings
            .iter()
            .filter(|warning| warning.as_str() == "dropped malformed span")
            .count(),
        1
    );
    // The span with a defaulted-empty evidence_quote dies on anchoring.
    assert!(warnings.contains(&"evidence_missing:102-103".to_string()));
}

#[test]
fn merges_same_kind_overlaps_even_when_other_kinds_are_interleaved() {
    let request = output_request();
    let output = ModelOutput::from_spans(vec![
        span(
            AdSpanKind::HostReadAd,
            "Acme A",
            101,
            102,
            0.7,
            "brought to you by Acme Mattress",
        ),
        span(
            AdSpanKind::InsertedAd,
            "Inserted disclaimer",
            102,
            103,
            0.6,
            "ask your doctor",
        ),
        span(
            AdSpanKind::HostReadAd,
            "Acme A",
            102,
            103,
            0.9,
            "use code podcast at checkout",
        ),
        span(
            AdSpanKind::HouseOrNetworkPromo,
            "Unknown End",
            101,
            999,
            0.8,
            "bad end",
        ),
    ]);

    let (spans, warnings) = validate_model_output(&request, output);

    assert_eq!(spans.len(), 2);
    assert_eq!(spans[0].kind, AdSpanKind::HostReadAd);
    assert_eq!(spans[0].start_segment_id, 101);
    assert_eq!(spans[0].end_segment_id, 103);
    assert_eq!(spans[0].confidence, 0.9);
    assert_eq!(spans[1].kind, AdSpanKind::InsertedAd);
    assert_eq!(spans[1].start_segment_id, 102);
    assert_eq!(spans[1].end_segment_id, 103);
    assert!(warnings.iter().any(|warning| warning.contains("merged")));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("unknown end")));
}

#[test]
fn drops_duplicate_reversed_unlabeled_and_invalid_confidence_spans() {
    let request = output_request();
    let output = ModelOutput::from_spans(vec![
        span(
            AdSpanKind::HostReadAd,
            "Sponsor A",
            101,
            102,
            1.4,
            "brought to you by Acme Mattress",
        ),
        span(
            AdSpanKind::HostReadAd,
            "Sponsor A",
            101,
            102,
            0.7,
            "duplicate",
        ),
        span(
            AdSpanKind::InsertedAd,
            "Reversed",
            103,
            102,
            0.8,
            "bad order",
        ),
        span(
            AdSpanKind::HouseOrNetworkPromo,
            "  ",
            102,
            102,
            0.8,
            "blank label",
        ),
        span(
            AdSpanKind::InsertedAd,
            "Invalid confidence",
            102,
            103,
            f64::NAN,
            "nan confidence",
        ),
    ]);

    let (spans, warnings) = validate_model_output(&request, output);

    assert_eq!(spans.len(), 1);
    assert_eq!(spans[0].label, "Sponsor A");
    assert_eq!(spans[0].confidence, 1.0);
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("clamped confidence")));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("duplicate span")));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("reversed span")));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("unlabeled span")));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("invalid confidence")));
}

#[test]
fn daily_usage_caps_requests_and_tokens() {
    let usage = DailyUsage {
        request_count: BEARER_DAILY_REQUEST_CAP - 1,
        estimated_input_tokens: 100,
    };
    assert_eq!(
        usage.admitting(50).unwrap().request_count,
        BEARER_DAILY_REQUEST_CAP
    );
    assert!(usage.admitting(50).unwrap().estimated_input_tokens == 150);
    assert!(usage.admitting(50).unwrap().admitting(1).is_err());
}

#[test]
fn usage_object_names_preserve_key_scope() {
    let current_day_key = usage_object_name("token-hash-a", 20_123);
    let next_day_key = usage_object_name("token-hash-a", 20_124);
    let other_token_key = usage_object_name("token-hash-b", 20_123);

    assert_eq!(current_day_key, "ad-analysis:v1:usage:20123:token-hash-a");
    assert_ne!(current_day_key, next_day_key);
    assert_ne!(current_day_key, other_token_key);
    assert!(current_day_key.ends_with(":token-hash-a"));
    assert_eq!(
        global_usage_object_name(20_123),
        "ad-analysis:v1:usage:20123:global"
    );
}

#[test]
fn bearer_usage_boundaries_preserve_internal_caps() {
    let last_allowed_request = DailyUsage {
        request_count: BEARER_DAILY_REQUEST_CAP - 1,
        estimated_input_tokens: 0,
    }
    .admitting(1)
    .expect("last request under cap should be admitted");
    assert_eq!(last_allowed_request.request_count, BEARER_DAILY_REQUEST_CAP);
    assert_eq!(
        last_allowed_request.admitting(1).unwrap_err(),
        CapError::DailyRequestsExceeded
    );

    let last_allowed_token = DailyUsage {
        request_count: 0,
        estimated_input_tokens: BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP - 10,
    }
    .admitting(10)
    .expect("last token increment under cap should be admitted");
    assert_eq!(
        last_allowed_token.estimated_input_tokens,
        BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP
    );
    assert_eq!(
        last_allowed_token.admitting(1).unwrap_err(),
        CapError::DailyEstimatedInputTokensExceeded
    );
}

#[test]
fn app_attest_and_global_profiles_use_public_caps_and_global_error_code() {
    let app_key_usage = DailyUsage {
        request_count: APP_ATTEST_KEY_DAILY_REQUEST_CAP,
        estimated_input_tokens: 0,
    };
    assert_eq!(
        app_key_usage
            .admitting_with_limits(1, UsageLimitProfile::AppAttestKey.limits())
            .unwrap_err(),
        CapError::DailyRequestsExceeded
    );

    let global_usage = DailyUsage {
        request_count: GLOBAL_DAILY_REQUEST_CAP,
        estimated_input_tokens: 0,
    };
    assert_eq!(
        global_usage
            .admitting_with_limits(1, UsageLimitProfile::Global.limits())
            .unwrap_err(),
        CapError::GlobalCapacityExhausted
    );
    assert_eq!(
        CapError::GlobalCapacityExhausted.code(),
        "global_capacity_exhausted"
    );
}

#[test]
fn transcription_account_profile_uses_app_attest_scale_caps_and_shares_the_global_cap() {
    use opencast_ad_analysis_worker::types::{
        TRANSCRIPTION_ACCOUNT_DAILY_ESTIMATED_INPUT_TOKEN_CAP,
        TRANSCRIPTION_ACCOUNT_DAILY_REQUEST_CAP,
    };

    let full_account = DailyUsage {
        request_count: TRANSCRIPTION_ACCOUNT_DAILY_REQUEST_CAP,
        estimated_input_tokens: 0,
    };
    assert_eq!(
        full_account
            .admitting_with_limits(1, UsageLimitProfile::TranscriptionAccount.limits())
            .unwrap_err(),
        CapError::DailyRequestsExceeded
    );

    let token_capped = DailyUsage {
        request_count: 0,
        estimated_input_tokens: TRANSCRIPTION_ACCOUNT_DAILY_ESTIMATED_INPUT_TOKEN_CAP,
    };
    assert_eq!(
        token_capped
            .admitting_with_limits(1, UsageLimitProfile::TranscriptionAccount.limits())
            .unwrap_err(),
        CapError::DailyEstimatedInputTokensExceeded
    );

    // The internal profile shares the SAME global limits table public traffic
    // fills: a public-exhausted global day rejects internal traffic too.
    let publicly_exhausted_global = DailyUsage {
        request_count: GLOBAL_DAILY_REQUEST_CAP,
        estimated_input_tokens: 0,
    };
    assert_eq!(
        publicly_exhausted_global
            .admitting_with_limits(1, UsageLimitProfile::Global.limits())
            .unwrap_err(),
        CapError::GlobalCapacityExhausted
    );

    // Wire form is stable snake_case for the DO submit payload.
    assert_eq!(
        serde_json::to_string(&UsageLimitProfile::TranscriptionAccount).unwrap(),
        "\"transcription_account\""
    );
}

#[test]
fn daily_usage_persistence_shape_contains_only_usage_counters() {
    let usage = DailyUsage {
        request_count: 2,
        estimated_input_tokens: 1_234,
    };

    let encoded = serde_json::to_string(&usage).expect("usage serializes");
    let value: serde_json::Value = serde_json::from_str(&encoded).expect("usage is JSON");
    let object = value.as_object().expect("usage is a JSON object");

    assert_eq!(object.len(), 2);
    assert_eq!(value["request_count"], serde_json::json!(2));
    assert_eq!(value["estimated_input_tokens"], serde_json::json!(1_234));
    assert!(!encoded.contains("transcript"));
    assert!(!encoded.contains("segments"));
    assert!(!encoded.contains("spans"));
    assert!(!encoded.contains("source"));
}

#[test]
fn content_length_is_required_and_bounded_before_reading_body() {
    assert_eq!(
        validate_content_length(None).unwrap_err(),
        ContentLengthError::Missing
    );
    assert_eq!(
        validate_content_length(Some("not-a-number")).unwrap_err(),
        ContentLengthError::Invalid
    );
    assert_eq!(
        validate_content_length(Some("1500001")).unwrap_err(),
        ContentLengthError::TooLarge
    );
    assert_eq!(validate_content_length(Some(" 42 ")).unwrap(), 42);
}

fn span(
    kind: AdSpanKind,
    label: &str,
    start: i64,
    end: i64,
    confidence: f64,
    evidence_quote: &str,
) -> ModelSpan {
    ModelSpan {
        kind: kind.as_str().to_string(),
        label: label.to_string(),
        start_segment_id: start,
        end_segment_id: end,
        confidence,
        evidence_quote: evidence_quote.to_string(),
    }
}

/// Ten 10-second segments (ids 100-109) with anchorable ad copy: an Acme
/// Mattress read at 101-103, a Beta Coffee read at 106-108, and a repeated
/// resume phrase at 104/109 for ambiguity tests.
fn output_request() -> AdAnalysisRequest {
    let texts = [
        "Welcome back to the show everyone, great to have you.",
        "This episode is brought to you by Acme Mattress, the best sleep upgrade.",
        "Use code podcast at checkout for twenty percent off your first order.",
        "Side effects may include excellent naps, ask your doctor about sleeping.",
        "Now back to our regular discussion about the championship game.",
        "I had a wild weekend hiking with my brother in the mountains.",
        "Our second sponsor Beta Coffee roasts fresh beans every single morning.",
        "Visit beta coffee dot com slash show for a free bag today.",
        "That wraps the second read, huge thanks to Beta Coffee.",
        "Anyway, back to our regular discussion about the championship game.",
    ];
    request_with_segments(
        texts
            .iter()
            .enumerate()
            .map(|(index, text)| TranscriptSegment {
                id: 100 + index as i64,
                start: index as f64 * 10.0,
                end: (index as f64 + 1.0) * 10.0,
                text: (*text).to_string(),
            })
            .collect(),
        100.0,
    )
}

/// `count` segments of `seconds` each; segment N's text carries a unique
/// anchor phrase ("segment N unique pepper marker <word>").
fn wide_request(count: usize, seconds: f64) -> AdAnalysisRequest {
    let word = |index: usize| -> String {
        match index {
            0 => "zero".to_string(),
            3 => "three".to_string(),
            50 => "fifty".to_string(),
            100 => "hundred".to_string(),
            150 => "onefifty".to_string(),
            other => format!("w{other}"),
        }
    };
    request_with_segments(
        (0..count)
            .map(|index| TranscriptSegment {
                id: index as i64,
                start: index as f64 * seconds,
                end: (index as f64 + 1.0) * seconds,
                text: format!(
                    "segment {index} unique pepper marker {} filler words continue",
                    word(index)
                ),
            })
            .collect(),
        count as f64 * seconds,
    )
}

fn request_with_segments(segments: Vec<TranscriptSegment>, duration: f64) -> AdAnalysisRequest {
    AdAnalysisRequest {
        schema_version: SCHEMA_VERSION,
        async_supported: false,
        request_id: "request-1".to_string(),
        episode_id: "episode-1".to_string(),
        podcast_id: "podcast-1".to_string(),
        episode_title: Some("Episode".to_string()),
        podcast_title: Some("Podcast".to_string()),
        transcript: TranscriptMetadata {
            language_code: "en".to_string(),
            audio_duration: duration,
            model_identifier: Some("large-v3".to_string()),
            model_version: Some("v1".to_string()),
            model_tree_sha256: Some("abc".to_string()),
            fingerprint: "fingerprint".to_string(),
            updated_at: "2026-07-01T00:00:00Z".to_string(),
            state: "completed".to_string(),
            segment_count: segments.len(),
        },
        segments,
    }
}

fn sample_request() -> AdAnalysisRequest {
    request_with_segments(
        vec![
            TranscriptSegment {
                id: 100,
                start: 0.0,
                end: 3.0,
                text: "This is sponsor copy.".to_string(),
            },
            TranscriptSegment {
                id: 101,
                start: 3.0,
                end: 6.0,
                text: "Use code podcast.".to_string(),
            },
            TranscriptSegment {
                id: 102,
                start: 6.0,
                end: 9.0,
                text: "Now another promo.".to_string(),
            },
        ],
        10.0,
    )
}

use opencast_transcript_analysis_worker::gemini::{
    parse_error_envelope, parse_generate_content_response, GeminiErrorBody, GeminiParseError,
};
use opencast_transcript_analysis_worker::retry::{
    classify_http_status, parse_retry_after_seconds, RetryDecision,
};

fn model_output_json() -> String {
    serde_json::json!({
        "chapters": [
            {"title": "Opening", "start_segment_id": 0, "end_segment_id": 1, "confidence": 0.8},
        ],
        "summary": {
            "summary": "A short episode.",
            "one_line_description": "Short",
            "claims": [{"text": "It is short", "evidence_segment_id": 0}],
        },
    })
    .to_string()
}

fn wrap_candidate(text: &str, finish_reason: &str) -> String {
    serde_json::json!({
        "candidates": [
            {"content": {"parts": [{"text": text}]}, "finishReason": finish_reason}
        ],
        "usageMetadata": {
            "promptTokenCount": 100,
            "candidatesTokenCount": 20,
            "thoughtsTokenCount": 3000,
            "totalTokenCount": 3120
        }
    })
    .to_string()
}

#[test]
fn parses_gemini_text_json_and_usage_with_thoughts() {
    let parsed = parse_generate_content_response(&wrap_candidate(&model_output_json(), "STOP"));

    let output = parsed.output.expect("valid response has output");
    assert_eq!(output.chapters.len(), 1);
    assert_eq!(output.chapters[0].title, "Opening");
    assert_eq!(output.summary.claims.len(), 1);
    let usage = parsed.usage.expect("usage present");
    // Thoughts are recorded separately for cost instrumentation (billed
    // output = candidates + thoughts).
    assert_eq!(usage.thoughts_token_count, 3_000);
    assert_eq!(usage.total_token_count, 3_120);
    assert!(parsed.warnings.is_empty());
    assert!(parsed.failure.is_none());
}

#[test]
fn usage_totals_cover_thinking_tokens_when_total_omits_them() {
    let body = r#"{
      "candidates": [
        {"content": {"parts": [{"text": "irrelevant"}]}, "finishReason": "STOP"}
      ],
      "usageMetadata": {
        "promptTokenCount": 100,
        "candidatesTokenCount": 20,
        "thoughtsTokenCount": 1700,
        "totalTokenCount": 120
      }
    }"#;

    let parsed = parse_generate_content_response(body);

    assert_eq!(parsed.usage.unwrap().total_token_count, 1_820);
}

#[test]
fn parse_failures_distinguish_malformed_response_missing_text_and_model_json() {
    let parsed = parse_generate_content_response("not-json");
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MalformedResponse));

    let parsed = parse_generate_content_response(r#"{"candidates":[]}"#);
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MissingCandidateText));

    let parsed = parse_generate_content_response(
        r#"{"candidates":[{"content":{"parts":[{"text":"   "}]},"finishReason":"STOP"}]}"#,
    );
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MissingCandidateText));

    let parsed = parse_generate_content_response(
        r#"{"candidates":[{"content":{"parts":[{"text":"{\"chapters\":"}]},"finishReason":"STOP"}]}"#,
    );
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MalformedModelJson));

    // A response missing required model-output fields is malformed, never
    // partial output.
    let parsed = parse_generate_content_response(
        r#"{"candidates":[{"content":{"parts":[{"text":"{\"chapters\":[]}"}]},"finishReason":"STOP"}]}"#,
    );
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MalformedModelJson));
}

/// MAX_TOKENS is a hard parse failure here — unlike the ad-analysis
/// template, which tolerated a non-STOP finish when the JSON happened to
/// parse. A truncated schema-constrained response can be a valid JSON
/// prefix, and evaluation measured truncation as transient (retry fixes it), so
/// the text is never trusted.
#[test]
fn max_tokens_is_a_failure_even_when_the_json_parses() {
    let parsed = parse_generate_content_response(&wrap_candidate(&model_output_json(), "MAX_TOKENS"));

    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MaxTokensTruncated));
    assert_eq!(GeminiParseError::MaxTokensTruncated.code(), "max_tokens_truncated");
    assert_eq!(parsed.warnings, vec!["gemini_finish_reason:MAX_TOKENS"]);
    // The burned usage still surfaces for cost instrumentation.
    assert_eq!(parsed.usage.unwrap().total_token_count, 3_120);
}

#[test]
fn safety_finish_is_a_non_stop_failure() {
    let parsed = parse_generate_content_response(&wrap_candidate(&model_output_json(), "SAFETY"));

    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::NonStopFinishReason));
    assert_eq!(parsed.warnings, vec!["gemini_finish_reason:SAFETY"]);
}

#[test]
fn parser_combines_text_parts() {
    let body = r#"{
      "candidates": [
        {
          "content": {
            "parts": [
              {"text": "{\"chapters\":[{\"title\":\"T\",\"start_segment_id\":0,\"end_segment_id\":0,\"confidence\":0.5}],"},
              {"text": "\"summary\":{\"summary\":\"s\",\"one_line_description\":\"o\",\"claims\":[{\"text\":\"c\",\"evidence_segment_id\":0}]}}"}
            ]
          },
          "finishReason": "STOP"
        }
      ]
    }"#;

    let parsed = parse_generate_content_response(body);

    let output = parsed.output.expect("valid combined JSON has output");
    assert_eq!(output.chapters.len(), 1);
    assert!(parsed.usage.is_none());
}

#[test]
fn parses_gemini_error_envelope_when_present() {
    let body = r#"{
      "error": {
        "code": 429,
        "message": "Resource exhausted, check billing.",
        "status": "RESOURCE_EXHAUSTED"
      }
    }"#;

    let error = parse_error_envelope(body).expect("error envelope should parse");

    assert_eq!(error.code, Some(429));
    assert_eq!(error.status.as_deref(), Some("RESOURCE_EXHAUSTED"));
    assert!(error.message.contains("billing"));
    assert!(parse_error_envelope(r#"{"message":"not the Gemini shape"}"#).is_none());
}

#[test]
fn retry_classification_handles_transient_and_quota_statuses() {
    assert_eq!(
        classify_http_status(503, Some("7"), None),
        RetryDecision::Retry {
            retry_after_seconds: Some(7)
        }
    );

    let quota = GeminiErrorBody {
        code: Some(429),
        message: "You exceeded your current quota. Check billing.".to_string(),
        status: Some("RESOURCE_EXHAUSTED".to_string()),
    };
    assert_eq!(
        classify_http_status(429, None, Some(&quota)),
        RetryDecision::HardQuota
    );

    let transient = GeminiErrorBody {
        code: Some(429),
        message: "Too many requests, try again later.".to_string(),
        status: Some("RESOURCE_EXHAUSTED".to_string()),
    };
    assert!(classify_http_status(429, None, Some(&transient)).is_retry());
    assert_eq!(
        classify_http_status(500, None, None),
        RetryDecision::Retry {
            retry_after_seconds: None
        }
    );
    assert_eq!(
        classify_http_status(504, Some("999"), None),
        RetryDecision::Retry {
            retry_after_seconds: Some(30)
        }
    );
    assert_eq!(
        classify_http_status(400, None, None),
        RetryDecision::DoNotRetry
    );
}

#[test]
fn retry_after_parses_only_numeric_seconds_and_caps_delay() {
    assert_eq!(parse_retry_after_seconds(" 12 "), Some(12));
    assert_eq!(parse_retry_after_seconds("999"), Some(30));
    assert_eq!(
        parse_retry_after_seconds("Wed, 01 Jul 2026 00:00:00 GMT"),
        None
    );
    assert_eq!(parse_retry_after_seconds("soon"), None);
    assert_eq!(parse_retry_after_seconds("-1"), None);
}

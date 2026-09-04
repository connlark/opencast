use opencast_ad_analysis_worker::gemini::{
    parse_error_envelope, parse_generate_content_response, GeminiErrorBody, GeminiParseError,
};
use opencast_ad_analysis_worker::job::JOB_RUNNING_DEADLINE_SECONDS;
use opencast_ad_analysis_worker::retry::{
    backoff_seconds, classify_http_status, parse_retry_after_seconds, worst_case_ladder_seconds,
    worst_case_window_seconds, RetryDecision, GEMINI_CALL_TIMEOUT_SECONDS,
    LADDER_DEADLINE_HEADROOM_SECONDS, MAX_GEMINI_ATTEMPTS, MAX_GEMINI_REREQUEST_ATTEMPTS,
    MAX_RETRY_DELAY_SECONDS,
};

#[test]
fn parses_gemini_text_json_and_usage() {
    let body = r#"{
      "candidates": [
        {
          "content": {
            "parts": [
              { "text": "{\"spans\":[{\"kind\":\"host_read_ad\",\"label\":\"Sponsor\",\"start_segment_id\":1,\"end_segment_id\":2,\"confidence\":0.7,\"evidence_quote\":\"use code\"}]}" }
            ]
          },
          "finishReason": "STOP"
        }
      ],
      "usageMetadata": {
        "promptTokenCount": 100,
        "candidatesTokenCount": 20,
        "totalTokenCount": 120
      }
    }"#;

    let parsed = parse_generate_content_response(body);

    let output = parsed.output.expect("valid response has output");
    assert_eq!(output.spans.len(), 1);
    assert_eq!(output.spans[0].label, "Sponsor");
    assert_eq!(output.malformed_span_count, 0);
    let usage = parsed.usage.unwrap();
    assert_eq!(usage.total_token_count, 120);
    // No thoughtsTokenCount in the body reads as zero thinking tokens.
    assert_eq!(usage.thoughts_token_count, 0);
    assert!(parsed.warnings.is_empty());
    assert!(parsed.failure.is_none());
}

#[test]
fn thought_parts_are_excluded_from_the_model_json() {
    // Thinking models can return their reasoning as `thought: true` parts
    // ahead of the answer. Concatenating them into the model text made the
    // JSON unparseable and degraded the window to zero spans.
    let body = r#"{
      "candidates": [
        {
          "content": {
            "parts": [
              { "thought": true, "text": "Let me scan the segments for sponsor reads..." },
              { "text": "{\"spans\":[{\"kind\":\"host_read_ad\",\"label\":\"Sponsor\",\"start_segment_id\":1,\"end_segment_id\":2,\"confidence\":0.9,\"evidence_quote\":\"use code\"}]}", "thoughtSignature": "opaque" }
            ]
          },
          "finishReason": "STOP"
        }
      ],
      "usageMetadata": {
        "promptTokenCount": 100,
        "candidatesTokenCount": 20,
        "thoughtsTokenCount": 700,
        "totalTokenCount": 820
      }
    }"#;

    let parsed = parse_generate_content_response(body);

    let output = parsed
        .output
        .expect("thought parts must not poison the model JSON");
    assert_eq!(output.spans.len(), 1);
    assert_eq!(output.spans[0].label, "Sponsor");
    assert!(parsed.failure.is_none());
    assert!(parsed.warnings.is_empty());
    let usage = parsed.usage.unwrap();
    assert_eq!(usage.thoughts_token_count, 700);
    assert_eq!(usage.total_token_count, 820);
}

#[test]
fn thought_signature_on_a_text_part_is_still_used() {
    // Every archived 3.5/3.6/3.8 response carries `thoughtSignature` on the
    // ordinary answer part; it is an unknown key, not a thought part.
    let body = r#"{
      "candidates": [
        {
          "content": {
            "parts": [
              { "text": "{\"spans\":[]}", "thoughtSignature": "Cq0BAXKq" }
            ]
          },
          "finishReason": "STOP"
        }
      ]
    }"#;

    let parsed = parse_generate_content_response(body);

    let output = parsed
        .output
        .expect("signature-bearing text part is the answer");
    assert!(output.spans.is_empty());
    assert!(parsed.failure.is_none());
}

#[test]
fn only_thought_parts_yield_missing_candidate_text() {
    let body = r#"{
      "candidates": [
        {
          "content": {
            "parts": [
              { "thought": true, "text": "{\"spans\":[]}" }
            ]
          },
          "finishReason": "STOP"
        }
      ]
    }"#;

    let parsed = parse_generate_content_response(body);

    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MissingCandidateText));
}

#[test]
fn usage_totals_cover_thinking_tokens_when_reported_separately() {
    // Thinking models report thoughtsTokenCount; totalTokenCount normally
    // already includes it, but a total that omits thoughts is corrected.
    let body = r#"{
      "candidates": [
        {
          "content": { "parts": [{ "text": "{\"spans\":[]}" }] },
          "finishReason": "STOP"
        }
      ],
      "usageMetadata": {
        "promptTokenCount": 100,
        "candidatesTokenCount": 20,
        "thoughtsTokenCount": 1700,
        "totalTokenCount": 120
      }
    }"#;

    let parsed = parse_generate_content_response(body);

    let usage = parsed.usage.unwrap();
    assert_eq!(usage.total_token_count, 1_820);
    assert_eq!(usage.thoughts_token_count, 1_700);
}

#[test]
fn parses_valid_model_spans_when_a_sibling_span_is_malformed() {
    let body = r#"{
      "candidates": [
        {
          "content": {
            "parts": [
              { "text": "{\"spans\":[{\"kind\":\"host_read_ad\",\"label\":\"Missing confidence\",\"start_segment_id\":1,\"end_segment_id\":1},{\"kind\":\"inserted_ad\",\"label\":\"Sponsor\",\"start_segment_id\":2,\"end_segment_id\":2,\"confidence\":0.7,\"evidence_quote\":\"use code\"}]}" }
            ]
          },
          "finishReason": "STOP"
        }
      ]
    }"#;

    let parsed = parse_generate_content_response(body);

    let output = parsed.output.expect("valid response has output");
    assert_eq!(output.spans.len(), 1);
    assert_eq!(output.spans[0].label, "Sponsor");
    assert_eq!(output.malformed_span_count, 1);
    assert!(parsed.usage.is_none());
    assert!(parsed.warnings.is_empty());
}

#[test]
fn parse_failures_distinguish_malformed_response_missing_text_and_model_json() {
    // Malformed/truncated model output is a degradable failure, not an error:
    // output is None and the failure code drives a window-skipped warning.
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
        r#"{"candidates":[{"content":{"parts":[{"text":"{\"spans\":"}]},"finishReason":"STOP"}]}"#,
    );
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MalformedModelJson));
    assert_eq!(
        GeminiParseError::MalformedModelJson.code(),
        "malformed_model_json"
    );
}

#[test]
fn truncated_model_json_keeps_finish_reason_warning_and_usage() {
    // A MAX_TOKENS truncation must surface both the finish-reason warning and
    // the usage that was burned, so the degraded window is debuggable.
    let body = r#"{
      "candidates": [
        {
          "content": { "parts": [{ "text": "{\"spans\":[{\"kind\":" }] },
          "finishReason": "MAX_TOKENS"
        }
      ],
      "usageMetadata": {
        "promptTokenCount": 100,
        "candidatesTokenCount": 4096,
        "totalTokenCount": 4196
      }
    }"#;

    let parsed = parse_generate_content_response(body);

    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MalformedModelJson));
    assert_eq!(parsed.warnings, vec!["gemini_finish_reason:MAX_TOKENS"]);
    assert_eq!(parsed.usage.unwrap().total_token_count, 4_196);
}

#[test]
fn parser_combines_text_parts_and_warns_on_non_stop_finish_reason() {
    let body = r#"{
      "candidates": [
        {
          "content": {
            "parts": [
              { "text": "{\"spans\":" },
              { "text": "[]}" }
            ]
          },
          "finishReason": "MAX_TOKENS"
        }
      ]
    }"#;

    let parsed = parse_generate_content_response(body);

    let output = parsed.output.expect("valid combined JSON has output");
    assert!(output.spans.is_empty());
    assert!(parsed.usage.is_none());
    assert_eq!(parsed.warnings, vec!["gemini_finish_reason:MAX_TOKENS"]);
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

    let quota = opencast_ad_analysis_worker::gemini::GeminiErrorBody {
        code: Some(429),
        message: "You exceeded your current quota. Check billing.".to_string(),
        status: Some("RESOURCE_EXHAUSTED".to_string()),
    };
    assert_eq!(
        classify_http_status(429, None, Some(&quota)),
        RetryDecision::HardQuota
    );

    let transient = opencast_ad_analysis_worker::gemini::GeminiErrorBody {
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
        classify_http_status(502, None, None),
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

#[test]
fn quota_classification_requires_resource_exhausted_with_billing_language() {
    let no_error_body = classify_http_status(429, Some("3"), None);
    assert_eq!(
        no_error_body,
        RetryDecision::Retry {
            retry_after_seconds: Some(3)
        }
    );

    let exhausted_without_billing = GeminiErrorBody {
        code: Some(429),
        message: "Rate limit exceeded, try later.".to_string(),
        status: Some("RESOURCE_EXHAUSTED".to_string()),
    };
    assert!(classify_http_status(429, None, Some(&exhausted_without_billing)).is_retry());

    let billing_without_resource_exhausted = GeminiErrorBody {
        code: Some(403),
        message: "Billing account disabled.".to_string(),
        status: Some("PERMISSION_DENIED".to_string()),
    };
    assert_eq!(
        classify_http_status(429, None, Some(&billing_without_resource_exhausted)),
        RetryDecision::Retry {
            retry_after_seconds: None
        }
    );

    for message in [
        "Project quota exceeded.",
        "Billing is not enabled.",
        "Prepay credits are exhausted.",
        "Insufficient credit.",
    ] {
        let quota = GeminiErrorBody {
            code: Some(429),
            message: message.to_string(),
            status: Some("RESOURCE_EXHAUSTED".to_string()),
        };
        assert_eq!(
            classify_http_status(429, None, Some(&quota)),
            RetryDecision::HardQuota
        );
    }
}

/// The ladders are sized together: a window whose every attempt times out
/// and whose every gap waits the longest allowed delay must still finish
/// inside the job Durable Object's running deadline with headroom for the
/// unbounded body read and DO bookkeeping. (3×60 + 2×30) + (2×60 + 1×30) =
/// 390 s; 390 + 120 ≤ 600.
#[test]
fn gemini_ladder_worst_case_fits_the_job_deadline() {
    assert_eq!(GEMINI_CALL_TIMEOUT_SECONDS, 60);
    assert_eq!(MAX_GEMINI_ATTEMPTS, 3);
    assert_eq!(MAX_GEMINI_REREQUEST_ATTEMPTS, 2);
    assert_eq!(MAX_RETRY_DELAY_SECONDS, 30);
    assert_eq!(worst_case_ladder_seconds(MAX_GEMINI_ATTEMPTS), 240);
    assert_eq!(
        worst_case_ladder_seconds(MAX_GEMINI_REREQUEST_ATTEMPTS),
        150
    );
    assert_eq!(worst_case_window_seconds(), 390);
    assert!(
        worst_case_window_seconds() + LADDER_DEADLINE_HEADROOM_SECONDS
            <= JOB_RUNNING_DEADLINE_SECONDS as u64,
        "ladder worst case {} s + {} s headroom exceeds the {} s job deadline",
        worst_case_window_seconds(),
        LADDER_DEADLINE_HEADROOM_SECONDS,
        JOB_RUNNING_DEADLINE_SECONDS
    );
    // Neither backoff nor an honoured Retry-After may exceed the delay the
    // worst case assumes.
    for attempt in 1..=MAX_GEMINI_ATTEMPTS {
        assert!(backoff_seconds(attempt) <= MAX_RETRY_DELAY_SECONDS);
    }
    assert_eq!(backoff_seconds(1), 2);
    assert_eq!(backoff_seconds(2), 4);
    assert_eq!(
        parse_retry_after_seconds("999"),
        Some(MAX_RETRY_DELAY_SECONDS)
    );
}

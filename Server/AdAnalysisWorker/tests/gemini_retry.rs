use opencast_ad_analysis_worker::gemini::{
    parse_error_envelope, parse_generate_content_response, GeminiErrorBody, GeminiParseError,
};
use opencast_ad_analysis_worker::retry::{
    classify_http_status, parse_retry_after_seconds, RetryDecision,
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
    assert_eq!(parsed.usage.unwrap().total_token_count, 120);
    assert!(parsed.warnings.is_empty());
    assert!(parsed.failure.is_none());
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

    assert_eq!(parsed.usage.unwrap().total_token_count, 1_820);
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

use std::time::Duration;

use futures_util::future::{select, Either};
use worker::{console_error, console_log, Date, Delay, Fetch, Headers, Method, Request, RequestInit, Response};

use crate::coalescing::{prepare_analysis_request, CoalescingError};
use crate::gemini::{parse_error_envelope, parse_generate_content_response, GeminiParseError};
use crate::prompt::{gemini_generate_content_url, gemini_request_payload, GeminiGenerationOptions};
use crate::retry::{classify_http_status, RetryDecision};
use crate::route::JSON_CONTENT_TYPE;
use crate::thinking::thinking_level_for_segment_count;
use crate::types::{
    ErrorResponse, GeminiUsage, TranscriptAnalysisRequest, TranscriptAnalysisResponse, POLICY_NAME,
    SCHEMA_VERSION,
};
use crate::validation::{combine_warnings, validate_and_remap_model_output};

const MAX_GEMINI_ATTEMPTS: usize = 5;
/// Full model re-requests before failing typed. The first attempt uses the
/// model-facing segment-count level; every retry escalates to `high`.
/// Evaluation found
/// gemini-3.5-flash at temp 0 now emits the id-discipline failure
/// (seconds-in-id-fields) at <=1,399 segments where evaluation had pinned the
/// cliff at >=1,800, and a same-level re-draw does not reliably recover
/// (representative inputs both failed after two same-level attempts). The
/// validated high-thinking configuration fixes the id-discipline class, so an
/// escalated retry is a stronger re-roll than an identical one. Retry at high
/// up to three attempts; the prompt remains unchanged.
const MAX_ANALYSIS_ATTEMPTS: usize = 3;
/// 60 s bounds each attempt. The template's 30 s would time out healthy
/// long-episode generations here: evaluation measured 15–30 s typical latency
/// with 63 s and 134 s outliers on thinking-token spikes over the ~3 h
/// fixture. The retry ladder is unchanged — a timed-out attempt backs off
/// and retries like any transport failure.
const GEMINI_CALL_TIMEOUT_SECONDS: u64 = 60;

pub(crate) struct UpstreamError {
    pub status: u16,
    pub body: ErrorResponse,
}

/// Single-shot only: partial/windowed context degrades chapter boundaries and
/// summaries. Dense transcripts above the validated raw envelope are
/// represented as coalesced units, validated in unit space, remapped, and
/// re-validated in original-id space. Parse, truncation, and hard-invalid
/// failures retry up to the validated three-attempt limit; every retry uses
/// high thinking.
pub(crate) async fn run_analysis(
    gemini_api_key: &str,
    model: &str,
    request: TranscriptAnalysisRequest,
) -> std::result::Result<TranscriptAnalysisResponse, UpstreamError> {
    let gemini_url = gemini_generate_content_url(model);
    let prepared = prepare_analysis_request(&request).map_err(|error| match error {
        CoalescingError::TooManyUnits => UpstreamError {
            status: 400,
            body: ErrorResponse::new("transcript_too_long"),
        },
    })?;
    let base_level = thinking_level_for_segment_count(prepared.model_request.segments.len());
    let raw_segment_count = request.segments.len();
    let model_unit_count = prepared.model_request.segments.len();
    let started_at_ms = Date::now().as_millis();

    let mut combined_usage: Option<GeminiUsage> = None;
    let mut gemini_warnings: Vec<String> = Vec::new();
    let mut last_failure: Option<GeminiParseError> = None;

    for attempt in 0..MAX_ANALYSIS_ATTEMPTS {
        // Attempt 0 uses the model-facing segment-count level; every retry
        // escalates to high (see MAX_ANALYSIS_ATTEMPTS). Rebuilt per attempt
        // so the level change reaches the payload; the prompt text is
        // identical across attempts (only generationConfig.thinkingLevel differs).
        let level = if attempt == 0 { base_level } else { "high" };
        let payload = gemini_request_payload(
            prepared.model_request.as_ref(),
            GeminiGenerationOptions {
                thinking_level: level,
                ..GeminiGenerationOptions::default()
            },
        );
        let is_last = attempt + 1 == MAX_ANALYSIS_ATTEMPTS;

        let response_body = call_gemini_with_retry(gemini_api_key, &gemini_url, &payload).await?;
        let mut parsed = parse_generate_content_response(&response_body);
        combined_usage = combine_usage(combined_usage, parsed.usage.take());
        gemini_warnings.append(&mut parsed.warnings);

        match parsed.output {
            Some(output) => match validate_and_remap_model_output(&request, &prepared, output) {
                Ok(validated) => {
                    let response = TranscriptAnalysisResponse {
                        schema_version: SCHEMA_VERSION,
                        request_id: request.request_id,
                        model: model.to_string(),
                        policy: POLICY_NAME.to_string(),
                        chapters: validated.chapters,
                        summary: Some(validated.summary),
                        warnings: combine_warnings(validated.warnings, gemini_warnings),
                        usage: combined_usage,
                    };
                    console_log!(
                        "{}",
                        crate::job::completion_log_line(
                            &response,
                            raw_segment_count,
                            model_unit_count,
                            attempt + 1,
                            Date::now().as_millis().saturating_sub(started_at_ms),
                        )
                    );
                    return Ok(response);
                }
                Err(violations) => {
                    // Client detail and response warnings contain fixed rule
                    // codes only, never model text or violation details.
                    let codes = violations
                        .iter()
                        .map(|violation| violation.rule)
                        .collect::<Vec<_>>()
                        .join(",");
                    if is_last {
                        return Err(UpstreamError {
                            status: 502,
                            body: ErrorResponse::with_detail("invalid_model_output", codes),
                        });
                    }
                    // `_high`: the next attempt runs at high thinking.
                    gemini_warnings.push(format!("invalid_model_output_retried_high:{codes}"));
                    last_failure = None;
                }
            },
            None => {
                let failure = parsed
                    .failure
                    .unwrap_or(GeminiParseError::MalformedModelJson);
                if is_last {
                    last_failure = Some(failure);
                    break;
                }
                gemini_warnings.push(format!("{}_retried_high", failure.code()));
                last_failure = Some(failure);
            }
        }
    }

    let code = match last_failure {
        Some(GeminiParseError::MaxTokensTruncated) => "model_output_truncated",
        _ => "invalid_model_output",
    };
    Err(UpstreamError {
        status: 502,
        body: ErrorResponse::new(code),
    })
}

async fn call_gemini_with_retry(
    gemini_api_key: &str,
    gemini_url: &str,
    payload: &serde_json::Value,
) -> std::result::Result<String, UpstreamError> {
    let payload_string = serde_json::to_string(payload).map_err(|error| UpstreamError {
        status: 500,
        body: ErrorResponse::with_detail("gemini_payload_error", error.to_string()),
    })?;
    let mut last_error = UpstreamError {
        status: 502,
        body: ErrorResponse::new("gemini_unavailable"),
    };

    for attempt in 1..=MAX_GEMINI_ATTEMPTS {
        let mut response = match call_gemini_once(gemini_api_key, gemini_url, &payload_string).await
        {
            Ok(response) => response,
            Err(error) => {
                last_error = error;
                if attempt < MAX_GEMINI_ATTEMPTS {
                    Delay::from(Duration::from_secs(backoff_seconds(attempt))).await;
                    continue;
                }
                break;
            }
        };

        let status = response.status_code();
        let retry_after = response.headers().get("retry-after").ok().flatten();
        let text = response.text().await.unwrap_or_default();
        if (200..300).contains(&status) {
            return Ok(text);
        }

        let error_body = parse_error_envelope(&text);
        match classify_http_status(status, retry_after.as_deref(), error_body.as_ref()) {
            RetryDecision::Retry {
                retry_after_seconds,
            } if attempt < MAX_GEMINI_ATTEMPTS => {
                let seconds = retry_after_seconds.unwrap_or_else(|| backoff_seconds(attempt));
                Delay::from(Duration::from_secs(seconds)).await;
                last_error = UpstreamError {
                    status: 503,
                    body: ErrorResponse::new("gemini_retry_exhausted"),
                };
            }
            RetryDecision::HardQuota => {
                return Err(UpstreamError {
                    status: 503,
                    body: ErrorResponse::new("gemini_quota_exhausted"),
                });
            }
            _ => {
                return Err(UpstreamError {
                    status: upstream_status(status),
                    body: ErrorResponse::with_detail(
                        "gemini_http_error",
                        format!("status {status}"),
                    ),
                });
            }
        }
    }

    Err(last_error)
}

async fn call_gemini_once(
    gemini_api_key: &str,
    gemini_url: &str,
    payload_string: &str,
) -> std::result::Result<Response, UpstreamError> {
    let headers = Headers::new();
    headers
        .set("content-type", JSON_CONTENT_TYPE)
        .map_err(worker_error)?;
    headers
        .set("x-goog-api-key", gemini_api_key)
        .map_err(worker_error)?;

    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(payload_string.into()));

    let request = Request::new_with_init(gemini_url, &init).map_err(worker_error)?;
    let fetch = Fetch::Request(request);
    let fetch = std::pin::pin!(fetch.send());
    let deadline = std::pin::pin!(Delay::from(Duration::from_secs(
        GEMINI_CALL_TIMEOUT_SECONDS
    )));
    match select(fetch, deadline).await {
        Either::Left((result, _)) => result.map_err(worker_error),
        Either::Right(((), _)) => Err(UpstreamError {
            status: 503,
            body: ErrorResponse::new("gemini_timeout"),
        }),
    }
}

fn worker_error(error: worker::Error) -> UpstreamError {
    console_error!("Worker error: {error:?}");
    UpstreamError {
        status: 502,
        body: ErrorResponse::new("worker_fetch_error"),
    }
}

fn backoff_seconds(attempt: usize) -> u64 {
    (1u64 << attempt.min(4)).min(20)
}

fn upstream_status(status: u16) -> u16 {
    if status == 429 || (500..600).contains(&status) {
        503
    } else {
        502
    }
}

fn combine_usage(lhs: Option<GeminiUsage>, rhs: Option<GeminiUsage>) -> Option<GeminiUsage> {
    match (lhs, rhs) {
        (Some(lhs), Some(rhs)) => Some(GeminiUsage {
            prompt_token_count: lhs
                .prompt_token_count
                .saturating_add(rhs.prompt_token_count),
            candidates_token_count: lhs
                .candidates_token_count
                .saturating_add(rhs.candidates_token_count),
            thoughts_token_count: lhs
                .thoughts_token_count
                .saturating_add(rhs.thoughts_token_count),
            total_token_count: lhs.total_token_count.saturating_add(rhs.total_token_count),
        }),
        (Some(lhs), None) => Some(lhs),
        (None, Some(rhs)) => Some(rhs),
        (None, None) => None,
    }
}

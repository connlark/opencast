use std::time::Duration;

use futures_util::future::join_all;
use worker::{console_error, Delay, Fetch, Headers, Method, Request, RequestInit, Response};

use crate::gemini::{parse_error_envelope, parse_generate_content_response};
use crate::prompt::{gemini_generate_content_url, gemini_request_payload, GeminiGenerationOptions};
use crate::retry::{classify_http_status, RetryDecision};
use crate::route::JSON_CONTENT_TYPE;
use crate::types::{
    AdAnalysisRequest, AdAnalysisResponse, ErrorResponse, GeminiUsage, POLICY_NAME, SCHEMA_VERSION,
};
use crate::validation::{combine_warnings, validate_model_output, ModelOutput};
use crate::windowing::analysis_windows;

const MAX_GEMINI_ATTEMPTS: usize = 5;

pub(crate) struct UpstreamError {
    pub status: u16,
    pub body: ErrorResponse,
}

struct WindowOutcome {
    output: Option<ModelOutput>,
    usage: Option<GeminiUsage>,
    warnings: Vec<String>,
    failure: Option<crate::gemini::GeminiParseError>,
}

pub(crate) async fn run_windows_analysis(
    gemini_api_key: &str,
    model: &str,
    request: AdAnalysisRequest,
) -> std::result::Result<AdAnalysisResponse, UpstreamError> {
    let gemini_url = gemini_generate_content_url(model);
    let mut combined_model_output = ModelOutput::from_spans(Vec::new());
    let mut combined_usage = None;
    let mut gemini_warnings = Vec::new();
    // At most four windows run concurrently, under the runtime's six-connection
    // cap. Folding in window order preserves the synchronous response contract.
    let window_outcomes = join_all(
        analysis_windows(&request)
            .into_iter()
            .map(|window| analyze_window(gemini_api_key, &gemini_url, window)),
    )
    .await;
    for outcome in window_outcomes {
        let outcome = outcome?;
        combined_usage = combine_usage(combined_usage, outcome.usage);
        gemini_warnings.extend(outcome.warnings);
        match outcome.output {
            Some(mut model_output) => {
                combined_model_output.spans.append(&mut model_output.spans);
                combined_model_output.malformed_span_count = combined_model_output
                    .malformed_span_count
                    .saturating_add(model_output.malformed_span_count);
            }
            None => {
                let code = outcome
                    .failure
                    .map(|failure| failure.code())
                    .unwrap_or("malformed_model_json");
                gemini_warnings.push(format!("{code}_skipped"));
            }
        }
    }

    let (spans, validation_warnings) = validate_model_output(&request, combined_model_output);
    Ok(AdAnalysisResponse {
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id,
        model: model.to_string(),
        policy: POLICY_NAME.to_string(),
        spans,
        warnings: combine_warnings(validation_warnings, gemini_warnings),
        usage: combined_usage,
    })
}

/// Malformed or truncated model output degrades a window to zero spans plus
/// warnings. Only transport-level failure of all attempts fails the request.
async fn analyze_window(
    gemini_api_key: &str,
    gemini_url: &str,
    window: AdAnalysisRequest,
) -> std::result::Result<WindowOutcome, UpstreamError> {
    let payload = gemini_request_payload(&window, GeminiGenerationOptions::default());
    let response_body = call_gemini_with_retry(gemini_api_key, gemini_url, &payload).await?;

    let mut usage = None;
    let mut warnings = Vec::new();
    let mut parsed = parse_generate_content_response(&response_body);
    if parsed.output.is_none() {
        if let Ok(retry_body) = call_gemini_with_retry(gemini_api_key, gemini_url, &payload).await {
            let retried = parse_generate_content_response(&retry_body);
            usage = combine_usage(usage, parsed.usage.take());
            warnings.append(&mut parsed.warnings);
            parsed = retried;
        }
    }

    usage = combine_usage(usage, parsed.usage);
    warnings.extend(parsed.warnings);
    Ok(WindowOutcome {
        output: parsed.output,
        usage,
        warnings,
        failure: parsed.failure,
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
    Fetch::Request(request).send().await.map_err(worker_error)
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
            total_token_count: lhs.total_token_count.saturating_add(rhs.total_token_count),
        }),
        (Some(lhs), None) => Some(lhs),
        (None, Some(rhs)) => Some(rhs),
        (None, None) => None,
    }
}

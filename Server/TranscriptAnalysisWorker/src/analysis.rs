use std::time::Duration;

use futures_util::{
    future::{select, Either},
    StreamExt,
};
use worker::{
    console_error, console_log, AbortController, Date, Delay, Fetch, Headers, Method, Request,
    RequestInit,
};

use crate::coalescing::{prepare_analysis_request, CoalescingError};
use crate::gemini::{parse_error_envelope, parse_generate_content_response, GeminiParseError};
use crate::prompt::{gemini_generate_content_url, gemini_request_payload, GeminiGenerationOptions};
use crate::retry::{
    classify_http_status, run_failure_error, AttemptFailure, LadderConfig, LadderStep,
    RetryDecision, RunBudget, TransportFailure, TransportLadder,
};
use crate::route::JSON_CONTENT_TYPE;
use crate::thinking::thinking_level_for_segment_count;
use crate::types::{
    AnalysisRunStats, GeminiUsage, TranscriptAnalysisRequest, TranscriptAnalysisResponse,
    POLICY_NAME, SCHEMA_VERSION,
};
use crate::validation::{combine_warnings, validate_and_remap_model_output};

pub(crate) use crate::types::UpstreamError;

/// Transport sends per analysis attempt (the inner ladder): fast failures
/// use all five with backoff, timeouts at most `retry::MAX_TIMEOUT_RESENDS`
/// resends. The per-call deadlines and the run budget live in `retry.rs`.
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
/// A schema-constrained reply of at most 32,768 output tokens is well under
/// this; anything larger is not a model reply the parser should hold.
const MAX_GEMINI_RESPONSE_BYTES: usize = 512 * 1024;

/// Single-shot only: partial/windowed context degrades chapter boundaries and
/// summaries. Dense transcripts above the validated raw envelope are
/// represented as coalesced units, validated in unit space, remapped, and
/// re-validated in original-id space. Parse, truncation, and hard-invalid
/// failures retry up to the validated three-attempt limit; every retry uses
/// high thinking.
///
/// `run_started_ms` anchors the run budget (`retry::RunBudget`): the
/// persisted job start for async runs, route entry for the inline lane.
///
/// The stats come back on BOTH arms: a failed run still made its attempts
/// and consumed its tokens, and the caller records that spend either way.
pub(crate) async fn run_analysis(
    gemini_api_key: &str,
    model: &str,
    request: TranscriptAnalysisRequest,
    ladder: LadderConfig,
    run_started_ms: u64,
) -> (
    std::result::Result<TranscriptAnalysisResponse, UpstreamError>,
    AnalysisRunStats,
) {
    let mut stats = AnalysisRunStats::default();
    let result = run_analysis_recording(
        gemini_api_key,
        model,
        request,
        ladder,
        run_started_ms,
        &mut stats,
    )
    .await;
    (result, stats)
}

async fn run_analysis_recording(
    gemini_api_key: &str,
    model: &str,
    request: TranscriptAnalysisRequest,
    ladder: LadderConfig,
    run_started_ms: u64,
    stats: &mut AnalysisRunStats,
) -> std::result::Result<TranscriptAnalysisResponse, UpstreamError> {
    let budget = RunBudget::start(ladder, run_started_ms);
    let gemini_url = gemini_generate_content_url(model);
    let prepared = prepare_analysis_request(&request).map_err(|error| match error {
        CoalescingError::TooManyUnits => UpstreamError::new(400, "transcript_too_long"),
    })?;
    let base_level = thinking_level_for_segment_count(prepared.model_request.segments.len());
    let raw_segment_count = request.segments.len();
    let model_unit_count = prepared.model_request.segments.len();
    let started_at_ms = now_ms();

    let mut gemini_warnings: Vec<String> = Vec::new();
    let mut last_failure: Option<AttemptFailure> = None;

    for attempt in 0..MAX_ANALYSIS_ATTEMPTS {
        // Attempt 0 uses the model-facing segment-count level; every retry
        // escalates to high (see MAX_ANALYSIS_ATTEMPTS). Rebuilt per attempt
        // so the level change reaches the payload; the prompt text is
        // identical across attempts (only generationConfig.thinkingLevel differs).
        let level = if attempt == 0 { base_level } else { "high" };
        let is_last = attempt + 1 == MAX_ANALYSIS_ATTEMPTS;

        // Budget gate before the attempt is counted: an attempt that cannot
        // start a call sent nothing and was billed for nothing. The run
        // then fails with the last failure it saw, or the deterministic
        // timeout code when nothing has failed yet.
        if budget.call_timeout(level, now_ms()).is_err() {
            stats.budget_exhausted = true;
            break;
        }
        let payload = gemini_request_payload(
            prepared.model_request.as_ref(),
            GeminiGenerationOptions {
                thinking_level: level,
                ..GeminiGenerationOptions::default()
            },
        );

        // Counted before the call: a transport-exhausted attempt may still
        // have been billed upstream, and the ladder position is what the
        // completion log line reports.
        stats.attempts = stats.attempts.saturating_add(1);
        let response_body = match call_gemini_with_retry(
            gemini_api_key,
            &gemini_url,
            &payload,
            level,
            &budget,
            stats,
        )
        .await
        {
            Ok(body) => body,
            Err(LadderError::Terminal(error)) => return Err(error),
            Err(LadderError::Budget(error)) => {
                stats.budget_exhausted = true;
                last_failure = Some(AttemptFailure::Transport(error));
                break;
            }
            Err(LadderError::Exhausted {
                error,
                delay_seconds,
            }) => {
                let code = error.code().to_string();
                last_failure = Some(AttemptFailure::Transport(error));
                if is_last {
                    continue;
                }
                // The spent ladder's last failure may have asked for a pause
                // (`Retry-After`, or its backoff step). It is honoured across
                // the attempt boundary, from the same budget, so the escalated
                // attempt does not spend its first send on an upstream that
                // just said it was not ready.
                if delay_seconds > 0 {
                    let Ok(delay) = budget.backoff(delay_seconds, now_ms()) else {
                        stats.budget_exhausted = true;
                        break;
                    };
                    Delay::from(delay).await;
                }
                // `_high`: the next attempt runs at high thinking.
                gemini_warnings.push(format!("{code}_retried_high"));
                continue;
            }
        };
        let mut parsed = parse_generate_content_response(&response_body);
        stats.usage = combine_usage(stats.usage.take(), parsed.usage.take());
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
                        usage: stats.usage.clone(),
                    };
                    console_log!(
                        "{}",
                        crate::job::completion_log_line(
                            &response,
                            raw_segment_count,
                            model_unit_count,
                            attempt + 1,
                            now_ms().saturating_sub(started_at_ms),
                        )
                    );
                    return Ok(response);
                }
                Err(violations) => {
                    // Client detail and response warnings contain fixed rule
                    // codes only, never model text or violation details.
                    let rules = violations
                        .iter()
                        .map(|violation| violation.rule)
                        .collect::<Vec<_>>();
                    stats.rejected.record_validation(&rules);
                    let codes = rules.join(",");
                    if !is_last {
                        gemini_warnings.push(format!("invalid_model_output_retried_high:{codes}"));
                    }
                    last_failure = Some(AttemptFailure::Validation(codes));
                }
            },
            None => {
                let failure = parsed
                    .failure
                    .unwrap_or(GeminiParseError::MalformedModelJson);
                stats.rejected.record_parse(&failure);
                if !is_last {
                    gemini_warnings.push(format!("{}_retried_high", failure.code()));
                }
                last_failure = Some(AttemptFailure::Parse(failure));
            }
        }
    }

    Err(run_failure_error(last_failure))
}

/// How one transport ladder ended without a 2xx body.
enum LadderError {
    /// A failure no resend can fix (hard quota, a non-retryable status, a
    /// local payload error): the run ends with this error.
    Terminal(UpstreamError),
    /// The ladder gave up (two timeouts, or five fast failures): the run
    /// moves to its next attempt while budget remains, after the pause the
    /// last failure asked for (`delay_seconds`, zero after a timeout).
    Exhausted {
        error: UpstreamError,
        delay_seconds: u64,
    },
    /// The run budget cannot fit another call: the run ends with the last
    /// failure the ladder saw.
    Budget(UpstreamError),
}

/// One analysis attempt's transport ladder. Timeouts abort the upstream
/// request and resend the identical payload once, immediately; fast
/// failures (5xx, retryable 429, fetch rejection) back off and resend up to
/// `MAX_GEMINI_ATTEMPTS` sends in total. Every deadline and sleep is cut
/// from the run budget.
async fn call_gemini_with_retry(
    gemini_api_key: &str,
    gemini_url: &str,
    payload: &serde_json::Value,
    level: &str,
    budget: &RunBudget,
    stats: &mut AnalysisRunStats,
) -> std::result::Result<String, LadderError> {
    let payload_string = serde_json::to_string(payload).map_err(|error| {
        LadderError::Terminal(UpstreamError::with_detail(
            500,
            "gemini_payload_error",
            error.to_string(),
        ))
    })?;
    let mut ladder = TransportLadder::new(MAX_GEMINI_ATTEMPTS, budget.config().max_timeout_resends);
    // Budget exhaustion before any failure reads as a timeout: the budget
    // is time, and nothing else has gone wrong.
    let mut last_error = UpstreamError::new(503, "gemini_timeout");
    let mut resending = false;

    loop {
        let Ok(timeout) = budget.call_timeout(level, now_ms()) else {
            return Err(LadderError::Budget(last_error));
        };
        // Counted only for a resend that actually goes out: a resend the
        // budget refuses above sent nothing.
        if resending {
            stats.transport_retries = stats.transport_retries.saturating_add(1);
        }
        let failure =
            match call_gemini_once(gemini_api_key, gemini_url, &payload_string, timeout).await {
                Ok(reply) => {
                    if (200..300).contains(&reply.status) {
                        return Ok(reply.text);
                    }
                    let error_body = parse_error_envelope(&reply.text);
                    match classify_http_status(
                        reply.status,
                        reply.retry_after.as_deref(),
                        error_body.as_ref(),
                    ) {
                        RetryDecision::Retry {
                            retry_after_seconds,
                        } => {
                            last_error = UpstreamError::new(503, "gemini_retry_exhausted");
                            TransportFailure::RetryableStatus {
                                retry_after_seconds,
                            }
                        }
                        RetryDecision::HardQuota => {
                            return Err(LadderError::Terminal(UpstreamError::new(
                                503,
                                "gemini_quota_exhausted",
                            )));
                        }
                        RetryDecision::DoNotRetry => {
                            return Err(LadderError::Terminal(UpstreamError::with_detail(
                                upstream_status(reply.status),
                                "gemini_http_error",
                                format!("status {}", reply.status),
                            )));
                        }
                    }
                }
                Err(CallFailure::Timeout) => {
                    stats.gemini_call_timeouts = stats.gemini_call_timeouts.saturating_add(1);
                    // Content-free: the level and the deadline only.
                    console_error!(
                        "Gemini call timed out at {level} thinking after {} s",
                        timeout.as_secs()
                    );
                    last_error = UpstreamError::new(503, "gemini_timeout");
                    TransportFailure::Timeout
                }
                Err(CallFailure::Fetch) => {
                    last_error = UpstreamError::new(502, "worker_fetch_error");
                    TransportFailure::FetchError
                }
                Err(CallFailure::Terminal(error)) => return Err(LadderError::Terminal(error)),
            };

        match ladder.next_after(failure) {
            LadderStep::GiveUp { delay_seconds } => {
                return Err(LadderError::Exhausted {
                    error: last_error,
                    delay_seconds,
                });
            }
            LadderStep::Resend { delay_seconds } => {
                if delay_seconds > 0 {
                    let Ok(delay) = budget.backoff(delay_seconds, now_ms()) else {
                        return Err(LadderError::Budget(last_error));
                    };
                    Delay::from(delay).await;
                }
                resending = true;
            }
        }
    }
}

/// One Gemini reply, fully read: status, `Retry-After`, and the body text.
struct GeminiReply {
    status: u16,
    retry_after: Option<String>,
    text: String,
}

/// Transport classification for one send. Timeouts and fetch failures enter
/// the ladder; everything local that a resend cannot fix is terminal.
enum CallFailure {
    /// The deadline elapsed before the exchange completed; the request was
    /// aborted.
    Timeout,
    /// The fetch was rejected or the body stream failed.
    Fetch,
    /// A local request/serialization error, an oversized body, or a body
    /// that is not UTF-8.
    Terminal(UpstreamError),
}

struct AbortOnDrop(Option<AbortController>);
impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        if let Some(controller) = self.0.take() {
            controller.abort();
        }
    }
}

/// One send under `timeout`. The deadline covers the whole exchange, the
/// send AND the body read: headers that arrive promptly followed by a
/// stalled body must not escape the ladder arithmetic the run budget relies
/// on. A deadline that fires aborts the upstream request, so the runtime
/// stops waiting on it and the resend is the only request in flight.
async fn call_gemini_once(
    gemini_api_key: &str,
    gemini_url: &str,
    payload_string: &str,
    timeout: Duration,
) -> std::result::Result<GeminiReply, CallFailure> {
    let headers = Headers::new();
    headers
        .set("content-type", JSON_CONTENT_TYPE)
        .map_err(local_request_error)?;
    headers
        .set("x-goog-api-key", gemini_api_key)
        .map_err(local_request_error)?;

    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(payload_string.into()));

    let request = Request::new_with_init(gemini_url, &init).map_err(local_request_error)?;
    let controller = AbortController::default();
    let signal = controller.signal();
    let mut abort = AbortOnDrop(Some(controller));
    let exchange = std::pin::pin!(async move {
        let fetch = Fetch::Request(request);
        let mut response = fetch.send_with_signal(&signal).await.map_err(fetch_error)?;
        let status = response.status_code();
        let retry_after = response.headers().get("retry-after").ok().flatten();
        let mut stream = response.stream().map_err(fetch_error)?;
        let mut bytes = Vec::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(fetch_error)?;
            if bytes.len().saturating_add(chunk.len()) > MAX_GEMINI_RESPONSE_BYTES {
                return Err(CallFailure::Terminal(UpstreamError::new(
                    503,
                    "gemini_response_oversized",
                )));
            }
            bytes.extend_from_slice(&chunk);
        }
        let text = String::from_utf8(bytes).map_err(|_| {
            CallFailure::Terminal(UpstreamError::new(503, "gemini_response_encoding"))
        })?;
        Ok(GeminiReply {
            status,
            retry_after,
            text,
        })
    });
    let deadline = std::pin::pin!(Delay::from(timeout));
    match select(exchange, deadline).await {
        Either::Left((result, _)) => {
            // The exchange has already ended. Aborting its completed stream
            // here can re-enter the runtime's stream completion callback.
            abort.0 = None;
            result
        }
        Either::Right(((), _)) => Err(CallFailure::Timeout),
    }
}

fn fetch_error(error: worker::Error) -> CallFailure {
    console_error!("Worker error: {error:?}");
    CallFailure::Fetch
}

fn local_request_error(error: worker::Error) -> CallFailure {
    console_error!("Gemini request construction failed: {error:?}");
    CallFailure::Terminal(UpstreamError::with_detail(
        500,
        "gemini_payload_error",
        "request construction failed",
    ))
}

fn now_ms() -> u64 {
    Date::now().as_millis()
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

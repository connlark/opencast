use futures_util::{stream::FuturesUnordered, StreamExt};
use serde_json::json;
use std::rc::Rc;

use crate::analysis::{call_gemini_once, combine_usage, UpstreamError};
use crate::execution::{failure, Execution};
use crate::policy::{V3_INITIAL_ATTEMPTS, V3_MODEL, V3_THINKING};
use crate::promo_v3::{self, Output, Validation};
use crate::retry::{backoff_seconds, classify_http_status, RetryDecision};
use crate::types::{
    AdAnalysisRequest, AdAnalysisResponse, ErrorResponse, GeminiUsage, SCHEMA_VERSION,
};

struct WindowOutcome {
    output: Output,
    usage: Option<GeminiUsage>,
    notices: Vec<String>,
}

pub(crate) async fn run(
    request: AdAnalysisRequest,
    key: &str,
    execution: Rc<Execution>,
) -> Result<AdAnalysisResponse, UpstreamError> {
    let windows = crate::v3_windowing::analysis_windows(&request);
    let single = windows.len() == 1;
    let mut remaining = windows.into_iter().enumerate();
    let mut pending = FuturesUnordered::new();
    for (index, window) in remaining
        .by_ref()
        .take(crate::v3_windowing::CONCURRENT_WINDOWS)
    {
        pending.push(analyze_window(index, window, key, &execution, single));
    }
    let mut outcomes = Vec::new();
    while let Some(outcome) = pending.next().await {
        match outcome {
            Ok(outcome) => outcomes.push(outcome),
            Err(error) => {
                execution.cancel();
                // Dropping the remaining futures aborts real fetch/body reads.
                // Already dispatched calls retain their unknown-usage charge.
                drop(pending);
                return Err(error);
            }
        }
        if let Some((index, window)) = remaining.next() {
            pending.push(analyze_window(index, window, key, &execution, single));
        }
    }
    outcomes.sort_by_key(|(index, _)| *index);
    let mut output = Output { spans: Vec::new() };
    let mut usage = None;
    let mut notices = Vec::new();
    for (_, mut outcome) in outcomes {
        output.spans.append(&mut outcome.output.spans);
        usage = combine_usage(usage, outcome.usage);
        notices.append(&mut outcome.notices);
    }
    // Multi-window global alarms have no isolated corrective scope. Stop with
    // evidence intact; never buy a blanket episode replay or publish a subset.
    let mut validated = promo_v3::validate(&request, output);
    if !validated.is_complete() {
        return Err(incomplete(&validated.issues));
    }
    notices.append(&mut validated.notices);
    notices.sort();
    notices.dedup();
    Ok(AdAnalysisResponse {
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id,
        model: V3_MODEL.into(),
        policy: promo_v3::POLICY.into(),
        policy_revision: Some(crate::policy::V3_REVISION.into()),
        accounting: None,
        spans: validated.spans,
        warnings: notices,
        usage,
    })
}

async fn analyze_window(
    index: usize,
    window: AdAnalysisRequest,
    key: &str,
    execution: &Execution,
    single: bool,
) -> Result<(usize, WindowOutcome), UpstreamError> {
    let payload = promo_v3::payload(&window, Some(V3_THINKING));
    let body = call(
        key,
        &payload,
        index as u8 * 3,
        V3_INITIAL_ATTEMPTS,
        execution,
    )
    .await?;
    let mut first = promo_v3::parse_response(&body);
    // A single-window global coverage/budget alarm gets the SAME one bounded
    // corrective opportunity as a receipt error, preserving both evidence gates.
    let validate = |output: Output| {
        if single {
            promo_v3::validate(&window, output)
        } else {
            promo_v3::validate_window(&window, output)
        }
    };
    let validation = first
        .output
        .as_ref()
        .map(|o| validate(o.clone()))
        .unwrap_or_else(|| Validation {
            issues: vec![first.issue.unwrap_or("v3_missing_output").into()],
            ..Validation::default()
        });
    if validation.is_complete() {
        return Ok((
            index,
            WindowOutcome {
                output: first.output.unwrap(),
                usage: first.usage,
                notices: validation.notices,
            },
        ));
    }
    execution.check()?;
    let previous = first
        .output
        .as_ref()
        .map(|o| serde_json::to_value(o).unwrap())
        .unwrap_or(json!({"unusable_previous_output": true}));
    let corrective =
        promo_v3::repair_payload(payload, &previous, &validation.issues).map_err(failure)?;
    let body = call(
        key,
        &corrective,
        index as u8 * 3 + 2,
        crate::policy::V3_REPAIR_ATTEMPTS,
        execution,
    )
    .await?;
    let repaired = promo_v3::parse_response(&body);
    let usage = combine_usage(first.usage.take(), repaired.usage);
    let Some(output) = repaired.output else {
        return Err(incomplete(&[repaired
            .issue
            .unwrap_or("v3_missing_output")
            .into()]));
    };
    let mut checked = validate(output.clone());
    if !promo_v3::preserves_verified_breaks(&validation, &checked)
        || first.output.as_ref().is_some_and(|old| {
            checked.is_complete() && !promo_v3::preserves_candidate_evidence(&window, old, &output)
        })
    {
        checked.issues.push("v3_repair_lost_candidate".into());
    }
    if !checked.is_complete() {
        return Err(incomplete(&checked.issues));
    }
    checked.notices.push("v3_semantic_repair".into());
    Ok((
        index,
        WindowOutcome {
            output,
            usage,
            notices: checked.notices,
        },
    ))
}

async fn call(
    key: &str,
    payload: &serde_json::Value,
    attempt_id: u8,
    attempts: usize,
    execution: &Execution,
) -> Result<String, UpstreamError> {
    let serialized = payload.to_string();
    let estimate = (serialized.chars().count() as u64).div_ceil(4);
    let url = crate::prompt::gemini_generate_content_url(V3_MODEL);
    for attempt in 0..attempts {
        let id = attempt_id + attempt as u8;
        execution.dispatch(id, estimate).await?;
        let response = call_gemini_once(key, &url, &serialized, execution.call_timeout()?).await;
        let delay = match response {
            Ok(reply) => {
                // Record receipts before semantic validation, including failed
                // windows and non-2xx bodies that carry valid usage metadata.
                execution
                    .receipt(id, promo_v3::parse_response(&reply.text).usage)
                    .await?;
                if (200..300).contains(&reply.status) {
                    return Ok(reply.text);
                }
                let error = crate::gemini::parse_error_envelope(&reply.text);
                match classify_http_status(
                    reply.status,
                    reply.retry_after.as_deref(),
                    error.as_ref(),
                ) {
                    RetryDecision::HardQuota => return Err(failure("gemini_quota_exhausted")),
                    RetryDecision::DoNotRetry => return Err(failure("gemini_http_error")),
                    RetryDecision::Retry {
                        retry_after_seconds,
                    } => retry_after_seconds.unwrap_or_else(|| backoff_seconds(attempt + 1)),
                }
            }
            Err(error) => {
                if attempt + 1 == attempts {
                    return Err(error);
                }
                backoff_seconds(attempt + 1)
            }
        };
        if attempt + 1 == attempts {
            return Err(failure("gemini_retry_exhausted"));
        }
        execution.backoff(delay).await?;
    }
    Err(failure("gemini_retry_exhausted"))
}

fn incomplete(issues: &[String]) -> UpstreamError {
    // Codes/IDs only; bounded independently of provider/transcript size.
    worker::console_error!(
        "{}",
        serde_json::json!({"event":"ad_analysis_incomplete", "issues":issues.iter().take(64).collect::<Vec<_>>() })
    );
    UpstreamError {
        status: 422,
        body: ErrorResponse::new("ad_analysis_incomplete"),
    }
}

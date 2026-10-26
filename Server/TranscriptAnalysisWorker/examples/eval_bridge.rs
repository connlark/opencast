//! Local, network-free replay oracle for the chapters pipeline.
//!
//! The orchestration (`analysis::run_analysis_recording`) is wasm-only, so
//! `run` restates its attempt loop sequentially, without transport, budget,
//! clock or logging, over the library's real functions, feeding recorded
//! provider bodies in place of model calls. `render` and `validate` expose
//! the steps it is built from. One JSON command on stdin, one JSON line out.
use opencast_transcript_analysis_worker::{
    coalescing::{prepare_analysis_request, CoalescingError, PreparedAnalysisRequest},
    gemini::{parse_generate_content_response, GeminiParseError, ParsedModelResponse},
    prompt::{gemini_request_payload, GeminiGenerationOptions},
    retry::{run_failure_error, AttemptFailure},
    thinking::thinking_level_for_segment_count,
    types::{
        ErrorResponse, GeminiUsage, TranscriptAnalysisRequest, TranscriptAnalysisResponse,
        UpstreamError, POLICY_NAME, SCHEMA_VERSION,
    },
    validation::{
        combine_warnings, validate_and_remap_model_output, validate_request, HardViolation,
        ValidatedAnalysis,
    },
};
use serde_json::{json, Value};
use std::error::Error;
use std::io::{self, Read};

/// Full model requests per run: the base level, then two at `high`.
const MAX_ANALYSIS_ATTEMPTS: usize = 3;

fn main() -> Result<(), Box<dyn Error>> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let command: Value = serde_json::from_str(&input)?;
    let request: TranscriptAnalysisRequest = serde_json::from_value(command["request"].clone())?;
    let result = match command["op"].as_str().ok_or("missing op")? {
        "render" => render(&request),
        "validate" => {
            let body = command["body"].as_str().ok_or("missing body")?;
            let mut parsed = parse_generate_content_response(body);
            let has_output = parsed.output.is_some();
            let result = match parsed.output.take() {
                None => Value::Null,
                Some(output) => match prepare_analysis_request(&request) {
                    Err(CoalescingError::TooManyUnits) => json!({"error": "transcript_too_long"}),
                    Ok(prepared) => result_json(&validate_and_remap_model_output(
                        &request, &prepared, output,
                    )),
                },
            };
            json!({"parse": parse_json(&parsed, has_output), "result": result})
        }
        "run" => {
            let model = command["model"].as_str().ok_or("missing model")?;
            let replies = command["replies"].as_array().ok_or("missing replies")?;
            run(&request, model, replies)?
        }
        _ => return Err("unknown op".into()),
    };
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

fn payload(prepared: &PreparedAnalysisRequest<'_>, level: &'static str) -> Value {
    gemini_request_payload(
        prepared.model_request.as_ref(),
        GeminiGenerationOptions {
            thinking_level: level,
            ..GeminiGenerationOptions::default()
        },
    )
}

fn render(request: &TranscriptAnalysisRequest) -> Value {
    let (request_error, estimated_input_tokens) = match validate_request(request.clone()) {
        Ok(validated) => (None, Some(validated.estimate.estimated_input_tokens)),
        Err(error) => (Some(error.code()), None),
    };
    let prepared = match prepare_analysis_request(request) {
        Ok(prepared) => prepared,
        Err(CoalescingError::TooManyUnits) => {
            return json!({
                "request_error": request_error,
                "estimated_input_tokens": estimated_input_tokens,
                "error": "transcript_too_long", "coalesced": null, "model_request": null,
                "remap": null, "base_level": null, "payloads": null,
            });
        }
    };
    let base_level = thinking_level_for_segment_count(prepared.model_request.segments.len());
    let remap = prepared.remap.as_ref().map(|remap| {
        remap
            .iter()
            .map(|unit| [unit.original_start_id, unit.original_end_id])
            .collect::<Vec<_>>()
    });
    json!({
        "request_error": request_error,
        "estimated_input_tokens": estimated_input_tokens,
        "error": null,
        "coalesced": prepared.remap.is_some(),
        "model_request": prepared.model_request.as_ref(),
        "remap": remap,
        "base_level": base_level,
        "payloads": {"base": payload(&prepared, base_level), "high": payload(&prepared, "high")},
    })
}

/// The parse half of the `validate` object. Call before `usage` and
/// `warnings` are taken from `parsed`.
fn parse_json(parsed: &ParsedModelResponse, has_output: bool) -> Value {
    json!({
        "failure": parsed.failure.as_ref().map(GeminiParseError::code),
        "warnings": parsed.warnings,
        "usage": parsed.usage,
        "has_output": has_output,
    })
}

fn result_json(result: &Result<ValidatedAnalysis, Vec<HardViolation>>) -> Value {
    match result {
        Ok(validated) => json!({"ok": {
            "chapters": validated.chapters, "summary": validated.summary,
            "warnings": validated.warnings,
        }}),
        Err(violations) => json!({"violations": violations
            .iter()
            .map(|violation| json!({"rule": violation.rule, "detail": violation.detail}))
            .collect::<Vec<_>>()}),
    }
}

fn error_json(error: &UpstreamError) -> Value {
    json!({"error": {"status": error.status, "body": error.body}})
}

/// The serving path's usage fold: saturating per field, absent sides skipped.
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

/// The attempt loop. Each reply stands for the 2xx body of one attempt's
/// transport ladder; an absent or null reply stops the run.
fn run(
    request: &TranscriptAnalysisRequest,
    model: &str,
    replies: &[Value],
) -> Result<Value, Box<dyn Error>> {
    let mut attempts = Vec::new();
    let prepared = match prepare_analysis_request(request) {
        Ok(prepared) => prepared,
        Err(CoalescingError::TooManyUnits) => {
            let error = UpstreamError::new(400, "transcript_too_long");
            return Ok(json!({
                "attempts": attempts, "result": error_json(&error), "response_json": null,
            }));
        }
    };
    let base_level = thinking_level_for_segment_count(prepared.model_request.segments.len());
    let mut usage: Option<GeminiUsage> = None;
    let mut gemini_warnings: Vec<String> = Vec::new();
    let mut last_failure: Option<AttemptFailure> = None;

    for attempt in 0..MAX_ANALYSIS_ATTEMPTS {
        let level = if attempt == 0 { base_level } else { "high" };
        let is_last = attempt + 1 == MAX_ANALYSIS_ATTEMPTS;
        let payload = payload(&prepared, level);
        let body = match replies.get(attempt).unwrap_or(&Value::Null) {
            Value::Null => {
                let missing = json!({"error": {
                    "status": 0, "body": ErrorResponse::new("replay_missing_reply"),
                }});
                return Ok(json!({"attempts": attempts, "result": missing, "response_json": null}));
            }
            Value::String(body) => body,
            _ => return Err(format!("reply {attempt} must be a string or null").into()),
        };
        let mut parsed = parse_generate_content_response(body);
        let has_output = parsed.output.is_some();
        let validated = parsed
            .output
            .take()
            .map(|output| validate_and_remap_model_output(request, &prepared, output));
        attempts.push(json!({
            "attempt": attempt, "level": level, "payload": payload,
            "validate": {
                "parse": parse_json(&parsed, has_output),
                "result": validated.as_ref().map(result_json),
            },
        }));
        usage = combine_usage(usage, parsed.usage.take());
        gemini_warnings.append(&mut parsed.warnings);

        match validated {
            Some(Ok(validated)) => {
                let response = TranscriptAnalysisResponse {
                    schema_version: SCHEMA_VERSION,
                    request_id: request.request_id.clone(),
                    model: model.to_string(),
                    policy: POLICY_NAME.to_string(),
                    chapters: validated.chapters,
                    summary: Some(validated.summary),
                    warnings: combine_warnings(validated.warnings, gemini_warnings),
                    usage,
                };
                let response_json = serde_json::to_string(&response)?;
                return Ok(json!({
                    "attempts": attempts, "result": {"response": response},
                    "response_json": response_json,
                }));
            }
            Some(Err(violations)) => {
                let rules = violations
                    .iter()
                    .map(|violation| violation.rule)
                    .collect::<Vec<_>>();
                let codes = rules.join(",");
                if !is_last {
                    gemini_warnings.push(format!("invalid_model_output_retried_high:{codes}"));
                }
                last_failure = Some(AttemptFailure::Validation(codes));
            }
            None => {
                let failure = parsed
                    .failure
                    .unwrap_or(GeminiParseError::MalformedModelJson);
                if !is_last {
                    gemini_warnings.push(format!("{}_retried_high", failure.code()));
                }
                last_failure = Some(AttemptFailure::Parse(failure));
            }
        }
    }

    let error = run_failure_error(last_failure);
    Ok(json!({"attempts": attempts, "result": error_json(&error), "response_json": null}))
}

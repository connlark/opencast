//! Local, network-free adapter: evals use the exact serving prompt/validator.
//!
//! `parse` and `replay` are replay oracles. The v3 orchestration
//! (`v3_analysis::run` and `analyze_window`) is wasm-only, so `replay`
//! restates its control flow sequentially and without transport over the
//! library's real functions, feeding recorded provider bodies in place of
//! model calls. Every window is evaluated, even after one fails, and the
//! lowest-index failure is the result. `char_classes` reports, for every
//! scalar, what the receipt tokenizer and `str::trim` make of it, and
//! `preserves` runs the two repair-preservation checks on their own.
use opencast_ad_analysis_worker::{
    promo_v3::{self, Output, Validation},
    prompt,
    types::{AdAnalysisRequest, AdAnalysisResponse, ErrorResponse, GeminiUsage, SCHEMA_VERSION},
    v3_windowing, validation, windowing,
};
use serde_json::{json, Value};
use std::error::Error;
use std::io::{self, Read};

fn main() -> Result<(), Box<dyn Error>> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let command: Value = serde_json::from_str(&input)?;
    let result = match command["op"].as_str() {
        Some("parse") => {
            let body = command["body"].as_str().ok_or("missing body")?;
            parsed_json(&promo_v3::parse_response(body))
        }
        Some("replay") => replay(&command)?,
        Some("char_classes") => char_classes(),
        Some("preserves") => preserves(&command)?,
        _ => legacy(&command)?,
    };
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}

/// Ranges `[first, last]` of the scalars the receipt tokenizer keeps
/// (alphanumeric), of those `str::trim` removes (whitespace), and every
/// scalar whose token differs from itself (its lowercase form).
fn char_classes() -> Value {
    fn push_range(ranges: &mut Vec<[u32; 2]>, value: u32) {
        match ranges.last_mut() {
            Some(last) if last[1] + 1 == value => last[1] = value,
            _ => ranges.push([value, value]),
        }
    }
    let mut alphanumeric = Vec::new();
    let mut whitespace = Vec::new();
    let mut lowercase = Vec::new();
    for value in 0..=0x10FFFFu32 {
        let Some(character) = char::from_u32(value) else {
            continue;
        };
        let text = character.to_string();
        let tokens = promo_v3::normalized_receipt_tokens(&text);
        if let Some(token) = tokens.first() {
            push_range(&mut alphanumeric, value);
            if *token != text {
                lowercase.push(json!([
                    value,
                    token.chars().map(|c| c as u32).collect::<Vec<_>>()
                ]));
            }
        }
        if text.trim().is_empty() {
            push_range(&mut whitespace, value);
        }
    }
    json!({"alphanumeric": alphanumeric, "whitespace": whitespace, "lowercase": lowercase})
}

/// Both repair-preservation checks for one window: verified breaks are
/// compared on the window validations, candidate evidence only when the
/// repaired answer validates (the check indexes its segments).
fn preserves(command: &Value) -> Result<Value, Box<dyn Error>> {
    let request: AdAnalysisRequest = serde_json::from_value(command["request"].clone())?;
    let before: Output = serde_json::from_value(command["before"].clone())?;
    let after: Output = serde_json::from_value(command["after"].clone())?;
    let old = promo_v3::validate_window(&request, before.clone());
    let checked = promo_v3::validate_window(&request, after.clone());
    let evidence = checked
        .is_complete()
        .then(|| promo_v3::preserves_candidate_evidence(&request, &before, &after));
    Ok(json!({
        "verified_breaks": promo_v3::preserves_verified_breaks(&old, &checked),
        "candidate_evidence": evidence,
    }))
}

/// The original ops, unchanged: each requires `request`.
fn legacy(command: &Value) -> Result<Value, Box<dyn Error>> {
    let request: AdAnalysisRequest = serde_json::from_value(command["request"].clone())?;
    let v3 = command["policy"] == promo_v3::POLICY;
    let result = match command["op"].as_str().ok_or("missing op")? {
        "repair" => promo_v3::repair_payload(
            command["payload"].clone(),
            &command["output"],
            &serde_json::from_value::<Vec<String>>(command["issues"].clone())?,
        )?,
        "check_repair" => {
            let before: promo_v3::Output = serde_json::from_value(command["before"].clone())?;
            let after: promo_v3::Output = serde_json::from_value(command["output"].clone())?;
            let old = promo_v3::validate_window(&request, before.clone());
            let mut checked = promo_v3::validate_window(&request, after.clone());
            if !promo_v3::preserves_verified_breaks(&old, &checked)
                || (checked.is_complete()
                    && !promo_v3::preserves_candidate_evidence(&request, &before, &after))
            {
                checked.issues.push("v3_repair_lost_candidate".into());
            }
            json!({"complete":checked.is_complete(),"spans":checked.spans,"warnings":checked.issues,"notices":checked.notices})
        }
        "prepare" => {
            json!({"windows":(if v3 {opencast_ad_analysis_worker::v3_windowing::analysis_windows(&request)} else {windowing::analysis_windows(&request)}).iter().map(|w|{
            let payload=if v3 {promo_v3::payload(w,command["thinking"].as_str())} else {prompt::gemini_request_payload(w,prompt::GeminiGenerationOptions::default())};
            json!({"request":w,"payload":payload})
        }).collect::<Vec<_>>()})
        }
        "validate" => {
            if v3 {
                let result =
                    match serde_json::from_value::<promo_v3::Output>(command["output"].clone()) {
                        Ok(output) if command["window"] == true => {
                            promo_v3::validate_window(&request, output)
                        }
                        Ok(output) => promo_v3::validate(&request, output),
                        Err(_) => promo_v3::Validation {
                            issues: vec!["v3_malformed_model_json".into()],
                            ..Default::default()
                        },
                    };
                json!({"complete":result.is_complete(),"spans":result.spans,"warnings":result.issues,"notices":result.notices})
            } else {
                let output: validation::ModelOutput =
                    serde_json::from_value(command["output"].clone())?;
                let (spans, warnings) = validation::validate_model_output(&request, output);
                json!({"complete":warnings.is_empty(),"spans":spans,"warnings":warnings})
            }
        }
        _ => return Err("unknown op".into()),
    };
    Ok(result)
}

fn parsed_json(parsed: &promo_v3::ParsedResponse) -> Value {
    json!({"issue": parsed.issue, "usage": parsed.usage, "output": parsed.output})
}

/// The same shape the `validate` op emits.
fn validation_json(validation: &Validation) -> Value {
    json!({
        "complete": validation.is_complete(), "spans": validation.spans,
        "warnings": validation.issues, "notices": validation.notices,
    })
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

/// A recorded provider body; an absent or null entry means the call never
/// produced one.
fn recorded<'a>(replies: &'a Value, key: &str) -> Result<Option<&'a str>, Box<dyn Error>> {
    match &replies[key] {
        Value::Null => Ok(None),
        Value::String(body) => Ok(Some(body)),
        _ => Err(format!("reply {key} must be a string or null").into()),
    }
}

struct WindowOutcome {
    output: Output,
    usage: Option<GeminiUsage>,
    notices: Vec<String>,
}

struct WindowFailure {
    code: String,
    issues: Vec<String>,
    /// Usage of the calls this window made before it failed.
    usage: Option<GeminiUsage>,
}

fn failed(code: &str, issues: Vec<String>, usage: Option<GeminiUsage>) -> WindowFailure {
    WindowFailure {
        code: code.into(),
        issues,
        usage,
    }
}

fn replay(command: &Value) -> Result<Value, Box<dyn Error>> {
    let request: AdAnalysisRequest = serde_json::from_value(command["request"].clone())?;
    let thinking = command["thinking"].as_str();
    let model = command["model"].as_str().ok_or("missing model")?;
    let policy_revision = command["policy_revision"]
        .as_str()
        .ok_or("missing policy_revision")?;
    let replies = &command["replies"];
    if !replies.is_object() {
        return Err("missing replies".into());
    }
    let windows = v3_windowing::analysis_windows(&request);
    let single = windows.len() == 1;
    let mut records = Vec::new();
    let mut outcomes = Vec::new();
    for (index, window) in windows.iter().enumerate() {
        let mut record = json!({"index": index, "initial": null, "repair": null});
        let outcome = replay_window(index, window, thinking, replies, single, &mut record)?;
        record["outcome"] = match &outcome {
            Ok(ok) => json!({
                "status": "ok", "code": null, "issues": [],
                "notices": ok.notices, "usage": ok.usage,
            }),
            Err(failure) => json!({
                "status": "failed", "code": failure.code, "issues": failure.issues,
                "notices": [], "usage": failure.usage,
            }),
        };
        records.push(record);
        outcomes.push(outcome);
    }
    let (result, response_json) = merge(&request, model, policy_revision, outcomes)?;
    Ok(json!({"windows": records, "result": result, "response_json": response_json}))
}

/// `analyze_window` without transport: one initial reply, then at most one
/// corrective reply when the initial answer is incomplete.
fn replay_window(
    index: usize,
    window: &AdAnalysisRequest,
    thinking: Option<&str>,
    replies: &Value,
    single: bool,
    record: &mut Value,
) -> Result<Result<WindowOutcome, WindowFailure>, Box<dyn Error>> {
    let payload = promo_v3::payload(window, thinking);
    record["payload"] = payload.clone();
    let Some(body) = recorded(replies, &format!("window-{index}"))? else {
        return Ok(Err(failed("replay_missing_reply", Vec::new(), None)));
    };
    let mut first = promo_v3::parse_response(body);
    // A single-window global alarm gets the same corrective opportunity.
    let validate = |output: Output| {
        if single {
            promo_v3::validate(window, output)
        } else {
            promo_v3::validate_window(window, output)
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
    let mut initial = parsed_json(&first);
    initial["validation"] = validation_json(&validation);
    record["initial"] = initial;
    if validation.is_complete() {
        return Ok(Ok(WindowOutcome {
            output: first.output.unwrap(),
            usage: first.usage,
            notices: validation.notices,
        }));
    }
    let mut repair = json!({
        "payload": null, "payload_error": null, "reply": false,
        "issue": null, "usage": null, "output": null, "validation": null,
    });
    let previous = first
        .output
        .as_ref()
        .map(|o| serde_json::to_value(o).unwrap())
        .unwrap_or(json!({"unusable_previous_output": true}));
    let corrective = match promo_v3::repair_payload(payload, &previous, &validation.issues) {
        Ok(corrective) => corrective,
        Err(code) => {
            repair["payload_error"] = json!(code);
            record["repair"] = repair;
            return Ok(Err(failed(code, validation.issues, first.usage)));
        }
    };
    repair["payload"] = corrective;
    let Some(body) = recorded(replies, &format!("repair-{index}"))? else {
        record["repair"] = repair;
        return Ok(Err(failed(
            "replay_missing_reply",
            validation.issues,
            first.usage,
        )));
    };
    let repaired = promo_v3::parse_response(body);
    let reply = parsed_json(&repaired);
    for key in ["issue", "usage", "output"] {
        repair[key] = reply[key].clone();
    }
    repair["reply"] = json!(true);
    let usage = combine_usage(first.usage.take(), repaired.usage);
    let Some(output) = repaired.output else {
        record["repair"] = repair;
        let issue = repaired.issue.unwrap_or("v3_missing_output");
        return Ok(Err(failed(
            "ad_analysis_incomplete",
            vec![issue.into()],
            usage,
        )));
    };
    let mut checked = validate(output.clone());
    if !promo_v3::preserves_verified_breaks(&validation, &checked)
        || first.output.as_ref().is_some_and(|old| {
            checked.is_complete() && !promo_v3::preserves_candidate_evidence(window, old, &output)
        })
    {
        checked.issues.push("v3_repair_lost_candidate".into());
    }
    repair["validation"] = validation_json(&checked);
    record["repair"] = repair;
    if !checked.is_complete() {
        return Ok(Err(failed("ad_analysis_incomplete", checked.issues, usage)));
    }
    checked.notices.push("v3_semantic_repair".into());
    Ok(Ok(WindowOutcome {
        output,
        usage,
        notices: checked.notices,
    }))
}

/// `run` after its windows: the lowest-index failure wins; otherwise the
/// windows' spans are concatenated in index order and validated against the
/// whole request.
fn merge(
    request: &AdAnalysisRequest,
    model: &str,
    policy_revision: &str,
    outcomes: Vec<Result<WindowOutcome, WindowFailure>>,
) -> Result<(Value, Value), Box<dyn Error>> {
    let mut output = Output { spans: Vec::new() };
    let mut usage = None;
    let mut notices = Vec::new();
    for (index, outcome) in outcomes.into_iter().enumerate() {
        let mut outcome = match outcome {
            Ok(outcome) => outcome,
            Err(failure) => {
                let error = json!({
                    "error": ErrorResponse::new(failure.code), "window": index,
                    "issues": failure.issues,
                });
                return Ok((error, Value::Null));
            }
        };
        output.spans.append(&mut outcome.output.spans);
        usage = combine_usage(usage, outcome.usage);
        notices.append(&mut outcome.notices);
    }
    let mut validated = promo_v3::validate(request, output);
    if !validated.is_complete() {
        let error = json!({
            "error": ErrorResponse::new("ad_analysis_incomplete"), "window": null,
            "issues": validated.issues,
        });
        return Ok((error, Value::Null));
    }
    notices.append(&mut validated.notices);
    notices.sort();
    notices.dedup();
    let response = AdAnalysisResponse {
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id.clone(),
        model: model.into(),
        policy: promo_v3::POLICY.into(),
        policy_revision: Some(policy_revision.into()),
        accounting: None,
        spans: validated.spans,
        warnings: notices,
        usage,
    };
    let response_json = serde_json::to_string(&response)?;
    Ok((json!({"response": response}), json!(response_json)))
}

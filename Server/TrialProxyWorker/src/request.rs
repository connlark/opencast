//! The inbound trial body: `{feature, run_id, window_index, request}` where
//! `request` is the Gemini `generateContent` body the device built. The
//! proxy keeps `contents`, `systemInstruction` and the sampling settings
//! verbatim and rebuilds everything chargeable from the embedded bundle.

use serde_json::{Map, Value};

use crate::bundle::{Feature, TrialBundle};

/// The pipeline's escalated Chapters level: every retry, and every
/// transcript above the escalation threshold, asks for it.
pub const CHAPTERS_ESCALATED_THINKING: &str = "high";
/// The call timeout the pipeline gives an escalated Chapters request.
pub const CHAPTERS_ESCALATED_CALL_TIMEOUT_SECONDS: u32 = 300;
pub const MAX_RUN_ID_CHARS: usize = 64;
pub const MAX_WINDOW_INDEX: u64 = 1_023;
pub const MAX_TURNS: usize = 64;
pub const MAX_PARTS: usize = 64;
pub const OUTBOUND_MIME_TYPE: &str = "application/json";

const WRAPPER_KEYS: [&str; 4] = ["feature", "run_id", "window_index", "request"];
/// Optional: the device's own call budget for this window (tighten-only).
const WRAPPER_TIMEOUT_KEY: &str = "timeout_seconds";
pub const MAX_TIMEOUT_SECONDS: u64 = 600;
const REQUEST_KEYS: [&str; 4] = ["contents", "systemInstruction", "generationConfig", "model"];
const OVERWRITTEN_CONFIG_KEYS: [&str; 4] = [
    "maxOutputTokens",
    "thinkingConfig",
    "responseMimeType",
    "responseJsonSchema",
];

/// Why a body was refused, for the content-free log line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InvalidReason {
    Json,
    Wrapper,
    Feature,
    RunId,
    WindowIndex,
    Timeout,
    RequestKeys,
    Contents,
    Turn,
    Parts,
    SystemInstruction,
    GenerationConfig,
    Sampling,
}

impl InvalidReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Wrapper => "wrapper",
            Self::Feature => "feature",
            Self::RunId => "run_id",
            Self::WindowIndex => "window_index",
            Self::Timeout => "timeout_seconds",
            Self::RequestKeys => "request_keys",
            Self::Contents => "contents",
            Self::Turn => "turn",
            Self::Parts => "parts",
            Self::SystemInstruction => "system_instruction",
            Self::GenerationConfig => "generation_config",
            Self::Sampling => "sampling",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestError {
    TooLarge,
    Invalid(InvalidReason),
}

/// A validated trial window, ready to count and forward.
#[derive(Debug, Clone, PartialEq)]
pub struct TrialWindow {
    pub feature: Feature,
    pub run_id: String,
    pub window_index: u16,
    /// The rebuilt Gemini body.
    pub outbound: Value,
    pub outbound_bytes: Vec<u8>,
    pub thinking: String,
    pub max_output_tokens: u32,
    /// The whole exchange's budget: the cap (the entry's per-call timeout,
    /// or the escalated Chapters timeout), shortened by the device's own.
    pub call_timeout_seconds: u32,
}

pub fn parse_window(
    bytes: &[u8],
    bundle: &TrialBundle,
    max_bytes: usize,
) -> Result<TrialWindow, RequestError> {
    if bytes.len() > max_bytes {
        return Err(RequestError::TooLarge);
    }
    let invalid = RequestError::Invalid;
    // serde_json's recursion limit (128) refuses deeper nesting here.
    let Value::Object(wrapper) =
        serde_json::from_slice::<Value>(bytes).map_err(|_| invalid(InvalidReason::Json))?
    else {
        return Err(invalid(InvalidReason::Wrapper));
    };
    let has_timeout = wrapper.contains_key(WRAPPER_TIMEOUT_KEY);
    if wrapper.len() != WRAPPER_KEYS.len() + usize::from(has_timeout)
        || !WRAPPER_KEYS.iter().all(|key| wrapper.contains_key(*key))
    {
        return Err(invalid(InvalidReason::Wrapper));
    }
    let client_timeout = match wrapper.get(WRAPPER_TIMEOUT_KEY) {
        None => None,
        Some(value) => Some(
            value
                .as_u64()
                .filter(|seconds| (1..=MAX_TIMEOUT_SECONDS).contains(seconds))
                .ok_or(invalid(InvalidReason::Timeout))? as u32,
        ),
    };
    let feature = wrapper["feature"]
        .as_str()
        .and_then(Feature::parse)
        .ok_or(invalid(InvalidReason::Feature))?;
    let run_id = wrapper["run_id"]
        .as_str()
        .filter(|run_id| valid_run_id(run_id))
        .ok_or(invalid(InvalidReason::RunId))?
        .to_string();
    let window_index = wrapper["window_index"]
        .as_u64()
        .filter(|index| *index <= MAX_WINDOW_INDEX)
        .ok_or(invalid(InvalidReason::WindowIndex))? as u16;
    let Value::Object(request) = &wrapper["request"] else {
        return Err(invalid(InvalidReason::RequestKeys));
    };
    if !request.contains_key("contents")
        || !request
            .keys()
            .all(|key| REQUEST_KEYS.contains(&key.as_str()))
    {
        return Err(invalid(InvalidReason::RequestKeys));
    }
    let contents = &request["contents"];
    check_contents(contents)?;
    let system_instruction = request.get("systemInstruction");
    if let Some(system_instruction) = system_instruction {
        check_system_instruction(system_instruction)?;
    }
    let inbound_config = match request.get("generationConfig") {
        None => Map::new(),
        Some(Value::Object(config)) => config.clone(),
        Some(_) => return Err(invalid(InvalidReason::GenerationConfig)),
    };
    let sampling = check_generation_config(&inbound_config)?;

    let entry = bundle.entry(feature);
    let asked_escalation = inbound_config
        .get("thinkingConfig")
        .and_then(|thinking| thinking.get("thinkingLevel"))
        .and_then(Value::as_str)
        == Some(CHAPTERS_ESCALATED_THINKING);
    let escalated = feature == Feature::ChaptersSummary && asked_escalation;
    let thinking = if escalated {
        CHAPTERS_ESCALATED_THINKING.to_string()
    } else {
        entry.thinking.clone()
    };
    let cap_seconds = if escalated {
        CHAPTERS_ESCALATED_CALL_TIMEOUT_SECONDS
    } else {
        entry.per_call_timeout_seconds
    };
    // The device may only shorten the budget: it plans its own retries
    // around it, and a proxy still forwarding past it holds the lock.
    let call_timeout_seconds =
        client_timeout.map_or(cap_seconds, |seconds| seconds.min(cap_seconds));

    let mut config = Map::new();
    config.insert("maxOutputTokens".into(), entry.max_output_tokens.into());
    config.insert(
        "thinkingConfig".into(),
        serde_json::json!({ "thinkingLevel": thinking }),
    );
    config.insert("responseMimeType".into(), OUTBOUND_MIME_TYPE.into());
    config.insert("responseJsonSchema".into(), entry.response_schema.clone());
    for (key, value) in sampling {
        config.insert(key, value);
    }
    let mut outbound = Map::new();
    outbound.insert("contents".into(), contents.clone());
    if let Some(system_instruction) = system_instruction {
        outbound.insert("systemInstruction".into(), system_instruction.clone());
    }
    outbound.insert("generationConfig".into(), Value::Object(config));
    let outbound = Value::Object(outbound);
    let outbound_bytes = serde_json::to_vec(&outbound).map_err(|_| invalid(InvalidReason::Json))?;
    Ok(TrialWindow {
        feature,
        run_id,
        window_index,
        outbound,
        outbound_bytes,
        thinking,
        max_output_tokens: entry.max_output_tokens,
        call_timeout_seconds,
    })
}

pub fn valid_run_id(value: &str) -> bool {
    (1..=MAX_RUN_ID_CHARS).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn check_contents(contents: &Value) -> Result<(), RequestError> {
    let Value::Array(turns) = contents else {
        return Err(RequestError::Invalid(InvalidReason::Contents));
    };
    if turns.is_empty() || turns.len() > MAX_TURNS {
        return Err(RequestError::Invalid(InvalidReason::Contents));
    }
    for turn in turns {
        let Value::Object(turn) = turn else {
            return Err(RequestError::Invalid(InvalidReason::Turn));
        };
        let role_ok = matches!(
            turn.get("role").and_then(Value::as_str),
            Some("user" | "model")
        );
        if turn.len() != 2 || !role_ok || !turn.contains_key("parts") {
            return Err(RequestError::Invalid(InvalidReason::Turn));
        }
        check_parts(&turn["parts"])?;
    }
    Ok(())
}

fn check_system_instruction(value: &Value) -> Result<(), RequestError> {
    match value {
        Value::Object(instruction)
            if instruction.len() == 1 && instruction.contains_key("parts") =>
        {
            check_parts(&instruction["parts"])
        }
        _ => Err(RequestError::Invalid(InvalidReason::SystemInstruction)),
    }
}

/// Text parts only: the device sends nothing else, and another modality
/// could bill at a rate the price table does not hold.
fn check_parts(parts: &Value) -> Result<(), RequestError> {
    let Value::Array(parts) = parts else {
        return Err(RequestError::Invalid(InvalidReason::Parts));
    };
    let text_only = |part: &Value| match part {
        Value::Object(part) => part.len() == 1 && part.get("text").is_some_and(Value::is_string),
        _ => false,
    };
    if parts.is_empty() || parts.len() > MAX_PARTS || !parts.iter().all(text_only) {
        return Err(RequestError::Invalid(InvalidReason::Parts));
    }
    Ok(())
}

/// Keeps `temperature` and `topP` when in range; the chargeable keys are
/// overwritten whatever they hold; any other key is refused.
fn check_generation_config(
    config: &Map<String, Value>,
) -> Result<Vec<(String, Value)>, RequestError> {
    let mut sampling = Vec::new();
    for (key, value) in config {
        if OVERWRITTEN_CONFIG_KEYS.contains(&key.as_str()) {
            continue;
        }
        let range = match key.as_str() {
            "temperature" => 0.0..=2.0,
            "topP" => 0.0..=1.0,
            _ => return Err(RequestError::Invalid(InvalidReason::GenerationConfig)),
        };
        if !value.as_f64().is_some_and(|number| range.contains(&number)) {
            return Err(RequestError::Invalid(InvalidReason::Sampling));
        }
        sampling.push((key.clone(), value.clone()));
    }
    Ok(sampling)
}

use serde::Deserialize;

use crate::types::GeminiUsage;
use crate::validation::{usage_from_counts, ModelOutput};

#[derive(Debug, Clone, Deserialize)]
pub struct GeminiGenerateContentResponse {
    #[serde(default)]
    pub candidates: Vec<GeminiCandidate>,
    #[serde(default, rename = "usageMetadata")]
    pub usage_metadata: Option<GeminiUsageMetadata>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeminiCandidate {
    #[serde(default)]
    pub content: Option<GeminiContent>,
    #[serde(default, rename = "finishReason")]
    pub finish_reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeminiContent {
    #[serde(default)]
    pub parts: Vec<GeminiPart>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeminiPart {
    #[serde(default)]
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeminiUsageMetadata {
    #[serde(default, rename = "promptTokenCount")]
    pub prompt_token_count: u64,
    #[serde(default, rename = "candidatesTokenCount")]
    pub candidates_token_count: u64,
    #[serde(default, rename = "thoughtsTokenCount")]
    pub thoughts_token_count: u64,
    #[serde(default, rename = "totalTokenCount")]
    pub total_token_count: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeminiErrorEnvelope {
    pub error: GeminiErrorBody,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeminiErrorBody {
    #[serde(default)]
    pub code: Option<u16>,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub status: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeminiParseError {
    MalformedResponse,
    MissingCandidateText,
    MalformedModelJson,
}

impl GeminiParseError {
    pub fn code(&self) -> &'static str {
        match self {
            GeminiParseError::MalformedResponse => "malformed_gemini_response",
            GeminiParseError::MissingCandidateText => "missing_gemini_text",
            GeminiParseError::MalformedModelJson => "malformed_model_json",
        }
    }
}

/// Parse result for one Gemini window response. Malformed or truncated model
/// output is not an error path: `output` is `None`, the
/// failure code and any extractable finish-reason warning ride along, and the
/// caller decides between one full re-request and degrading the window to
/// zero spans plus warnings. Transport-level failures never reach this type.
#[derive(Debug, Clone)]
pub struct ParsedModelResponse {
    pub output: Option<ModelOutput>,
    pub usage: Option<GeminiUsage>,
    pub warnings: Vec<String>,
    pub failure: Option<GeminiParseError>,
}

pub fn parse_generate_content_response(body: &str) -> ParsedModelResponse {
    let Ok(response) = serde_json::from_str::<GeminiGenerateContentResponse>(body) else {
        return ParsedModelResponse {
            output: None,
            usage: None,
            warnings: Vec::new(),
            failure: Some(GeminiParseError::MalformedResponse),
        };
    };

    // totalTokenCount already includes thinking tokens; guard against
    // upstreams that report thoughts separately without folding them in.
    let usage = response.usage_metadata.map(|usage| {
        usage_from_counts(
            usage.prompt_token_count,
            usage.candidates_token_count,
            usage.total_token_count.max(
                usage
                    .prompt_token_count
                    .saturating_add(usage.candidates_token_count)
                    .saturating_add(usage.thoughts_token_count),
            ),
        )
    });

    let Some(candidate) = response.candidates.first() else {
        return ParsedModelResponse {
            output: None,
            usage,
            warnings: Vec::new(),
            failure: Some(GeminiParseError::MissingCandidateText),
        };
    };

    let mut warnings = Vec::new();
    if let Some(reason) = candidate.finish_reason.as_deref() {
        if reason != "STOP" {
            warnings.push(format!("gemini_finish_reason:{reason}"));
        }
    }

    let text = candidate
        .content
        .as_ref()
        .map(|content| {
            content
                .parts
                .iter()
                .map(|part| part.text.as_str())
                .collect::<String>()
        })
        .unwrap_or_default();
    if text.trim().is_empty() {
        return ParsedModelResponse {
            output: None,
            usage,
            warnings,
            failure: Some(GeminiParseError::MissingCandidateText),
        };
    }

    match serde_json::from_str::<ModelOutput>(text.trim()) {
        Ok(output) => ParsedModelResponse {
            output: Some(output),
            usage,
            warnings,
            failure: None,
        },
        Err(_) => ParsedModelResponse {
            output: None,
            usage,
            warnings,
            failure: Some(GeminiParseError::MalformedModelJson),
        },
    }
}

pub fn parse_error_envelope(body: &str) -> Option<GeminiErrorBody> {
    serde_json::from_str::<GeminiErrorEnvelope>(body)
        .ok()
        .map(|envelope| envelope.error)
}

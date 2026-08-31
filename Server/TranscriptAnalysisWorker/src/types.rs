use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: u16 = 1;
pub const GEMINI_MODEL_DEFAULT: &str = "gemini-3.5-flash";
// gemini-3.5-flash is the only externally validated serving configuration;
// every challenger failed the evaluation smoke. There is no
// second production lane, so the allowlist is a single entry — an env-var
// flip to anything else clamps back to the default.
pub const GEMINI_MODEL_ALLOWLIST: [&str; 1] = ["gemini-3.5-flash"];
pub const GEMINI_MODEL_ENV_VAR: &str = "TRANSCRIPT_ANALYSIS_GEMINI_MODEL";
pub const POLICY_NAME: &str = "transcript_analysis_v2";

/// Resolve the serving model from the `TRANSCRIPT_ANALYSIS_GEMINI_MODEL` env
/// var. Absent or not on the allowlist falls back to the default; the
/// response `model` field always reports the model actually used.
pub fn resolve_gemini_model(env_value: Option<&str>) -> &'static str {
    let Some(value) = env_value else {
        return GEMINI_MODEL_DEFAULT;
    };
    let value = value.trim();
    GEMINI_MODEL_ALLOWLIST
        .iter()
        .find(|allowed| **allowed == value)
        .copied()
        .unwrap_or(GEMINI_MODEL_DEFAULT)
}

pub const MAX_BODY_BYTES: usize = 1_500_000;
// The authenticated envelope embeds the analysis payload as a JSON string.
// The payload is itself JSON text (no raw control characters), so escaping
// its quotes/backslashes can at most double its byte length; the remaining
// slack covers the install/key IDs and the base64 assertion. Keeping this
// at least `2 * MAX_BODY_BYTES` guarantees any payload accepted on the
// bearer path also fits inside an envelope.
pub const MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES: usize = 2 * MAX_BODY_BYTES + 16 * 1024;
// Evaluation validated 2,400 as the whole-episode raw id ceiling and retained it
// as the maximum number of model-facing unit ids after coalescing. Raw
// requests may contain more, while unit counts above this ceiling fail typed
// as `transcript_too_long` after coalescing where coalescing applies.
pub const MAX_MODEL_UNITS: usize = 2_400;
pub const MAX_TRANSCRIPT_TEXT_CHARS: usize = 360_000;
pub const MAX_SEGMENT_TEXT_CHARS: usize = 2_000;
pub const MAX_ESTIMATED_INPUT_TOKENS_PER_REQUEST: u64 = 120_000;
// Header metadata fields flow into the prompt (`build_prompt`) but not the
// segment-text estimate, so they must be bounded or they silently defeat the
// spend caps. Unlike ad analysis, this
// worker's shipped app path sends real titles:
// they anchor summaries, and a nil title would change the prompt bytes the
// evaluation corpus validated. podcast_id stays 2048 for the same reason as the
// template: the direct path sends the canonical feed URL, historically
// uncapped in the app.
pub const MAX_EPISODE_ID_CHARS: usize = 128;
// request_id is echoed into the result envelope; uncapped it could push the
// terminal DO record past the 128 KiB per-value platform limit (template
// storage budget). Both real producers are UUID-shaped; 256 clears them comfortably.
pub const MAX_REQUEST_ID_CHARS: usize = 256;
pub const MAX_PODCAST_ID_CHARS: usize = 2_048;
pub const MAX_TITLE_CHARS: usize = 512;
pub const MAX_LANGUAGE_CODE_CHARS: usize = 40;
// Named result budget with headroom under the DO storage 128 KiB per-value
// platform limit: the terminal record wraps result_json
// with bounded bookkeeping (ids, hashes, subjects), so an in-budget result
// always fits the platform write. Chapter/claim counts are capped and the
// echoed request_id is bounded above; over budget means degenerate model
// output (e.g. multi-kilobyte titles, which are soft violations) — fail the
// job with a stable code instead of hanging it on the platform rejection.
pub const MAX_RESULT_JSON_BYTES: usize = 100_000;
// Interim admission caps — an abuse guardrail, never the access model. They
// count a request and its
// estimated input once, not the outer-analysis/inner-transport retry ladder or
// output/thinking tokens. They are therefore not a production dollar ceiling;
// values remain unchanged pending an attributed operations decision.
pub const BEARER_DAILY_REQUEST_CAP: u64 = 40;
pub const BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP: u64 = 2_000_000;
pub const APP_ATTEST_KEY_DAILY_REQUEST_CAP: u64 = 12;
pub const APP_ATTEST_KEY_DAILY_ESTIMATED_INPUT_TOKEN_CAP: u64 = 1_500_000;
pub const GLOBAL_DAILY_REQUEST_CAP: u64 = 60;
pub const GLOBAL_DAILY_ESTIMATED_INPUT_TOKEN_CAP: u64 = 2_000_000;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct TranscriptAnalysisRequest {
    pub schema_version: u16,
    #[serde(default)]
    pub async_supported: bool,
    pub request_id: String,
    pub episode_id: String,
    pub podcast_id: String,
    #[serde(default)]
    pub episode_title: Option<String>,
    #[serde(default)]
    pub podcast_title: Option<String>,
    pub transcript: TranscriptMetadata,
    pub segments: Vec<TranscriptSegment>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct TranscriptMetadata {
    pub language_code: String,
    pub audio_duration: f64,
    #[serde(default)]
    pub model_identifier: Option<String>,
    #[serde(default)]
    pub model_version: Option<String>,
    #[serde(default)]
    pub model_tree_sha256: Option<String>,
    pub fingerprint: String,
    pub updated_at: String,
    pub state: String,
    pub segment_count: usize,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct TranscriptSegment {
    pub id: i64,
    pub start: f64,
    pub end: f64,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct TranscriptAnalysisResponse {
    pub schema_version: u16,
    pub request_id: String,
    pub model: String,
    pub policy: String,
    pub chapters: Vec<ValidatedChapter>,
    pub summary: Option<ValidatedSummary>,
    pub warnings: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<GeminiUsage>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ValidatedChapter {
    pub title: String,
    pub start_segment_id: i64,
    pub end_segment_id: i64,
    /// Times are derived server-side from the submitted segments; model
    /// output never supplies them.
    pub start_time: f64,
    pub end_time: f64,
    pub confidence: f64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ValidatedSummary {
    pub summary: String,
    pub one_line_description: String,
    pub claims: Vec<ValidatedClaim>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ValidatedClaim {
    pub text: String,
    pub evidence_segment_id: i64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct GeminiUsage {
    pub prompt_token_count: u64,
    pub candidates_token_count: u64,
    /// Thinking tokens bill as output alongside candidates (billed output =
    /// candidates + thoughts). Recorded separately so per-run cost can be
    /// instrumented from day one — the uncharged alpha's real usage is what
    /// prices the at-cost minutes rate.
    #[serde(default)]
    pub thoughts_token_count: u64,
    pub total_token_count: u64,
}

/// Purchase-account balance snapshot (integer seconds), the shared currency
/// shape across RTW/PurchaseWorker (`Balance` in PW types.ts / RTW types.rs).
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
pub struct Balance {
    pub available_seconds: i64,
    pub reserved_seconds: i64,
    pub debt_seconds: i64,
}

/// Envelope payload of the account bootstrap route. The AppTransaction JWS
/// is required on purchase-backend lanes and ignored by the development
/// fake (which keys the account off the authenticated install).
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct BootstrapRequest {
    pub schema_version: u16,
    #[serde(default)]
    pub app_transaction_jws: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct BootstrapResponse {
    pub schema_version: u16,
    pub account_id: String,
    pub balance: Balance,
}

/// Typed 402 body: the charge that was refused plus a
/// best-effort balance snapshot so the client can render the needs-minutes
/// state without a second round trip. No server-side awaiting state exists —
/// resubmission is cheap and the client owns deferral.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct InsufficientSecondsResponse {
    pub error: String,
    pub charge_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance: Option<Balance>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ErrorResponse {
    pub error: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl ErrorResponse {
    pub fn new(error: impl Into<String>) -> Self {
        Self {
            error: error.into(),
            detail: None,
        }
    }

    pub fn with_detail(error: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            error: error.into(),
            detail: Some(detail.into()),
        }
    }
}

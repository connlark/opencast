use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: u16 = 1;
pub const GEMINI_MODEL_DEFAULT: &str = "gemini-3.5-flash";
pub const GEMINI_MODEL_ALLOWLIST: [&str; 2] = ["gemini-3.5-flash", "gemini-3.1-flash-lite"];
pub const GEMINI_MODEL_ENV_VAR: &str = "AD_ANALYSIS_GEMINI_MODEL";
pub const POLICY_NAME: &str = "promo_ad_breaks_v2";

/// Resolve the serving model from the `AD_ANALYSIS_GEMINI_MODEL` env var.
/// Absent or not on the allowlist falls back to the default; the response
/// `model` field always reports the model actually used.
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
pub const MAX_SEGMENTS: usize = 6_000;
pub const MAX_TRANSCRIPT_TEXT_CHARS: usize = 360_000;
pub const MAX_SEGMENT_TEXT_CHARS: usize = 2_000;
pub const MAX_ESTIMATED_INPUT_TOKENS_PER_REQUEST: u64 = 120_000;
// Header metadata fields flow into the prompt (`build_prompt`) but not the
// segment-text estimate, so they must be bounded or they silently defeat the
// spend caps (Phase 10 review AA-2). Episode ids, titles, and language codes
// mirror the gateway's caps (RemoteTranscriptionWorker episode_id ≤128,
// titles ≤512): every chained request already satisfies them (bytes ≥ chars)
// and the shipped app's direct path sends a 64-hex episode id and nil titles.
// podcast_id CANNOT mirror the gateway's 256: on the direct path it is the
// canonical feed URL, historically uncapped there, so 256 would reject
// in-field apps subscribed to long-URL feeds (Phase 10 re-review). 2048
// clears any plausible real URL while still bounding the field to noise
// against the spend caps; the allowance pin test renders this worst case.
pub const MAX_EPISODE_ID_CHARS: usize = 128;
// AA-5: request_id was conspicuously absent from these caps, so up to
// ~1.5 MB (MAX_BODY_BYTES) of request_id sailed through validation and got
// echoed into the result envelope — whose post-paid-call DO write then
// failed on the platform's 128 KiB per-value limit, stranding the job as
// Running for the full 600 s deadline with the model spend discarded. Both
// real producers are UUID-shaped: the shipped app sends UUID().uuidString
// (36 chars, EpisodeAdAnalysisStore.swift:639) and the chained RTW path
// sends its own job id ("job-" + 22-char token,
// RemoteTranscriptionWorker/src/ad_analysis.rs:196). 256 clears both with
// comfortable headroom.
pub const MAX_REQUEST_ID_CHARS: usize = 256;
pub const MAX_PODCAST_ID_CHARS: usize = 2_048;
pub const MAX_TITLE_CHARS: usize = 512;
pub const MAX_LANGUAGE_CODE_CHARS: usize = 40;
// AA-5: named result budget with headroom under the DO storage 128 KiB
// per-value platform limit — the terminal record wraps result_json with
// bounded bookkeeping (ids, hashes, subjects), so an in-budget result
// always fits the platform write. Over budget means degenerate model
// output (validated spans are capped; the echoed request_id is capped
// above): fail the job with a stable code instead of hanging it on the
// platform rejection.
pub const MAX_RESULT_JSON_BYTES: usize = 100_000;
// Spend caps scaled to ~= $15/day worst case (step-4 PLAN §A6).
pub const BEARER_DAILY_REQUEST_CAP: u64 = 40;
pub const BEARER_DAILY_ESTIMATED_INPUT_TOKEN_CAP: u64 = 2_000_000;
pub const APP_ATTEST_KEY_DAILY_REQUEST_CAP: u64 = 12;
pub const APP_ATTEST_KEY_DAILY_ESTIMATED_INPUT_TOKEN_CAP: u64 = 1_500_000;
pub const GLOBAL_DAILY_REQUEST_CAP: u64 = 300;
pub const GLOBAL_DAILY_ESTIMATED_INPUT_TOKEN_CAP: u64 = 8_000_000;
// Internal transcription-chained requests are already credit-gated upstream,
// so these per-account caps are a backstop (App-Attest profile numbers;
// retunable independently).
pub const TRANSCRIPTION_ACCOUNT_DAILY_REQUEST_CAP: u64 = 12;
pub const TRANSCRIPTION_ACCOUNT_DAILY_ESTIMATED_INPUT_TOKEN_CAP: u64 = 1_500_000;

/// Body of the internal analyze route (RemoteTranscriptionWorker binding).
/// Trust boundary is the service binding + `.internal` host — no App Attest
/// or bearer. `transcription_job_id` is diagnostics only, never keyed on.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct InternalAnalyzeRequest {
    pub schema_version: u16,
    pub account_id: String,
    #[serde(default)]
    pub transcription_job_id: Option<String>,
    pub request: AdAnalysisRequest,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct AdAnalysisRequest {
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

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AdSpanKind {
    HostReadAd,
    InsertedAd,
    HouseOrNetworkPromo,
}

impl AdSpanKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            AdSpanKind::HostReadAd => "host_read_ad",
            AdSpanKind::InsertedAd => "inserted_ad",
            AdSpanKind::HouseOrNetworkPromo => "house_or_network_promo",
        }
    }

    pub fn from_model_value(value: &str) -> Option<Self> {
        match value {
            "host_read_ad" => Some(AdSpanKind::HostReadAd),
            "inserted_ad" => Some(AdSpanKind::InsertedAd),
            "house_or_network_promo" => Some(AdSpanKind::HouseOrNetworkPromo),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct AdAnalysisResponse {
    pub schema_version: u16,
    pub request_id: String,
    pub model: String,
    pub policy: String,
    pub spans: Vec<ValidatedAdSpan>,
    pub warnings: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<GeminiUsage>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ValidatedAdSpan {
    pub kind: AdSpanKind,
    pub label: String,
    pub start_segment_id: i64,
    pub end_segment_id: i64,
    pub start_time: f64,
    pub end_time: f64,
    pub confidence: f64,
    pub evidence_quote: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct GeminiUsage {
    pub prompt_token_count: u64,
    pub candidates_token_count: u64,
    pub total_token_count: u64,
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

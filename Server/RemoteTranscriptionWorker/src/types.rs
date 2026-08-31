use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: u32 = 1;

pub const MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES: usize = 64 * 1024;
pub const MAX_PAYLOAD_BYTES: usize = 32 * 1024;

// Stable machine error codes shared with the app
// (OpenCastRemoteTranscriptionErrorCode). Localized copy stays app-side.
pub const ERROR_SOURCE_MISMATCH: &str = "remote_unavailable_source_mismatch";
pub const ERROR_UNSUPPORTED_MEDIA_TYPE: &str = "unsupported_media_type";
pub const ERROR_SOURCE_TOO_LARGE: &str = "source_too_large";
pub const ERROR_DURATION_TOO_LONG: &str = "duration_too_long";
pub const ERROR_ORIGIN_FETCH_FAILED: &str = "origin_fetch_failed";
pub const ERROR_DEADLINE_EXPIRED: &str = "deadline_expired";
pub const ERROR_JOB_NOT_FOUND: &str = "job_not_found";
pub const ERROR_ACCOUNT_MISMATCH: &str = "account_mismatch";
pub const ERROR_FEATURE_DISABLED: &str = "feature_disabled";
/// Purchase kill switch: store/purchase routes hidden
/// without touching balances, jobs, or notification processing.
pub const ERROR_PURCHASES_DISABLED: &str = "purchases_disabled";
/// Purchase-backend lanes require a bootstrap-established install→account
/// link before any job or purchase route resolves an account.
pub const ERROR_BOOTSTRAP_REQUIRED: &str = "bootstrap_required";
pub const ERROR_UNAUTHORIZED: &str = "unauthorized";
pub const ERROR_RATE_LIMITED: &str = "rate_limited";
pub const ERROR_INVALID_REQUEST: &str = "invalid_request";
pub const ERROR_TRANSCRIPTION_FAILED: &str = "transcription_failed";
pub const ERROR_CANCELLED: &str = "cancelled";
pub const ERROR_INTERNAL: &str = "internal_error";
/// Upload routes exist but the lane has no R2 S3 signing credential yet:
/// fail closed, leaving the development lane unaffected.
pub const ERROR_UPLOAD_UNAVAILABLE: &str = "upload_unavailable";
/// The completed exact-device upload's recomputed identity does not equal the
/// authenticated device report: terminal, zero spend.
pub const ERROR_UPLOAD_IDENTITY_MISMATCH: &str = "upload_identity_mismatch";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ErrorResponse {
    pub error: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl ErrorResponse {
    pub fn new(code: impl Into<String>) -> Self {
        Self {
            error: code.into(),
            detail: None,
        }
    }

    pub fn with_detail(code: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            error: code.into(),
            detail: Some(detail.into()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SourceIdentity {
    pub sha256: String,
    pub byte_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entity_tag: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_modified: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct Balance {
    pub available_seconds: i64,
    pub reserved_seconds: i64,
    pub debt_seconds: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobProgress {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chunks_completed: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chunks_total: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_remaining_seconds: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimate_status: Option<EstimateStatus>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EstimateStatus {
    OnTrack,
    Queued,
    Delayed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobError {
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// Per-chunk AI span: index, first-attempt start,
/// successful-attempt end (epoch seconds), and how many attempts failed.
/// Content-free by construction.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkAiSpan {
    pub index: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ai_started_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ai_ended_at: Option<i64>,
    #[serde(default)]
    pub failed_attempts: u32,
}

/// Phase telemetry exposed on poll in the development lane only: state name →
/// first-entry epoch seconds, plus per-chunk AI spans. Production lanes
/// decide later what (if anything) to show.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhaseTimestamps {
    pub states: std::collections::BTreeMap<String, i64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub chunks: Vec<ChunkAiSpan>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobStatus {
    pub job_id: String,
    pub state: String,
    /// Echo of the effective chained-ad-detection flag (first create wins on
    /// dedupe, so a re-send with a different flag sees the divergence here).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ad_analysis_requested: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<JobProgress>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JobError>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phase_timestamps: Option<PhaseTimestamps>,
}

#[derive(Debug, Deserialize)]
pub struct BootstrapRequest {
    pub schema_version: u32,
    #[serde(default)]
    pub app_transaction_jws: Option<String>,
}

/// Server catalog entry mirrored from PurchaseWorker; the app cross-checks
/// its embedded catalog hash against `catalog_sha256` and fails closed.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogProduct {
    pub product_id: String,
    pub grant_seconds: i64,
}

#[derive(Debug, Serialize)]
pub struct BootstrapResponse {
    pub schema_version: u32,
    pub account_id: String,
    pub balance: Balance,
    // Purchase-backend lanes only (additive; dev lane omits all of these).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_account_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catalog: Option<Vec<CatalogProduct>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catalog_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub purchases_enabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct RedeemRequest {
    pub schema_version: u32,
    pub transaction_jws: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct JobCreateRequest {
    pub schema_version: u32,
    pub client_request_id: String,
    pub episode_id: String,
    pub enclosure_url: String,
    #[serde(default)]
    pub declared_duration_seconds: Option<f64>,
    #[serde(default)]
    pub language_code: Option<String>,
    #[serde(default)]
    pub source_identity: Option<SourceIdentity>,
    /// Chain server-side ad detection after stitching (requires a non-empty
    /// `podcast_id`); the transcription outcome and pricing are unchanged.
    #[serde(default)]
    pub ad_analysis_requested: bool,
    #[serde(default)]
    pub podcast_id: Option<String>,
    /// Prompt context only; optional, never logged, erased with the record.
    #[serde(default)]
    pub episode_title: Option<String>,
    #[serde(default)]
    pub podcast_title: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SourceReportRequest {
    pub schema_version: u32,
    pub source_identity: SourceIdentity,
}

#[derive(Debug, Deserialize)]
pub struct PollRequest {
    pub schema_version: u32,
}

#[derive(Debug, Deserialize)]
pub struct AckRequest {
    pub schema_version: u32,
    #[serde(default)]
    pub normalized_transcript_sha256: Option<String>,
}

// --- Exact-device upload fallback wire shapes ---

#[derive(Debug, Deserialize)]
pub struct UploadStartRequest {
    pub schema_version: u32,
    /// Background-enqueued batches get the longer bounded URL expiry.
    #[serde(default)]
    pub for_background: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct UploadPartsRequest {
    pub schema_version: u32,
    pub part_numbers: Vec<u16>,
    #[serde(default)]
    pub for_background: Option<bool>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct UploadCompletedPart {
    pub part_number: u16,
    pub etag: String,
}

#[derive(Debug, Deserialize)]
pub struct UploadCompleteRequest {
    pub schema_version: u32,
    pub parts: Vec<UploadCompletedPart>,
}

/// One presigned `UploadPart` PUT URL. Treat as a bearer credential: never
/// logged, bounded expiry (`expires_at` epoch seconds).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UploadPartGrant {
    pub part_number: u16,
    pub url: String,
    pub expires_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UploadGrantResponse {
    pub schema_version: u32,
    pub upload_key_id: String,
    pub part_size_bytes: i64,
    pub part_count: u16,
    pub parts: Vec<UploadPartGrant>,
}

#[derive(Debug, Serialize)]
pub struct JobResponse {
    pub schema_version: u32,
    pub job: JobStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance: Option<Balance>,
}

#[derive(Debug, Serialize)]
pub struct PollResponse {
    pub schema_version: u32,
    pub job: JobStatus,
    pub poll_after_seconds: u32,
}

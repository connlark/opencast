use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    Capacity,
    TransientTransport,
    InterruptedJob,
    ValidationExhausted,
    UnsupportedInput,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RetryDisposition {
    AfterCapacity,
    BoundedRetry,
    ExplicitRetry,
    ChangedInput,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct AnalysisFailure {
    pub category: Category,
    pub retry_disposition: RetryDisposition,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_revision: Option<String>,
}

impl AnalysisFailure {
    pub fn for_code(code: &str) -> Option<Self> {
        let (category, retry_disposition) = match code {
            "daily_request_cap_exceeded"
            | "daily_input_token_cap_exceeded"
            | "global_capacity_exhausted"
            | "gemini_quota_exhausted" => (Category::Capacity, RetryDisposition::AfterCapacity),
            "ad_analysis_incomplete" | "repair_feedback_exceeded" => (
                Category::ValidationExhausted,
                RetryDisposition::ExplicitRetry,
            ),
            "job_failed_transient" | "job_task_failed" | "ambiguous_legacy_job" => {
                (Category::InterruptedJob, RetryDisposition::BoundedRetry)
            }
            "execution_expired"
            | "gemini_response_oversized"
            | "gemini_response_encoding"
            | "analysis_deadline_exhausted"
            | "gemini_timeout"
            | "gemini_unavailable"
            | "gemini_retry_exhausted"
            | "worker_fetch_error"
            | "gemini_http_error"
            | "usage_limiter_error"
            | "admission_busy" => (Category::TransientTransport, RetryDisposition::BoundedRetry),
            "execution_allowance_exhausted"
            | "invalid_execution_allowance"
            | "too_many_segments"
            | "transcript_too_large"
            | "estimated_input_tokens_exceeded"
            | "unsupported_schema_version"
            | "body_too_large"
            | "segment_count_exceeded"
            | "transcript_text_too_large"
            | "estimated_input_too_large"
            | "invalid_transcript_metadata"
            | "segment_count_mismatch"
            | "empty_segments"
            | "segment_text_too_large"
            | "invalid_segment_timing"
            | "non_monotonic_segments"
            | "duplicate_segment_id"
            | "metadata_field_too_large" => {
                (Category::UnsupportedInput, RetryDisposition::ChangedInput)
            }
            _ => return None,
        };
        Some(Self {
            category,
            retry_disposition,
            policy_revision: None,
        })
    }
}

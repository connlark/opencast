use serde::{Deserialize, Serialize};

use crate::validation::UsageLimits;

pub const USAGE_LIMITER_BINDING: &str = "AD_ANALYSIS_USAGE_LIMITER";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct UsageAdmitRequest {
    pub estimated_input_tokens: u64,
    pub profile: UsageLimitProfile,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UsageLimitProfile {
    Bearer,
    AppAttestKey,
    /// Internal transcription-chained requests, keyed per transcription
    /// account (`transcription-account:{token_hash(account_id)}`).
    TranscriptionAccount,
    Global,
}

impl UsageLimitProfile {
    pub fn limits(self) -> UsageLimits {
        match self {
            UsageLimitProfile::Bearer => UsageLimits::BEARER,
            UsageLimitProfile::AppAttestKey => UsageLimits::APP_ATTEST_KEY,
            UsageLimitProfile::TranscriptionAccount => UsageLimits::TRANSCRIPTION_ACCOUNT,
            UsageLimitProfile::Global => UsageLimits::GLOBAL,
        }
    }
}

pub fn usage_object_name(subject: &str, day_index: u64) -> String {
    format!("ad-analysis:v1:usage:{day_index}:{subject}")
}

pub fn global_usage_object_name(day_index: u64) -> String {
    format!("ad-analysis:v1:usage:{day_index}:global")
}

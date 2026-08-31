use serde::{Deserialize, Serialize};

use crate::validation::UsageLimits;

pub const USAGE_LIMITER_BINDING: &str = "TRANSCRIPT_ANALYSIS_USAGE_LIMITER";

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
    Global,
}

impl UsageLimitProfile {
    pub fn limits(self) -> UsageLimits {
        match self {
            UsageLimitProfile::Bearer => UsageLimits::BEARER,
            UsageLimitProfile::AppAttestKey => UsageLimits::APP_ATTEST_KEY,
            UsageLimitProfile::Global => UsageLimits::GLOBAL,
        }
    }
}

pub fn usage_object_name(subject: &str, day_index: u64) -> String {
    format!("transcript-analysis:v1:usage:{day_index}:{subject}")
}

pub fn global_usage_object_name(day_index: u64) -> String {
    format!("transcript-analysis:v1:usage:{day_index}:global")
}

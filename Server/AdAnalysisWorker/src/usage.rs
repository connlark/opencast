use serde::{Deserialize, Serialize};

use crate::validation::{CapError, DailyUsage, UsageLimits};

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

pub fn parse_daily_usage(raw: Option<&str>) -> DailyUsage {
    raw.and_then(|value| serde_json::from_str::<DailyUsage>(value).ok())
        .unwrap_or_default()
}

pub fn admitted_usage(
    raw: Option<&str>,
    estimated_input_tokens: u64,
) -> Result<DailyUsage, CapError> {
    parse_daily_usage(raw).admitting(estimated_input_tokens)
}

pub fn admitted_usage_with_profile(
    raw: Option<&str>,
    estimated_input_tokens: u64,
    profile: UsageLimitProfile,
) -> Result<DailyUsage, CapError> {
    parse_daily_usage(raw).admitting_with_limits(estimated_input_tokens, profile.limits())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpendCapScope {
    Subject,
    Global,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpendCapRejection {
    pub scope: SpendCapScope,
    pub error: CapError,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpendCapAdmission {
    pub subject: DailyUsage,
    pub global: DailyUsage,
}

pub fn admit_subject_then_global(
    subject: &DailyUsage,
    subject_profile: UsageLimitProfile,
    global: &DailyUsage,
    estimated_input_tokens: u64,
) -> Result<SpendCapAdmission, SpendCapRejection> {
    let subject = subject
        .admitting_with_limits(estimated_input_tokens, subject_profile.limits())
        .map_err(|error| SpendCapRejection {
            scope: SpendCapScope::Subject,
            error,
        })?;
    let global = global
        .admitting_with_limits(estimated_input_tokens, UsageLimits::GLOBAL)
        .map_err(|error| SpendCapRejection {
            scope: SpendCapScope::Global,
            error,
        })?;

    Ok(SpendCapAdmission { subject, global })
}

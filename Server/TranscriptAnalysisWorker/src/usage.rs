use serde::{Deserialize, Serialize};

use crate::counters;
use crate::validation::UsageLimits;

pub const USAGE_LIMITER_BINDING: &str = "TRANSCRIPT_ANALYSIS_USAGE_LIMITER";

/// Limiter object routes. `/admit` counts a request and its estimated
/// tokens against the day's caps; `/release` gives one confirmed admission
/// back. Every other path is unknown and never touches usage.
pub const USAGE_LIMITER_ADMIT_PATH: &str = "/admit";
pub const USAGE_LIMITER_RELEASE_PATH: &str = "/release";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsageLimiterRoute {
    Admit,
    Release,
}

pub fn usage_limiter_route(path: &str) -> Option<UsageLimiterRoute> {
    match path {
        USAGE_LIMITER_ADMIT_PATH => Some(UsageLimiterRoute::Admit),
        USAGE_LIMITER_RELEASE_PATH => Some(UsageLimiterRoute::Release),
        _ => None,
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct UsageAdmitRequest {
    pub estimated_input_tokens: u64,
    pub profile: UsageLimitProfile,
}

/// The exact figures of the admission being given back. The profile is
/// carried for logging parity with `/admit`; release math is profile-free
/// (one request, these tokens).
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct UsageReleaseRequest {
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

    pub fn label(self) -> &'static str {
        match self {
            UsageLimitProfile::Bearer => "bearer",
            UsageLimitProfile::AppAttestKey => "app_attest_key",
            UsageLimitProfile::Global => "global",
        }
    }
}

pub fn usage_object_name(subject: &str, day_index: u64) -> String {
    format!("transcript-analysis:v1:usage:{day_index}:{subject}")
}

pub fn global_usage_object_name(day_index: u64) -> String {
    format!("transcript-analysis:v1:usage:{day_index}:global")
}

/// Both limiter objects an attempt admits against, minted from ONE day
/// index so admission and release address the same pair across 00:00 UTC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageObjectNames {
    pub caller: String,
    pub global: String,
}

impl UsageObjectNames {
    pub fn for_day(subject: &str, day_index: u64) -> Self {
        Self {
            caller: usage_object_name(subject, day_index),
            global: global_usage_object_name(day_index),
        }
    }

    pub fn scopes(
        &self,
        caller_profile: UsageLimitProfile,
        estimated_input_tokens: u64,
    ) -> (AdmissionScope, AdmissionScope) {
        (
            AdmissionScope {
                object_name: self.caller.clone(),
                profile: caller_profile,
                estimated_input_tokens,
            },
            AdmissionScope {
                object_name: self.global.clone(),
                profile: UsageLimitProfile::Global,
                estimated_input_tokens,
            },
        )
    }
}

/// One limiter scope a submit attempt admits against: the exact object
/// name (day already folded in, so admission and release address the same
/// object across 00:00 UTC) plus the figures the admit charged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdmissionScope {
    pub object_name: String,
    pub profile: UsageLimitProfile,
    pub estimated_input_tokens: u64,
}

/// The scopes one submit attempt has CONFIRMED acquired, in acquisition
/// order. Owned by the attempt: release consumes it, so no scope can be
/// released twice and a denied or unknown-outcome scope is never inside.
#[derive(Debug, PartialEq, Eq)]
pub struct AcquiredAdmissions {
    scopes: Vec<AdmissionScope>,
}

impl AcquiredAdmissions {
    pub fn first(scope: AdmissionScope) -> Self {
        Self {
            scopes: vec![scope],
        }
    }

    pub fn push(&mut self, scope: AdmissionScope) {
        self.scopes.push(scope);
    }

    pub fn scopes(&self) -> &[AdmissionScope] {
        &self.scopes
    }

    pub fn into_scopes(self) -> Vec<AdmissionScope> {
        self.scopes
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScopeReleaseOutcome {
    Released,
    /// A refused release (non-200) or one whose response was lost. Both
    /// leave the scope charged; neither is retried (the route is not
    /// idempotent).
    Failed,
}

/// Counter deltas for one attempt's cleanup: `admission_releases` only
/// when every confirmed scope was given back (partial cleanup is not a
/// success), and one `admission_release_failures` per scope that was not.
pub fn release_counter_deltas(outcomes: &[ScopeReleaseOutcome]) -> Vec<(&'static str, i64)> {
    let failures = outcomes
        .iter()
        .filter(|outcome| **outcome == ScopeReleaseOutcome::Failed)
        .count();
    if failures == 0 {
        if outcomes.is_empty() {
            return Vec::new();
        }
        return vec![(counters::ADMISSION_RELEASES, 1)];
    }
    vec![(
        counters::ADMISSION_RELEASE_FAILURES,
        i64::try_from(failures).unwrap_or(i64::MAX),
    )]
}

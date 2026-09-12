//! A serving policy is a pinned prompt/validator/model bundle, not a free model
//! toggle. Changing it also changes the cache namespace; v2 remains the default.
use crate::{promo_v3, types::AdAnalysisRequest};

pub const POLICY_ENV_VAR: &str = "AD_ANALYSIS_POLICY";
pub const V3_MODEL: &str = "gemini-3.8-flash";
/// Bump for any deployed prompt/validator change, even when schema stays v3.
pub const V3_REVISION: &str = "2026-09-11.2-recovery";
pub const V3_PREVIOUS_REVISION: &str = "2026-09-11.1-word-boundaries";
pub const V3_INITIAL_ATTEMPTS: usize = 2;
pub const V3_REPAIR_ATTEMPTS: usize = 1;
pub const V3_MAX_BACKOFF_SECONDS: u64 = 10;
pub const V3_EXECUTION_SECONDS: u64 = 570;
pub const V3_THINKING: &str = "medium";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnalysisPolicy {
    V2,
    V3,
}

impl AnalysisPolicy {
    pub fn resolve(value: Option<&str>) -> Self {
        match value.map(str::trim) {
            Some(promo_v3::POLICY) => Self::V3,
            _ => Self::V2,
        }
    }

    pub fn model(self, v2_override: Option<&str>) -> &'static str {
        match self {
            Self::V2 => crate::types::resolve_gemini_model(v2_override),
            Self::V3 => V3_MODEL,
        }
    }

    pub fn job_object_name(self, id: &str) -> String {
        match self {
            Self::V2 => crate::job::job_object_name(id),
            Self::V3 => format!("ad-analysis:v3:{V3_REVISION}:flash38-medium:w800:r1:job:{id}"),
        }
    }

    pub fn job_handle(self, fingerprint: &str) -> String {
        match self {
            Self::V2 => fingerprint.to_string(),
            Self::V3 => format!("a3.20260911b.{fingerprint}"),
        }
    }

    /// Finite execution allowance, distinct from the 120k SOURCE request cap.
    /// This is not debited at admission: only individually reserved attempts
    /// consume input quota. Output/thinking receipts remain separate telemetry.
    pub fn admission_tokens(self, request: &AdAnalysisRequest, legacy: u64) -> u64 {
        if self == Self::V2 {
            return legacy;
        }
        crate::v3_windowing::analysis_windows(request)
            .iter()
            .map(|window| {
                let chars = promo_v3::payload(window, Some(V3_THINKING))
                    .to_string()
                    .chars()
                    .count() as u64;
                let initial = chars.div_ceil(4);
                // A repair includes one bounded previous answer plus bounded
                // ID-only feedback. No provider response or user text is logged.
                // Both bounded strings are nested in JSON text fields:
                // quotes/backslashes can double their serialized size.
                let feedback = (2
                    * (promo_v3::MAX_MODEL_JSON_BYTES as u64
                        + promo_v3::MAX_REPAIR_FEEDBACK_BYTES as u64)
                    + 4096) // message framing headroom
                    .div_ceil(4);
                initial * (V3_INITIAL_ATTEMPTS + V3_REPAIR_ATTEMPTS) as u64 + feedback
            })
            .sum()
    }
}

/// Only known routing tags select bundles. Untagged polls probe the two
/// pre-handle namespaces, never today's v3 selection. No arbitrary DO names.
pub fn poll_object_names(handle: &str) -> Option<Vec<String>> {
    if let Some(fingerprint) = handle.strip_prefix("a3.20260911b.") {
        return crate::job::valid_fingerprint(fingerprint).then(|| {
            vec![format!(
                "ad-analysis:v3:2026-09-11.2-recovery:flash38-medium:w800:r1:job:{fingerprint}"
            )]
        });
    }
    if let Some(fingerprint) = handle.strip_prefix("a3.20260911a.") {
        return crate::job::valid_fingerprint(fingerprint)
            .then(|| vec![legacy_v3_object_name(fingerprint)]);
    }
    if handle.starts_with("a3.") || !crate::job::valid_fingerprint(handle) {
        return None;
    }
    Some(vec![
        crate::job::job_object_name(handle),
        legacy_v3_object_name(handle),
        AnalysisPolicy::V3.job_object_name(handle),
    ])
}

fn legacy_v3_object_name(fingerprint: &str) -> String {
    format!("ad-analysis:v3:{V3_PREVIOUS_REVISION}:flash38-medium:w800:r1:job:{fingerprint}")
}

//! The trial entries of the analysis policy bundle embedded at build time
//! (`build.rs` copies the highest checked-in `vN.json`). A tolerant reader:
//! unknown fields are ignored and only what the trial forward needs is read.
//! The proxy never takes a chargeable field from the client; these entries
//! replace them.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::clock::parse_utc_timestamp_ms;

pub const EMBEDDED_BUNDLE_JSON: &str =
    include_str!(concat!(env!("OUT_DIR"), "/analysis-policy.json"));
/// File name of the embedded bundle (`vN.json`), for tests and readback.
pub const EMBEDDED_BUNDLE_FILE: &str = env!("TRIAL_EMBEDDED_BUNDLE_FILE");

/// The only host opencast's key is ever sent to.
pub const GOOGLE_HOST: &str = "generativelanguage.googleapis.com";
pub const THINKING_LEVELS: [&str; 3] = ["low", "medium", "high"];
const MODEL_PLACEHOLDER: &str = "{model}";

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Feature {
    AdDetection,
    ChaptersSummary,
}

impl Feature {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AdDetection => "ad_detection",
            Self::ChaptersSummary => "chapters_summary",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "ad_detection" => Some(Self::AdDetection),
            "chapters_summary" => Some(Self::ChaptersSummary),
            _ => None,
        }
    }
}

/// One feature's entry for the trial model.
#[derive(Debug, Clone, PartialEq)]
pub struct TrialEntry {
    pub thinking: String,
    pub max_output_tokens: u32,
    pub per_call_timeout_seconds: u32,
    pub response_schema: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TrialBundle {
    pub bundle_version: u32,
    pub model: String,
    pub starts_at: String,
    pub lifetime_units: u32,
    pub generate_url: String,
    pub count_tokens_url: String,
    pub ad_detection: TrialEntry,
    pub chapters_summary: TrialEntry,
}

impl TrialBundle {
    pub fn entry(&self, feature: Feature) -> &TrialEntry {
        match feature {
            Feature::AdDetection => &self.ad_detection,
            Feature::ChaptersSummary => &self.chapters_summary,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BundleError {
    Decode,
    ProviderHost,
    ProviderPath,
    VersionHeaders,
    ModelId,
    StartsAt,
    LifetimeUnits,
    MissingEntry(Feature),
    Entry(Feature),
}

impl BundleError {
    /// A closed reason for the config-error log line.
    pub fn reason(self) -> &'static str {
        match self {
            Self::Decode => "bundle_decode",
            Self::ProviderHost => "bundle_provider_host",
            Self::ProviderPath => "bundle_provider_path",
            Self::VersionHeaders => "bundle_version_headers",
            Self::ModelId => "bundle_model_id",
            Self::StartsAt => "bundle_starts_at",
            Self::LifetimeUnits => "bundle_lifetime_units",
            Self::MissingEntry(_) => "bundle_missing_entry",
            Self::Entry(_) => "bundle_entry",
        }
    }
}

#[derive(Deserialize)]
struct RawBundle {
    bundle_version: u32,
    trial: RawTrial,
    providers: RawProviders,
    features: RawFeatures,
}

#[derive(Deserialize)]
struct RawTrial {
    model: String,
    starts_at: String,
    lifetime_units: u32,
}

#[derive(Deserialize)]
struct RawProviders {
    google: RawProvider,
}

#[derive(Deserialize)]
struct RawProvider {
    base_url: String,
    generate_path: String,
    count_tokens_path: String,
    #[serde(default)]
    version_headers: BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct RawFeatures {
    ad_detection: RawAdDetection,
    chapters_summary: RawChaptersSummary,
}

#[derive(Deserialize)]
struct RawAdDetection {
    qualified_models: Vec<RawEntry>,
    response_schema: Value,
}

#[derive(Deserialize)]
struct RawChaptersSummary {
    allowed_models: Vec<RawEntry>,
    response_schema: Value,
}

#[derive(Deserialize)]
struct RawEntry {
    provider: String,
    model_id: String,
    thinking: String,
    max_output_tokens: u32,
    per_call_timeout_seconds: u32,
}

/// The embedded bundle, parsed once per isolate.
pub fn embedded() -> Result<&'static TrialBundle, BundleError> {
    static EMBEDDED: OnceLock<Result<TrialBundle, BundleError>> = OnceLock::new();
    EMBEDDED
        .get_or_init(|| parse_bundle(EMBEDDED_BUNDLE_JSON))
        .as_ref()
        .map_err(|error| *error)
}

pub fn parse_bundle(json: &str) -> Result<TrialBundle, BundleError> {
    let raw: RawBundle = serde_json::from_str(json).map_err(|_| BundleError::Decode)?;
    let google = &raw.providers.google;
    if google_base(&google.base_url).is_none() {
        return Err(BundleError::ProviderHost);
    }
    if !safe_model_path(&google.generate_path) || !safe_model_path(&google.count_tokens_path) {
        return Err(BundleError::ProviderPath);
    }
    if !google.version_headers.is_empty() {
        // The forward sends exactly two headers; a bundle that adds one is a
        // decision for whoever publishes it, not something to pass along.
        return Err(BundleError::VersionHeaders);
    }
    if !valid_model_id(&raw.trial.model) {
        return Err(BundleError::ModelId);
    }
    if parse_utc_timestamp_ms(&raw.trial.starts_at).is_none() {
        return Err(BundleError::StartsAt);
    }
    if raw.trial.lifetime_units == 0 {
        return Err(BundleError::LifetimeUnits);
    }
    let base = google.base_url.trim_end_matches('/');
    let url = |path: &str| {
        format!(
            "{base}{}",
            path.replace(MODEL_PLACEHOLDER, &raw.trial.model)
        )
    };
    let ad_detection = entry(
        Feature::AdDetection,
        &raw.features.ad_detection.qualified_models,
        &raw.features.ad_detection.response_schema,
        &raw.trial.model,
    )?;
    let chapters_summary = entry(
        Feature::ChaptersSummary,
        &raw.features.chapters_summary.allowed_models,
        &raw.features.chapters_summary.response_schema,
        &raw.trial.model,
    )?;
    Ok(TrialBundle {
        bundle_version: raw.bundle_version,
        generate_url: url(&google.generate_path),
        count_tokens_url: url(&google.count_tokens_path),
        model: raw.trial.model,
        starts_at: raw.trial.starts_at,
        lifetime_units: raw.trial.lifetime_units,
        ad_detection,
        chapters_summary,
    })
}

fn entry(
    feature: Feature,
    entries: &[RawEntry],
    schema: &Value,
    model: &str,
) -> Result<TrialEntry, BundleError> {
    let raw = entries
        .iter()
        .find(|entry| entry.provider == "google" && entry.model_id == model)
        .ok_or(BundleError::MissingEntry(feature))?;
    if !THINKING_LEVELS.contains(&raw.thinking.as_str())
        || !(1..=65_536).contains(&raw.max_output_tokens)
        || !(1..=600).contains(&raw.per_call_timeout_seconds)
        || !schema.is_object()
    {
        return Err(BundleError::Entry(feature));
    }
    Ok(TrialEntry {
        thinking: raw.thinking.clone(),
        max_output_tokens: raw.max_output_tokens,
        per_call_timeout_seconds: raw.per_call_timeout_seconds,
        response_schema: schema.clone(),
    })
}

/// `https://generativelanguage.googleapis.com[/path]` exactly: no port, no
/// credentials, no query; returns the path part.
fn google_base(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    let (host, path) = match rest.find('/') {
        Some(index) => rest.split_at(index),
        None => (rest, ""),
    };
    if host != GOOGLE_HOST || path.contains(['?', '#', '@', '\\']) || path.contains("..") {
        return None;
    }
    Some(path)
}

fn safe_model_path(path: &str) -> bool {
    path.starts_with('/')
        && path.matches(MODEL_PLACEHOLDER).count() == 1
        && !path.contains("..")
        && !path.contains("//")
        && path.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'/' | b'_' | b'-' | b'.' | b':' | b'{' | b'}')
        })
}

pub fn valid_model_id(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'-')
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_bundle_names_a_google_trial_model_for_both_features() {
        let bundle = embedded().expect("embedded bundle parses");
        assert_eq!(
            bundle.generate_url,
            format!(
                "https://{GOOGLE_HOST}/v1beta/models/{}:generateContent",
                bundle.model
            )
        );
        assert_eq!(
            bundle.count_tokens_url,
            format!(
                "https://{GOOGLE_HOST}/v1beta/models/{}:countTokens",
                bundle.model
            )
        );
        assert!(bundle.ad_detection.response_schema.is_object());
        assert!(bundle.chapters_summary.response_schema.is_object());
    }

    #[test]
    fn a_bundle_that_points_the_key_elsewhere_is_refused() {
        let base: Value = serde_json::from_str(EMBEDDED_BUNDLE_JSON).unwrap();
        for (pointer, value, expected) in [
            (
                "/providers/google/base_url",
                "https://example.com/v1beta",
                BundleError::ProviderHost,
            ),
            (
                "/providers/google/base_url",
                "http://generativelanguage.googleapis.com/v1beta",
                BundleError::ProviderHost,
            ),
            (
                "/providers/google/base_url",
                "https://generativelanguage.googleapis.com:8443/v1beta",
                BundleError::ProviderHost,
            ),
            (
                "/providers/google/base_url",
                "https://user@generativelanguage.googleapis.com/v1beta",
                BundleError::ProviderHost,
            ),
            (
                "/providers/google/generate_path",
                "/models/x:generateContent",
                BundleError::ProviderPath,
            ),
            (
                "/providers/google/generate_path",
                "/../{model}:generateContent",
                BundleError::ProviderPath,
            ),
            ("/trial/model", "Gemini 3.8", BundleError::ModelId),
            ("/trial/starts_at", "2027-01-01", BundleError::StartsAt),
            (
                "/trial/model",
                "gemini-0-missing",
                BundleError::MissingEntry(Feature::AdDetection),
            ),
        ] {
            let mut bundle = base.clone();
            *bundle.pointer_mut(pointer).unwrap() = Value::String(value.to_string());
            assert_eq!(
                parse_bundle(&bundle.to_string()),
                Err(expected),
                "{pointer} = {value}"
            );
        }
        let mut headers = base.clone();
        headers["providers"]["google"]["version_headers"] =
            serde_json::json!({"x-goog-api-client": "opencast"});
        assert_eq!(
            parse_bundle(&headers.to_string()),
            Err(BundleError::VersionHeaders)
        );
    }
}

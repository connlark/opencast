//! The analysis policy bundle: the signed document the app reads its analysis
//! prompts, response schemas, model entries, timeouts and limits from.
//!
//! Host-only. Every number, prompt and schema is imported from the analysis
//! workers' own source (the code the qualified results came from), so a
//! bundle cannot drift from what was qualified by retyping. The few facts the
//! workers do not hold (the OpenAI golden model, provider wire facts, the
//! trial and notice blocks, the key pages) are the named constants below.

use std::collections::BTreeMap;

use opencast_ad_analysis_worker::{
    policy as ad_policy, promo_v3, prompt as ad_prompt, v3_windowing, validation as ad_validation,
};
use opencast_transcript_analysis_worker::{
    coalescing, prompt as chapters_prompt, retry as chapters_retry, types as chapters_types,
    validation as chapters_validation,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::manifest_signature::{sign_manifest_bytes, verify_manifest_bytes, ManifestSignature};

/// Document format the app reads. A change that older apps cannot ignore
/// bumps this; adding optional fields or a provider does not.
pub const SCHEMA_VERSION: u8 = 1;

/// The production signing key id (advisory; clients verify with a pinned key).
pub const SIGNATURE_KEY_ID: &str = "opencast-remote-models-2026-07";
/// Public half of the production signing key, pinned by the app.
pub const PINNED_PUBLIC_KEY_HEX: &str =
    "795f50cc77f7e9723687492643cb3a99a1c5b1c4d145ab75ce2576d4d955d028";

/// The OpenAI golden model: qualified for ad detection on the golden suite at
/// medium reasoning effort, with the Gemini entry's timeouts, and for
/// Chapters & Summary on device beside [`CHAPTERS_GOOGLE_MODEL`].
pub const OPENAI_GOLDEN_MODEL: &str = "gpt-6.1-sol";
pub const OPENAI_GOLDEN_LABEL: &str = "GPT-6.1 Sol";
pub const OPENAI_GOLDEN_THINKING: &str = "medium";
/// Picker labels for the Gemini ids the ad worker can name. A new model id in
/// `policy::V3_MODEL` fails generation until it has a label here.
const GOOGLE_LABELS: &[(&str, &str)] = &[("gemini-3.8-flash", "Gemini 3.8 Flash")];
/// The Gemini model qualified for Chapters & Summary on device (2026-10-24,
/// a 15- and a 59-minute episode, two replicates each, no chapter starting
/// inside a known ad). Named on its own: the ad worker's model may move
/// without it.
pub const CHAPTERS_GOOGLE_MODEL: &str = "gemini-3.8-flash";
/// The thinking level both Chapters & Summary entries were qualified with.
/// The first request of a run uses it below the escalation threshold; every
/// retry and every long transcript escalates to `high` in the pipeline.
pub const CHAPTERS_THINKING: &str = "medium";

const GOOGLE_COUNT_TOKENS_PATH: &str = "/models/{model}:countTokens";
const OPENAI_BASE_URL: &str = "https://api.openai.com/v1";
const OPENAI_GENERATE_PATH: &str = "/responses";
const OPENAI_COUNT_TOKENS_PATH: &str = "/responses/input_tokens";

/// Display facts for the opencast-funded trial; the trial worker enforces.
pub const TRIAL_ENDPOINT: &str = "https://trial.opencast.mobile";
pub const TRIAL_STARTS_AT: &str = "2027-01-01T00:00:00Z";
pub const TRIAL_LIFETIME_UNITS: u32 = 5;

/// When the in-app notice about provider keys starts: the first bundle that
/// carried it (its `generated_at`). Kept as a constant so a later bundle does
/// not move it unless someone means to.
pub const NOTICE_STARTS_AT: &str = "2026-10-25T01:10:00Z";

/// The pages where a listener creates a key, opened from the key sheet. They
/// live in the bundle so a moved page is a bundle edit, not a release.
pub const GOOGLE_KEY_URL: &str = "https://aistudio.google.com/app/apikey";
pub const OPENAI_KEY_URL: &str = "https://platform.openai.com/settings/organization/api-keys";

/// What the app pins per provider: the only host its key may be sent to,
/// how the key is sent, and the thinking levels its golden models accept.
pub struct ProviderRules {
    pub provider: &'static str,
    pub host: &'static str,
    pub auth: &'static str,
    pub thinking: &'static [&'static str],
}

pub const PROVIDER_RULES: &[ProviderRules] = &[
    ProviderRules {
        provider: "google",
        host: "generativelanguage.googleapis.com",
        auth: "x-goog-api-key",
        thinking: &["low", "medium", "high"],
    },
    ProviderRules {
        provider: "openai",
        host: "api.openai.com",
        auth: "bearer",
        thinking: &["none", "low", "medium", "high"],
    },
];

/// Longest prompt and largest compact response schema, in UTF-8 bytes.
pub const MAX_TEXT_FIELD_BYTES: usize = 65_536;
const MAX_VERSION_HEADERS: usize = 8;
/// Longest key page URL, in bytes (the app's limit).
const MAX_KEY_URL_BYTES: usize = 256;
const CREDENTIAL_HEADERS: &[&str] = &[
    "authorization",
    "x-goog-api-key",
    "x-api-key",
    "cookie",
    "host",
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalysisPolicyBundle {
    pub schema_version: u8,
    pub bundle_version: u32,
    pub generated_at: String,
    pub min_app_build: u32,
    pub features: Features,
    pub providers: BTreeMap<String, ProviderEndpoint>,
    pub trial: Trial,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<Notice>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Features {
    pub ad_detection: AdDetection,
    pub chapters_summary: ChaptersSummary,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdDetection {
    pub policy: String,
    pub revision: String,
    pub prompt: String,
    pub response_schema: Value,
    pub window: Window,
    pub limits: Limits,
    pub repair: Repair,
    pub qualified_models: Vec<ModelEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Window {
    pub segments: usize,
    pub overlap: usize,
    pub max_in_flight: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    pub spans_per_window: usize,
    pub max_break_seconds: f64,
    pub budget_fraction: f64,
    pub budget_floor_seconds: f64,
    pub evidence_words: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Repair {
    pub attempts: usize,
    pub feedback_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChaptersSummary {
    pub policy: String,
    pub revision: String,
    pub prompt: String,
    pub response_schema: Value,
    pub coalescing: Coalescing,
    pub chapter_cap: ChapterCap,
    pub allowed_models: Vec<ModelEntry>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Coalescing {
    pub above_segments: usize,
    pub unit_seconds: f64,
    pub unit_chars: usize,
    pub gap_seconds: f64,
    pub max_units: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChapterCap {
    pub min: usize,
    pub seconds_per_chapter: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelEntry {
    pub provider: String,
    pub model_id: String,
    pub label: String,
    pub thinking: String,
    pub max_output_tokens: u32,
    pub per_call_timeout_seconds: u64,
    pub run_budget_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderEndpoint {
    pub base_url: String,
    pub auth: String,
    pub generate_path: String,
    pub count_tokens_path: String,
    pub version_headers: BTreeMap<String, String>,
    /// Where a listener creates a key for this provider (https, no query or
    /// fragment). Optional: older bundles have none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Trial {
    pub endpoint: String,
    pub starts_at: String,
    pub lifetime_units: u32,
    pub model: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Notice {
    pub starts_at: String,
}

/// The release facts a bundle carries that are not analysis settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationInputs {
    pub bundle_version: u32,
    pub generated_at: String,
    pub min_app_build: u32,
}

/// Builds the bundle from the analysis workers' constants.
///
/// # Errors
///
/// Returns an error when an imported value has no editorial counterpart here
/// (a Gemini id without a label), when the chapters prompt cannot be
/// isolated, or when the result fails [`check_bundle`].
pub fn generate(inputs: &GenerationInputs) -> Result<AnalysisPolicyBundle, String> {
    let gemini = ModelEntry {
        provider: "google".to_string(),
        model_id: ad_policy::V3_MODEL.to_string(),
        label: google_label(ad_policy::V3_MODEL)?.to_string(),
        thinking: ad_policy::V3_THINKING.to_string(),
        max_output_tokens: ad_prompt::GEMINI_MAX_OUTPUT_TOKENS,
        per_call_timeout_seconds: ad_policy::V3_MAX_CALL_SECONDS,
        run_budget_seconds: ad_policy::V3_EXECUTION_SECONDS,
    };
    let sol = ModelEntry {
        provider: "openai".to_string(),
        model_id: OPENAI_GOLDEN_MODEL.to_string(),
        label: OPENAI_GOLDEN_LABEL.to_string(),
        thinking: OPENAI_GOLDEN_THINKING.to_string(),
        ..gemini.clone()
    };

    // Chapters & Summary entries carry the Chapters worker's output cap,
    // first-call timeout and run budget, the settings they were qualified
    // with.
    let chapters_gemini = ModelEntry {
        provider: "google".to_string(),
        model_id: CHAPTERS_GOOGLE_MODEL.to_string(),
        label: google_label(CHAPTERS_GOOGLE_MODEL)?.to_string(),
        thinking: CHAPTERS_THINKING.to_string(),
        max_output_tokens: chapters_prompt::GEMINI_MAX_OUTPUT_TOKENS,
        per_call_timeout_seconds: chapters_retry::GEMINI_CALL_TIMEOUT_MEDIUM_SECONDS,
        run_budget_seconds: chapters_retry::ANALYSIS_RUN_BUDGET_SECONDS,
    };
    let chapters_sol = ModelEntry {
        provider: "openai".to_string(),
        model_id: OPENAI_GOLDEN_MODEL.to_string(),
        label: OPENAI_GOLDEN_LABEL.to_string(),
        ..chapters_gemini.clone()
    };

    let bundle = AnalysisPolicyBundle {
        schema_version: SCHEMA_VERSION,
        bundle_version: inputs.bundle_version,
        generated_at: inputs.generated_at.clone(),
        min_app_build: inputs.min_app_build,
        features: Features {
            ad_detection: AdDetection {
                policy: promo_v3::POLICY.to_string(),
                revision: ad_policy::V3_REVISION.to_string(),
                prompt: promo_v3::INSTRUCTIONS.to_string(),
                response_schema: promo_v3::schema(),
                window: Window {
                    segments: v3_windowing::WINDOW_SEGMENTS,
                    overlap: v3_windowing::OVERLAP_SEGMENTS,
                    max_in_flight: v3_windowing::CONCURRENT_WINDOWS,
                },
                limits: Limits {
                    spans_per_window: promo_v3::MAX_BREAKS_PER_WINDOW,
                    max_break_seconds: promo_v3::MAX_BREAK_SECONDS,
                    budget_fraction: ad_validation::AD_BUDGET_EPISODE_FRACTION,
                    budget_floor_seconds: ad_validation::AD_BUDGET_FLOOR_SECONDS,
                    evidence_words: promo_v3::MAX_EVIDENCE_WORDS,
                },
                repair: Repair {
                    attempts: ad_policy::V3_REPAIR_ATTEMPTS,
                    feedback_bytes: promo_v3::MAX_REPAIR_FEEDBACK_BYTES,
                },
                qualified_models: vec![gemini.clone(), sol],
            },
            chapters_summary: ChaptersSummary {
                policy: chapters_types::POLICY_NAME.to_string(),
                revision: chapters_types::POLICY_NAME.to_string(),
                prompt: chapters_rules()?,
                response_schema: serde_json::from_str(chapters_prompt::RESPONSE_SCHEMA)
                    .map_err(|error| format!("chapters response schema: {error}"))?,
                coalescing: Coalescing {
                    above_segments: coalescing::COALESCING_TRIGGER_SEGMENT_COUNT,
                    unit_seconds: coalescing::MIN_UNIT_SPAN_BEFORE_CLOSE,
                    unit_chars: coalescing::UNIT_JOIN_CHAR_LIMIT,
                    gap_seconds: coalescing::GAP_BREAK_SECONDS,
                    max_units: chapters_types::MAX_MODEL_UNITS,
                },
                chapter_cap: ChapterCap {
                    min: chapters_validation::MIN_CHAPTERS_FLOOR,
                    seconds_per_chapter: chapters_validation::CHAPTER_SECONDS_PER_CHAPTER,
                },
                allowed_models: vec![chapters_gemini, chapters_sol],
            },
        },
        providers: providers()?,
        trial: Trial {
            endpoint: TRIAL_ENDPOINT.to_string(),
            starts_at: TRIAL_STARTS_AT.to_string(),
            lifetime_units: TRIAL_LIFETIME_UNITS,
            model: gemini.model_id,
        },
        notice: Some(Notice {
            starts_at: NOTICE_STARTS_AT.to_string(),
        }),
    };
    check_bundle(&bundle)?;
    Ok(bundle)
}

/// Pretty JSON, the exact bytes that are signed, served and baked.
///
/// # Errors
///
/// Returns an error only if serialization fails.
pub fn bundle_json_bytes(bundle: &AnalysisPolicyBundle) -> Result<Vec<u8>, String> {
    serde_json::to_vec_pretty(bundle).map_err(|error| error.to_string())
}

/// Reads a bundle, refusing unknown fields.
///
/// # Errors
///
/// Returns an error when the bytes are not a well-formed bundle.
pub fn parse_bundle(bytes: &[u8]) -> Result<AnalysisPolicyBundle, String> {
    serde_json::from_slice(bytes).map_err(|error| error.to_string())
}

/// Signs bundle bytes and binds the envelope to them: the envelope names the
/// bundle version and the SHA-256 of the exact bytes, so a client fetches that
/// version's immutable copy and can never pair the signature with other bytes.
///
/// # Errors
///
/// Returns an error when the bytes are not a bundle or signing fails.
pub fn sign_policy_bytes(
    bytes: &[u8],
    key_id: &str,
    signing_key_hex: &str,
) -> Result<ManifestSignature, String> {
    let bundle = parse_bundle(bytes)?;
    let mut signature = sign_manifest_bytes(bytes, key_id, signing_key_hex)?;
    signature.bundle_version = Some(bundle.bundle_version);
    signature.sha256 = Some(hex::encode(Sha256::digest(bytes)));
    Ok(signature)
}

/// Verifies a policy signature the way the app does: the pinned-key
/// signature over the bytes, and the envelope naming exactly those bytes.
///
/// # Errors
///
/// Returns the first check that fails.
pub fn verify_policy_bytes(
    bytes: &[u8],
    signature: &ManifestSignature,
    public_key_hex: &str,
    expected_key_id: &str,
) -> Result<(), String> {
    verify_manifest_bytes(bytes, signature, public_key_hex, expected_key_id)?;
    let (Some(version), Some(digest)) = (signature.bundle_version, signature.sha256.as_deref())
    else {
        return Err("signature does not name its bundle".to_string());
    };
    if digest != hex::encode(Sha256::digest(bytes)) {
        return Err("bundle does not match the digest its signature names".to_string());
    }
    if parse_bundle(bytes)?.bundle_version != version {
        return Err("bundle version does not match its signature".to_string());
    }
    Ok(())
}

/// The relational rules the JSON schema cannot state. The app enforces the
/// same rules; this keeps the generator from emitting a bundle it would reject.
///
/// # Errors
///
/// Returns the first violated rule.
pub fn check_bundle(bundle: &AnalysisPolicyBundle) -> Result<(), String> {
    if bundle.schema_version != SCHEMA_VERSION {
        return Err(format!(
            "schema_version {} is not {SCHEMA_VERSION}",
            bundle.schema_version
        ));
    }
    let timestamps = [
        ("generated_at", Some(&bundle.generated_at)),
        ("trial.starts_at", Some(&bundle.trial.starts_at)),
        (
            "notice.starts_at",
            bundle.notice.as_ref().map(|notice| &notice.starts_at),
        ),
    ];
    for (field, value) in timestamps {
        if let Some(value) = value {
            if canonical_utc_timestamp_seconds(value).is_none() {
                return Err(format!(
                    "{field} must be a UTC timestamp like 2026-10-24T00:00:00Z"
                ));
            }
        }
    }
    let ad = &bundle.features.ad_detection;
    if 2 * ad.window.overlap >= ad.window.segments {
        return Err("ad_detection.window.overlap must be under half the window".to_string());
    }
    let chapters = &bundle.features.chapters_summary;
    check_text("ad_detection", &ad.prompt, &ad.response_schema)?;
    check_text(
        "chapters_summary",
        &chapters.prompt,
        &chapters.response_schema,
    )?;
    check_entries("ad_detection.qualified_models", &ad.qualified_models)?;
    check_entries("chapters_summary.allowed_models", &chapters.allowed_models)?;
    for rules in PROVIDER_RULES {
        let provider = rules.provider;
        let Some(endpoint) = bundle.providers.get(provider) else {
            return Err(format!("providers.{provider} is missing"));
        };
        if https_host(&endpoint.base_url) != Some(rules.host) {
            return Err(format!(
                "providers.{provider}.base_url must be on https://{}",
                rules.host
            ));
        }
        if endpoint.auth != rules.auth {
            return Err(format!("providers.{provider}.auth must be {}", rules.auth));
        }
        for path in [&endpoint.generate_path, &endpoint.count_tokens_path] {
            if !safe_path(path) {
                return Err(format!("providers.{provider} has an unsafe path {path}"));
            }
        }
        if endpoint
            .key_url
            .as_deref()
            .is_some_and(|url| url.len() > MAX_KEY_URL_BYTES || https_host(url).is_none())
        {
            return Err(format!(
                "providers.{provider}.key_url must be https with no query or fragment"
            ));
        }
        if endpoint.version_headers.len() > MAX_VERSION_HEADERS
            || !endpoint
                .version_headers
                .iter()
                .all(|(name, value)| safe_version_header(name, value))
        {
            return Err(format!(
                "providers.{provider}.version_headers are not allowed"
            ));
        }
    }
    let trial_model_is_google_ad_entry = ad
        .qualified_models
        .iter()
        .any(|entry| entry.provider == "google" && entry.model_id == bundle.trial.model);
    if !trial_model_is_google_ad_entry {
        return Err("trial.model must name a google ad_detection entry".to_string());
    }
    let trial_host_is_opencast = https_host(&bundle.trial.endpoint)
        .is_some_and(|host| host == "opencast.mobile" || host.ends_with(".opencast.mobile"));
    if !trial_host_is_opencast {
        return Err("trial.endpoint must be https on opencast.mobile".to_string());
    }
    Ok(())
}

/// Seconds since 1970 for a canonical UTC timestamp `YYYY-MM-DDTHH:MM:SSZ`
/// (a real calendar date, hours 00-23, minutes and seconds 00-59), else
/// `None`. The app decodes bundle timestamps with the same rule, so a bundle
/// that passes here always decodes there.
pub fn canonical_utc_timestamp_seconds(value: &str) -> Option<i64> {
    let bytes = value.as_bytes();
    if !value.is_ascii()
        || bytes.len() != 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'Z'
    {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let digits = &value[range];
        digits
            .bytes()
            .all(|byte| byte.is_ascii_digit())
            .then(|| digits.parse().ok())
            .flatten()
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if !(1..=12).contains(&month)
        || !(1..=month_days[(month - 1) as usize]).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let shifted_year = if month <= 2 { year - 1 } else { year };
    let era = shifted_year.div_euclid(400);
    let year_of_era = shifted_year - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// The host of an `https://example.com[/path]`-shaped URL with no user info,
/// port, query or fragment; anything else is `None`.
pub fn https_host(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    let (host, path) = rest.split_once('/').map_or((rest, ""), |(h, p)| (h, p));
    let host_ok = !host.is_empty()
        && host.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'-')
        });
    let path_ok = path.is_empty() || safe_path(&format!("/{path}"));
    (host_ok && path_ok).then_some(host)
}

/// Visible ASCII only (no spaces, controls or encoded bytes), so the raw text
/// the app checks is the text this checks.
fn safe_path(path: &str) -> bool {
    path.starts_with('/')
        && path.bytes().all(|byte| (0x21..0x7f).contains(&byte))
        && !path.contains("..")
        && !path.contains("//")
        && !path.contains(['?', '#', '\\', '@', '%', ' '])
}

fn check_text(field: &str, prompt: &str, schema: &Value) -> Result<(), String> {
    if prompt.is_empty() || prompt.len() > MAX_TEXT_FIELD_BYTES {
        return Err(format!(
            "{field}.prompt must be 1 to {MAX_TEXT_FIELD_BYTES} bytes"
        ));
    }
    let schema_bytes = serde_json::to_vec(schema).map_err(|error| error.to_string())?;
    if !schema.is_object() || schema_bytes.len() > MAX_TEXT_FIELD_BYTES {
        return Err(format!(
            "{field}.response_schema must be an object of at most {MAX_TEXT_FIELD_BYTES} bytes"
        ));
    }
    Ok(())
}

fn safe_version_header(name: &str, value: &str) -> bool {
    let name = name.to_ascii_lowercase();
    (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && !CREDENTIAL_HEADERS.contains(&name.as_str())
        && (1..=256).contains(&value.len())
        && value.bytes().all(|byte| (0x20..0x7f).contains(&byte))
}

fn check_entries(field: &str, entries: &[ModelEntry]) -> Result<(), String> {
    let mut providers = Vec::new();
    for entry in entries {
        if providers.contains(&entry.provider.as_str()) {
            return Err(format!("{field} lists {} twice", entry.provider));
        }
        providers.push(entry.provider.as_str());
        let Some(rules) = PROVIDER_RULES
            .iter()
            .find(|rules| rules.provider == entry.provider)
        else {
            return Err(format!("{field} names an unknown provider"));
        };
        if !rules.thinking.contains(&entry.thinking.as_str()) {
            return Err(format!(
                "{field} thinking {} is not a {} level",
                entry.thinking, entry.provider
            ));
        }
        if !valid_model_id(&entry.model_id) {
            return Err(format!("{field} has an invalid model id"));
        }
        if entry.run_budget_seconds < entry.per_call_timeout_seconds {
            return Err(format!("{field} run budget is shorter than one call"));
        }
    }
    Ok(())
}

/// Model ids are interpolated into request paths: 1-128 of `[A-Za-z0-9._-]`.
pub fn valid_model_id(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn google_label(model_id: &str) -> Result<&'static str, String> {
    GOOGLE_LABELS
        .iter()
        .find(|(id, _)| *id == model_id)
        .map(|(_, label)| *label)
        .ok_or_else(|| format!("no picker label for {model_id}"))
}

/// The rules text the chapters worker renders before its per-request header.
fn chapters_rules() -> Result<String, String> {
    let request: chapters_types::TranscriptAnalysisRequest = serde_json::from_value(json!({
        "schema_version": chapters_types::SCHEMA_VERSION,
        "request_id": "r",
        "episode_id": "e",
        "podcast_id": "p",
        "transcript": {
            "language_code": "en",
            "audio_duration": 1.0,
            "fingerprint": "f",
            "updated_at": "2026-01-01T00:00:00Z",
            "state": "complete",
            "segment_count": 0
        },
        "segments": []
    }))
    .map_err(|error| format!("chapters probe request: {error}"))?;
    let rendered = chapters_prompt::build_prompt(&request);
    let marker = format!("\n\nPolicy: {}\n", chapters_types::POLICY_NAME);
    let (rules, _) = rendered
        .split_once(&marker)
        .ok_or_else(|| "chapters prompt has no policy header".to_string())?;
    if rules.is_empty() || rules.contains(&marker) {
        return Err("chapters rules could not be isolated".to_string());
    }
    Ok(rules.to_string())
}

fn providers() -> Result<BTreeMap<String, ProviderEndpoint>, String> {
    let google_generate = ad_prompt::gemini_generate_content_url("{model}");
    let (google_base, google_generate_path) = google_generate
        .split_once("/models/")
        .map(|(base, rest)| (base.to_string(), format!("/models/{rest}")))
        .ok_or_else(|| "gemini URL has no /models/ path".to_string())?;
    Ok(BTreeMap::from([
        (
            "google".to_string(),
            ProviderEndpoint {
                base_url: google_base,
                auth: "x-goog-api-key".to_string(),
                generate_path: google_generate_path,
                count_tokens_path: GOOGLE_COUNT_TOKENS_PATH.to_string(),
                version_headers: BTreeMap::new(),
                key_url: Some(GOOGLE_KEY_URL.to_string()),
            },
        ),
        (
            "openai".to_string(),
            ProviderEndpoint {
                base_url: OPENAI_BASE_URL.to_string(),
                auth: "bearer".to_string(),
                generate_path: OPENAI_GENERATE_PATH.to_string(),
                count_tokens_path: OPENAI_COUNT_TOKENS_PATH.to_string(),
                version_headers: BTreeMap::new(),
                key_url: Some(OPENAI_KEY_URL.to_string()),
            },
        ),
    ]))
}

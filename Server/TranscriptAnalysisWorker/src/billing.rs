//! Pure billing rules for the pay-gate. Money movement
//! lives in `credit.rs` (worker-side seam); everything here is host-testable
//! arithmetic and policy: the flat blended rate, the server-authoritative
//! duration, billing-id minting rules, and lane/backend validation.
//!
//! Invariants:
//! - Billing never touches the model request: nothing here reads or writes
//!   prompt inputs.
//! - One reserve per run attempt under a FRESH `tan-` billing id — NEVER the
//!   transcript fingerprint. PurchaseWorker's `reserve:<job_id>` ledger key
//!   is permanent and a released id can never be re-reserved, while this
//!   worker restarts failed jobs under the same fingerprint. The `tan-`
//!   prefix also keeps the global reservation_index disjoint from RTW's
//!   `job-` ids.

use serde::{Deserialize, Serialize};

use crate::types::{TranscriptAnalysisRequest, TranscriptSegment};

/// Flat blended rate: credit-seconds charged per analyzed audio-hour,
/// calibrated from $0.108/audio-hour at $1.375e-5/credit-second. This is the
/// launch value. Post-ship recalibration from observed usage may only lower
/// it after explicit approval.
pub const ANALYSIS_CREDIT_SECONDS_PER_AUDIO_HOUR: u32 = 7_850;

/// Bounded post-terminal billing repair: the terminal-path attempt plus
/// three alarm retries before abandonment, paced by
/// `BILLING_RETRY_SECONDS`. Abandonment always errs in the user's favor
/// operationally: an abandoned settle means the user got the result free;
/// an abandoned release is surfaced loudly via console_error.
pub const BILLING_MAX_ATTEMPTS: u32 = 4;
pub const BILLING_RETRY_SECONDS: u64 = 60;

/// Pacing for the next billing-retry alarm: `BILLING_RETRY_SECONDS`, clamped
/// so a retry never overshoots the record's purge deadline. The single home
/// for this expression — the terminal path and the alarm retries must pace
/// identically.
pub fn billing_retry_delay_seconds(purge_at: i64, now: i64) -> u64 {
    BILLING_RETRY_SECONDS.min(purge_at.saturating_sub(now).max(1) as u64)
}

pub const ERROR_INSUFFICIENT_SECONDS: &str = "insufficient_transcription_seconds";
pub const ERROR_BOOTSTRAP_REQUIRED: &str = "bootstrap_required";
/// Billed work runs only on the durable job lane: the sync exchange has no
/// record to repair from, so a mid-run disconnect would strand the hold
/// forever (PurchaseWorker has no reservation expiry). The shipped app
/// always requests async; a billed `async_supported: false` caller must
/// upgrade.
pub const ERROR_ASYNC_REQUIRED: &str = "async_required";
/// Billing-required lanes fail CLOSED behind this code whenever the credit
/// backend is unreachable or misconfigured — money correctness over
/// availability.
pub const ERROR_BILLING_UNAVAILABLE: &str = "billing_unavailable";

/// Server-authoritative duration: a client cannot underprice
/// a run by understating `audio_duration` — the last segment end backstops
/// it. Validation has already guaranteed a finite positive declared duration
/// and finite, ordered segment timings.
pub fn authoritative_duration_seconds(request: &TranscriptAnalysisRequest) -> f64 {
    let last_end = request
        .segments
        .last()
        .map(|segment: &TranscriptSegment| segment.end)
        .unwrap_or(0.0);
    request.transcript.audio_duration.max(last_end)
}

/// `ceil(duration × RATE / 3600)`, integer credit-seconds. `None` for
/// non-finite or non-positive durations (defense in depth; validation
/// rejects those requests earlier).
pub fn charge_seconds_for_duration(duration_seconds: f64) -> Option<i64> {
    if !duration_seconds.is_finite() || duration_seconds <= 0.0 {
        return None;
    }
    let charge =
        (duration_seconds * f64::from(ANALYSIS_CREDIT_SECONDS_PER_AUDIO_HOUR) / 3_600.0).ceil();
    if !charge.is_finite() || charge < 1.0 || charge > 9_007_199_254_740_992.0 {
        return None;
    }
    Some(charge as i64)
}

/// Builds the billing id from a freshly minted random token. Kept separate
/// from the wasm-side entropy call so the shape rules are host-testable.
pub fn billing_id_from_token(token: &str) -> String {
    format!("tan-{token}")
}

pub fn is_billing_id(value: &str) -> bool {
    value.len() > 4 && value.starts_with("tan-")
}

/// PurchaseWorker bootstrap `install_key` namespace for this worker: opaque
/// to PurchaseWorker (write-only audit index there), prefixed so the audit
/// rows are attributable per consumer and can never collide with RTW's raw
/// install ids.
pub fn purchase_install_key(install_id: &str) -> String {
    format!("tan:{install_id}")
}

// --- Lane / backend configuration (mirrors RTW config.rs, fail closed) -----

pub const LANE_DEVELOPMENT: &str = "development";
pub const LANE_PROD_STAGING: &str = "prod-staging";
pub const LANE_PRODUCTION: &str = "production";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreditBackend {
    Dev,
    Purchase,
}

pub fn validate_lane(value: &str) -> Result<String, String> {
    match value {
        LANE_DEVELOPMENT | LANE_PROD_STAGING | LANE_PRODUCTION => Ok(value.to_string()),
        other => Err(format!("LANE must be a known lane, got {other:?}")),
    }
}

/// Backend resolution (RTW config.rs rule, fail closed): an explicit
/// `CREDIT_BACKEND` wins; absent derives `dev` only on the development lane
/// — a money lane must opt into the purchase backend explicitly, so a lane
/// whose billing vars were wholesale forgotten refuses to serve instead of
/// booting on a silent default. The dev fake is forbidden outside the
/// development lane in BOTH paths — there is no configuration in which a
/// money lane can be served by the fake.
pub fn validate_credit_backend(
    lane: &str,
    explicit: Option<&str>,
) -> Result<CreditBackend, String> {
    let backend = match explicit {
        None => {
            if lane == LANE_DEVELOPMENT {
                CreditBackend::Dev
            } else {
                return Err("non-development lanes must set CREDIT_BACKEND=purchase".to_string());
            }
        }
        Some("dev") => CreditBackend::Dev,
        Some("purchase") => CreditBackend::Purchase,
        Some(other) => {
            return Err(format!(
                "CREDIT_BACKEND must be dev or purchase, got {other:?}"
            ))
        }
    };
    if backend == CreditBackend::Dev && lane != LANE_DEVELOPMENT {
        return Err("dev credit backend is forbidden outside the development lane".to_string());
    }
    Ok(backend)
}

/// `BILLING_REQUIRED` is the money kill-switch: parse it as strictly as the
/// lane/backend vars. Absent stays dark (false); anything but exactly
/// "true"/"false" is a config error — a mistyped flip must fail the deploy
/// loudly, never serve free while the toml looks flipped.
pub fn validate_billing_required(explicit: Option<&str>) -> Result<bool, String> {
    match explicit {
        None | Some("false") => Ok(false),
        Some("true") => Ok(true),
        Some(other) => Err(format!(
            "BILLING_REQUIRED must be true or false, got {other:?}"
        )),
    }
}

// --- Wire shapes ------------------------------------------------------------

/// Gateway → job-DO billing directive, resolved server-side from the
/// authenticated install. Absent on the billing-exempt bearer probe lane and
/// whenever `BILLING_REQUIRED` is dark.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct BillingContext {
    pub account_id: String,
    pub charge_seconds: i64,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PendingBillingAction {
    Settle,
    Release,
}

/// Billing bookkeeping carried on the job record from reserve to terminal.
/// `pending` survives a failed terminal settle/release for the bounded alarm
/// retries; `attempts` counts failures toward `BILLING_MAX_ATTEMPTS`.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct JobBillingState {
    pub billing_id: String,
    pub charge_seconds: i64,
    #[serde(default)]
    pub pending: Option<PendingBillingAction>,
    #[serde(default)]
    pub attempts: u32,
}

impl JobBillingState {
    pub fn reserved(billing_id: String, charge_seconds: i64) -> Self {
        Self {
            billing_id,
            charge_seconds,
            pending: None,
            attempts: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{TranscriptMetadata, TranscriptSegment};

    fn request_with(duration: f64, last_end: f64) -> TranscriptAnalysisRequest {
        TranscriptAnalysisRequest {
            schema_version: 1,
            async_supported: true,
            request_id: "r".to_string(),
            episode_id: "e".to_string(),
            podcast_id: "p".to_string(),
            episode_title: None,
            podcast_title: None,
            transcript: TranscriptMetadata {
                language_code: "en".to_string(),
                audio_duration: duration,
                model_identifier: None,
                model_version: None,
                model_tree_sha256: None,
                fingerprint: "f".repeat(64),
                updated_at: "2026-08-28T00:00:00Z".to_string(),
                state: "completed".to_string(),
                segment_count: 1,
            },
            segments: vec![TranscriptSegment {
                id: 0,
                start: 0.0,
                end: last_end,
                text: "hello".to_string(),
            }],
        }
    }

    #[test]
    fn rate_constant_matches_the_client_contract() {
        // The client mirror pins against this exact value; changing it is a
        // deliberate contract update, never a drive-by.
        assert_eq!(ANALYSIS_CREDIT_SECONDS_PER_AUDIO_HOUR, 7_850);
    }

    #[test]
    fn rate_matches_shared_client_fixture() {
        // The app's display mirror (TranscriptAnalysisBillingRate) pins the
        // same committed fixture, so the two constants cannot drift apart
        // silently: a rate change must touch the fixture, which fails
        // both suites until both constants follow.
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/analysis_credit_rate.json"))
                .expect("fixture parses");
        assert_eq!(
            fixture["analysis_credit_seconds_per_audio_hour"],
            serde_json::json!(ANALYSIS_CREDIT_SECONDS_PER_AUDIO_HOUR)
        );
    }

    #[test]
    fn charge_is_ceiled_rate_scaled_duration() {
        assert_eq!(charge_seconds_for_duration(3_600.0), Some(7_850));
        // One second of audio still charges one credit-second (ceil).
        assert_eq!(charge_seconds_for_duration(0.25), Some(1));
        // 3.454 h QA fixture: 12434.5 s × 7850 / 3600 = 27114.1… → 27115.
        assert_eq!(charge_seconds_for_duration(12_434.5), Some(27_115));
        assert_eq!(charge_seconds_for_duration(0.0), None);
        assert_eq!(charge_seconds_for_duration(-5.0), None);
        assert_eq!(charge_seconds_for_duration(f64::NAN), None);
        assert_eq!(charge_seconds_for_duration(f64::INFINITY), None);
    }

    #[test]
    fn duration_is_server_authoritative_max() {
        // Understated declared duration is backstopped by the last segment.
        assert_eq!(
            authoritative_duration_seconds(&request_with(10.0, 900.0)),
            900.0
        );
        // Declared duration longer than the transcript keeps its price.
        assert_eq!(
            authoritative_duration_seconds(&request_with(900.0, 850.0)),
            900.0
        );
    }

    #[test]
    fn billing_ids_are_tan_prefixed_and_never_fingerprints() {
        let id = billing_id_from_token("AbCd1234EfGh5678");
        assert_eq!(id, "tan-AbCd1234EfGh5678");
        assert!(is_billing_id(&id));
        assert!(!is_billing_id("tan-"));
        assert!(!is_billing_id(&"a".repeat(64)));
        assert!(crate::job::valid_job_id(&id));
    }

    #[test]
    fn install_key_is_namespaced_for_purchase_worker() {
        assert_eq!(purchase_install_key("install-1"), "tan:install-1");
    }

    #[test]
    fn lane_validation_accepts_known_lanes_only() {
        assert!(validate_lane("development").is_ok());
        assert!(validate_lane("prod-staging").is_ok());
        assert!(validate_lane("production").is_ok());
        assert!(validate_lane("staging").is_err());
        assert!(validate_lane("").is_err());
    }

    #[test]
    fn credit_backend_requires_explicit_choice_on_money_lanes() {
        assert_eq!(
            validate_credit_backend("development", None),
            Ok(CreditBackend::Dev)
        );
        // Money lanes never get a silent default: absent refuses to serve.
        assert!(validate_credit_backend("prod-staging", None).is_err());
        assert!(validate_credit_backend("production", None).is_err());
        assert_eq!(
            validate_credit_backend("prod-staging", Some("purchase")),
            Ok(CreditBackend::Purchase)
        );
        assert_eq!(
            validate_credit_backend("production", Some("purchase")),
            Ok(CreditBackend::Purchase)
        );
        assert_eq!(
            validate_credit_backend("development", Some("purchase")),
            Ok(CreditBackend::Purchase)
        );
        assert!(validate_credit_backend("prod-staging", Some("dev")).is_err());
        assert!(validate_credit_backend("production", Some("dev")).is_err());
        assert!(validate_credit_backend("development", Some("bogus")).is_err());
    }

    #[test]
    fn billing_required_parses_strictly_or_fails_loud() {
        assert_eq!(validate_billing_required(None), Ok(false));
        assert_eq!(validate_billing_required(Some("false")), Ok(false));
        assert_eq!(validate_billing_required(Some("true")), Ok(true));
        // Every other spelling is a config error, never a silent false.
        for invalid in ["True", "TRUE", "1", "yes", "true ", " true", ""] {
            assert!(validate_billing_required(Some(invalid)).is_err());
        }
    }

    #[test]
    fn billing_retry_delay_paces_and_clamps_to_the_purge_deadline() {
        assert_eq!(billing_retry_delay_seconds(2_000, 100), 60);
        assert_eq!(billing_retry_delay_seconds(140, 100), 40);
        // At/after the deadline the delay floors at one second, never zero.
        assert_eq!(billing_retry_delay_seconds(100, 100), 1);
        assert_eq!(billing_retry_delay_seconds(50, 100), 1);
    }

    #[test]
    fn job_billing_state_serde_defaults_cover_deploy_skew() {
        let decoded: JobBillingState =
            serde_json::from_str(r#"{"billing_id":"tan-x1","charge_seconds":42}"#).unwrap();
        assert_eq!(decoded.pending, None);
        assert_eq!(decoded.attempts, 0);
    }
}

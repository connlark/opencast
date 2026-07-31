use crate::types::ErrorResponse;
use worker::Env;

pub const LANE_DEVELOPMENT: &str = "development";

/// Which authority backs the credit seam (pass 1 decision: same call sites,
/// swapped backend). `Dev` is the D1 fake and may only exist in the
/// development lane; `Purchase` is the private PurchaseWorker service
/// binding. Selection is explicit config — a non-development lane that does
/// not opt into `purchase` fails closed at config time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreditBackend {
    Dev,
    Purchase,
}

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub app_id: String,
    pub app_attest_environment: String,
    pub lane: String,
    pub model: String,
    pub dev_bearer_enabled: bool,
    pub credit_backend: CreditBackend,
    /// Purchase kill switch (decision 12): hides store/purchase routes only.
    pub purchases_enabled: bool,
    pub dev_credit_grant_seconds: i64,
    pub max_canonical_duration_seconds: f64,
    pub max_source_bytes: i64,
    pub max_active_jobs_per_account: i64,
    pub max_chunk_attempts: u32,
    /// Bounded chunk fan-out (pass 0.5 decision 1): chunks in flight per
    /// wave. `1` reproduces the pass-0 sequential walk — the rollback story.
    pub chunk_ai_concurrency: u32,
    /// Concurrent transcribing jobs platform-wide (pass 1 decision 8),
    /// clamped so `slots × chunk_ai_concurrency ≤ 8` until Workers AI
    /// rate-limit headroom is measured.
    pub global_inference_concurrency: u32,
    /// Remaining-time contribution used when an older or too-early job
    /// cannot provide a self-estimate to the FIFO limiter.
    pub queue_default_remaining_seconds: u32,
    pub daily_spend_cap_usd_micro: i64,
    pub waiting_for_device_source_deadline_seconds: i64,
    pub awaiting_credits_deadline_seconds: i64,
    /// Exact-device upload deadlines (pass 2 decision 2): both default 12 h,
    /// comfortably inside the one-day R2 lifecycle/multipart-abort backstops.
    pub exact_upload_required_deadline_seconds: i64,
    pub exact_uploading_deadline_seconds: i64,
    /// Uniform non-final part size (pass 2 decision 4). Default 16 MiB;
    /// clamped to R2's 5 MiB non-final minimum.
    pub upload_part_bytes: i64,
    /// Presigned URL expiries (pass 2 decision 3): foreground batches ~15 min,
    /// background-enqueued batches a bounded 4 h.
    pub upload_url_expires_seconds: u32,
    pub upload_background_url_expires_seconds: u32,
    /// How often an `awaiting_credits` job re-attempts its reservation; a
    /// var so workerd tests can drive the credit→resume path in test time.
    pub awaiting_credits_retry_seconds: i64,
    pub staging_origin_deadline_seconds: i64,
    pub origin_fetch_max_redirects: u32,
    pub origin_fetch_wall_seconds: u64,
    pub poll_after_seconds: u32,
    /// Chained cloud ad detection. Fail-safe defaults: disabled ⇒ jobs that
    /// requested the phase finalize immediately with the
    /// `ad_analysis_unavailable` marker — the transcript is never blocked.
    pub ad_analysis_enabled: bool,
    /// Whole-phase deadline; must exceed AdAnalysis's 600 s running
    /// watchdog plus resubmit slack, or timeouts fire under live jobs.
    pub ad_analysis_deadline_seconds: i64,
    pub ad_analysis_poll_seconds: u64,
    pub ad_analysis_max_submit_attempts: u32,
}

impl AppConfig {
    pub fn from_env(env: &Env) -> Result<Self, ErrorResponse> {
        let team_id = required_var(env, "APPLE_TEAM_ID")?;
        let bundle_id = required_var(env, "APPLE_BUNDLE_ID")?;
        let environment = required_var(env, "APP_ATTEST_ENVIRONMENT")?;
        let lane = required_var(env, "LANE")?;
        if !matches!(environment.as_str(), "development" | "production") {
            return Err(ErrorResponse::with_detail(
                "worker_env_invalid",
                "APP_ATTEST_ENVIRONMENT must be development or production",
            ));
        }

        let dev_bearer_flag = optional_var(env, "DEV_BEARER_ENABLED")
            .map(|value| value == "true")
            .unwrap_or(false);
        let dev_bearer_secret_present = env
            .secret("DEV_BEARER_TOKEN")
            .ok()
            .is_some_and(|value| !value.to_string().is_empty());
        let dev_bearer_enabled = validate_lane(
            &lane,
            &environment,
            dev_bearer_flag,
            dev_bearer_secret_present,
        )?;
        let credit_backend =
            validate_credit_backend(&lane, optional_var(env, "CREDIT_BACKEND").as_deref())?;

        let chunk_ai_concurrency = int_var(env, "CHUNK_AI_CONCURRENCY", 4).clamp(1, 8) as u32;
        // Keep slots × chunk fan-out ≤ 8 (decision 8) until Workers AI
        // rate-limit headroom is measured; misconfiguration clamps, never
        // fails, because it only shrinks capacity.
        let max_slots = (8 / chunk_ai_concurrency).max(1);
        let global_inference_concurrency =
            int_var(env, "GLOBAL_INFERENCE_CONCURRENCY", 2).clamp(1, i64::from(max_slots)) as u32;

        Ok(Self {
            app_id: format!("{team_id}.{bundle_id}"),
            app_attest_environment: environment,
            lane,
            model: optional_var(env, "REMOTE_TRANSCRIPTION_MODEL")
                .unwrap_or_else(|| "@cf/openai/whisper-large-v3-turbo".to_string()),
            dev_bearer_enabled,
            credit_backend,
            purchases_enabled: optional_var(env, "PURCHASES_ENABLED")
                .map(|value| value != "false")
                .unwrap_or(true),
            dev_credit_grant_seconds: int_var(env, "DEV_CREDIT_GRANT_SECONDS", 36_000),
            max_canonical_duration_seconds: float_var(
                env,
                "MAX_CANONICAL_DURATION_SECONDS",
                7_200.0,
            ),
            max_source_bytes: int_var(env, "MAX_SOURCE_BYTES", 268_435_456),
            max_active_jobs_per_account: int_var(env, "MAX_ACTIVE_JOBS_PER_ACCOUNT", 1),
            max_chunk_attempts: int_var(env, "MAX_CHUNK_ATTEMPTS", 3) as u32,
            chunk_ai_concurrency,
            global_inference_concurrency,
            queue_default_remaining_seconds: int_var(env, "QUEUE_DEFAULT_REMAINING_SECONDS", 64)
                .clamp(1, i64::from(u32::MAX)) as u32,
            daily_spend_cap_usd_micro: int_var(env, "DAILY_SPEND_CAP_USD_MICRO", 1_000_000),
            waiting_for_device_source_deadline_seconds: int_var(
                env,
                "WAITING_FOR_DEVICE_SOURCE_DEADLINE_SECONDS",
                43_200,
            ),
            awaiting_credits_deadline_seconds: int_var(
                env,
                "AWAITING_CREDITS_DEADLINE_SECONDS",
                21_600,
            ),
            awaiting_credits_retry_seconds: int_var(env, "AWAITING_CREDITS_RETRY_SECONDS", 30)
                .max(1),
            exact_upload_required_deadline_seconds: int_var(
                env,
                "EXACT_UPLOAD_REQUIRED_DEADLINE_SECONDS",
                43_200,
            ),
            exact_uploading_deadline_seconds: int_var(
                env,
                "EXACT_UPLOADING_DEADLINE_SECONDS",
                43_200,
            ),
            upload_part_bytes: int_var(env, "UPLOAD_PART_BYTES", 16 * 1024 * 1024)
                .max(5 * 1024 * 1024),
            upload_url_expires_seconds: int_var(env, "UPLOAD_URL_EXPIRES_SECONDS", 900)
                .clamp(60, 3_600) as u32,
            upload_background_url_expires_seconds: int_var(
                env,
                "UPLOAD_BACKGROUND_URL_EXPIRES_SECONDS",
                14_400,
            )
            .clamp(60, 14_400) as u32,
            staging_origin_deadline_seconds: int_var(env, "STAGING_ORIGIN_DEADLINE_SECONDS", 3_600),
            origin_fetch_max_redirects: int_var(env, "ORIGIN_FETCH_MAX_REDIRECTS", 5) as u32,
            origin_fetch_wall_seconds: int_var(env, "ORIGIN_FETCH_WALL_SECONDS", 900) as u64,
            poll_after_seconds: int_var(env, "POLL_AFTER_SECONDS", 5) as u32,
            ad_analysis_enabled: optional_var(env, "AD_ANALYSIS_ENABLED")
                .map(|value| value == "true")
                .unwrap_or(false),
            ad_analysis_deadline_seconds: int_var(env, "AD_ANALYSIS_DEADLINE_SECONDS", 900).max(1),
            ad_analysis_poll_seconds: int_var(env, "AD_ANALYSIS_POLL_SECONDS", 5).max(1) as u64,
            ad_analysis_max_submit_attempts: int_var(env, "AD_ANALYSIS_MAX_SUBMIT_ATTEMPTS", 3)
                .clamp(1, 10) as u32,
        })
    }

    pub fn is_development_lane(&self) -> bool {
        self.lane == LANE_DEVELOPMENT
    }
}

/// Everything needed to mint presigned `UploadPart` URLs. The S3 credential
/// is a narrow Worker secret; absence fails closed (`upload_unavailable`)
/// without affecting any other route — that is how prod-staging behaves until
/// its scoped token is set (pass 2 decision 12).
pub struct UploadPresignSettings {
    pub host: String,
    pub bucket: String,
    pub access_key_id: String,
    pub secret_access_key: String,
}

impl UploadPresignSettings {
    pub fn from_env(env: &Env) -> Option<Self> {
        let host = optional_var(env, "R2_S3_HOST")?;
        let bucket = optional_var(env, "R2_S3_BUCKET")?;
        let access_key_id = env.secret("R2_S3_ACCESS_KEY_ID").ok()?.to_string();
        let secret_access_key = env.secret("R2_S3_SECRET_ACCESS_KEY").ok()?.to_string();
        if host.is_empty() || bucket.is_empty() || access_key_id.is_empty() {
            return None;
        }
        Some(Self {
            host,
            bucket,
            access_key_id,
            secret_access_key,
        })
    }
}

/// Fail-closed lane rule (pass-0 decision 2): the dev bearer gate and the
/// DevCreditAuthority may only exist in the development lane. Any
/// production-shaped configuration that still carries the gate refuses to
/// serve rather than exposing it.
pub fn validate_lane(
    lane: &str,
    app_attest_environment: &str,
    dev_bearer_flag: bool,
    dev_bearer_secret_present: bool,
) -> Result<bool, ErrorResponse> {
    if lane == LANE_DEVELOPMENT {
        if app_attest_environment != "development" {
            return Err(ErrorResponse::with_detail(
                "lane_misconfigured",
                "development lane requires development App Attest",
            ));
        }
        return Ok(dev_bearer_flag && dev_bearer_secret_present);
    }

    if dev_bearer_flag || dev_bearer_secret_present {
        return Err(ErrorResponse::with_detail(
            "lane_misconfigured",
            "dev bearer gate is forbidden outside the development lane",
        ));
    }

    // Pass 0 provisions no non-development lane; when one arrives it must not
    // resolve the DevCreditAuthority. Callers check is_development_lane().
    Ok(false)
}

/// Fail-closed credit-backend rule (pass 1): the D1 dev fake never leaves the
/// development lane, and a non-development lane must opt into the purchase
/// backend explicitly — a missing/unknown value refuses to serve rather than
/// silently granting free dev credits. The development lane may select the
/// purchase backend (strictly more production-shaped; the workerd matrix
/// runs this way), but defaults to the fake.
pub fn validate_credit_backend(
    lane: &str,
    configured: Option<&str>,
) -> Result<CreditBackend, ErrorResponse> {
    let backend = match configured {
        None => {
            if lane == LANE_DEVELOPMENT {
                CreditBackend::Dev
            } else {
                return Err(ErrorResponse::with_detail(
                    "lane_misconfigured",
                    "non-development lanes must set CREDIT_BACKEND=purchase",
                ));
            }
        }
        Some("dev") => CreditBackend::Dev,
        Some("purchase") => CreditBackend::Purchase,
        Some(_) => {
            return Err(ErrorResponse::with_detail(
                "lane_misconfigured",
                "CREDIT_BACKEND must be dev or purchase",
            ))
        }
    };
    if backend == CreditBackend::Dev && lane != LANE_DEVELOPMENT {
        return Err(ErrorResponse::with_detail(
            "lane_misconfigured",
            "the dev credit backend is forbidden outside the development lane",
        ));
    }
    Ok(backend)
}

fn required_var(env: &Env, name: &'static str) -> Result<String, ErrorResponse> {
    env.var(name)
        .map(|value| value.to_string())
        .map_err(|_| ErrorResponse::with_detail("worker_env_missing", name.to_string()))
}

fn optional_var(env: &Env, name: &str) -> Option<String> {
    env.var(name).ok().map(|value| value.to_string())
}

fn int_var(env: &Env, name: &str, default_value: i64) -> i64 {
    optional_var(env, name)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default_value)
}

fn float_var(env: &Env, name: &str, default_value: f64) -> f64 {
    optional_var(env, name)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default_value)
}

#[cfg(test)]
mod tests {
    use super::{validate_credit_backend, validate_lane, CreditBackend};

    #[test]
    fn development_lane_allows_bearer_only_with_flag_and_secret() {
        assert_eq!(
            validate_lane("development", "development", true, true),
            Ok(true)
        );
        assert_eq!(
            validate_lane("development", "development", true, false),
            Ok(false)
        );
        assert_eq!(
            validate_lane("development", "development", false, true),
            Ok(false)
        );
        assert_eq!(
            validate_lane("development", "development", false, false),
            Ok(false)
        );
    }

    #[test]
    fn development_lane_requires_development_app_attest() {
        assert!(validate_lane("development", "production", false, false).is_err());
    }

    #[test]
    fn non_development_lane_fails_closed_when_bearer_gate_present() {
        assert!(validate_lane("production", "production", true, false).is_err());
        assert!(validate_lane("production", "production", false, true).is_err());
        assert!(validate_lane("prod-staging", "production", true, true).is_err());
        assert_eq!(
            validate_lane("production", "production", false, false),
            Ok(false)
        );
    }

    #[test]
    fn credit_backend_defaults_to_dev_only_in_development_lane() {
        assert_eq!(
            validate_credit_backend("development", None),
            Ok(CreditBackend::Dev)
        );
        assert!(validate_credit_backend("prod-staging", None).is_err());
        assert!(validate_credit_backend("production", None).is_err());
    }

    #[test]
    fn dev_credit_backend_is_forbidden_outside_development() {
        assert!(validate_credit_backend("prod-staging", Some("dev")).is_err());
        assert!(validate_credit_backend("production", Some("dev")).is_err());
        assert_eq!(
            validate_credit_backend("development", Some("dev")),
            Ok(CreditBackend::Dev)
        );
    }

    #[test]
    fn purchase_backend_is_valid_in_any_lane_and_unknown_values_fail() {
        assert_eq!(
            validate_credit_backend("prod-staging", Some("purchase")),
            Ok(CreditBackend::Purchase)
        );
        assert_eq!(
            validate_credit_backend("development", Some("purchase")),
            Ok(CreditBackend::Purchase)
        );
        assert!(validate_credit_backend("development", Some("fake")).is_err());
    }
}

use futures_util::StreamExt;
use opencast_app_attest_core::{
    app_attest::{canonical_key_id, challenge_hash, verify_attestation},
    app_attest_envelope::{self, AuthFailure},
    random,
};
use worker::{Env, Headers, Method, Request, RequestInit, Response, Result};

use crate::auth::{bearer_token, token_hash, token_matches, AUTHORIZATION_HEADER};
use crate::challenge_limits::{
    challenge_bucket_start, challenge_source_hash_key_for_environment, keyed_source_token,
    source_challenge_allows_after_increment, APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS,
    CHALLENGE_LIMIT_WINDOW_SECONDS, CHALLENGE_RETENTION_SECONDS,
    CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS, CHALLENGE_TTL_SECONDS,
    MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY,
};
use crate::config::{AppConfig, CreditBackend};
use crate::credit::{DevCreditAuthority, PurchaseAuthority};
use crate::job;
use crate::job_do::CreateMessage;
use crate::origin;
use crate::route::{
    json_response as static_json_response, route_request, Header as StaticHeader, JobAction,
    RouteAction, StaticResponse, JSON_CONTENT_TYPE,
};
use crate::storage;
use crate::types::{
    self, BootstrapRequest, BootstrapResponse, ErrorResponse, JobCreateRequest, SCHEMA_VERSION,
};

pub const TRANSCRIPTION_DB: &str = "TRANSCRIPTION_DB";
const DEV_BEARER_TOKEN: &str = "DEV_BEARER_TOKEN";
const CHALLENGE_SOURCE_HASH_KEY: &str = "CHALLENGE_SOURCE_HASH_KEY";
const DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY: &str =
    "opencast-remote-transcription-development-challenge-source-key";
const PUBLIC_REMOTE_TRANSCRIPTION_ENABLED: &str = "PUBLIC_REMOTE_TRANSCRIPTION_ENABLED";
const REGISTER_PURPOSE: &str = "register";
const MAX_CHALLENGE_REQUEST_BODY_BYTES: usize = 1024;
const MAX_REGISTER_REQUEST_BODY_BYTES: usize = 48 * 1024;
const MAX_NOTIFICATION_BODY_BYTES: usize = 256 * 1024;

pub async fn handle_request(mut req: Request, env: Env) -> Result<Response> {
    let method = req.method();
    let path = req.path();
    let enabled = env_flag(&env, PUBLIC_REMOTE_TRANSCRIPTION_ENABLED, false);

    let action = route_request(method.as_ref(), &path, enabled);
    if let RouteAction::Static(response) = action {
        return static_response(response);
    }

    // Everything past routing requires a coherent lane configuration; a
    // misconfigured lane (e.g. dev bearer outside development) fails closed.
    let config = match AppConfig::from_env(&env) {
        Ok(config) => config,
        Err(error) => return json_error(503, error),
    };
    let db = match required_d1(&env) {
        Ok(db) => db,
        Err(error) => return json_error(503, error),
    };

    match action {
        RouteAction::Static(_) => unreachable!("handled above"),
        RouteAction::AppAttestChallenge => {
            handle_challenge(&mut req, &env, &db, now_seconds()).await
        }
        RouteAction::AppAttestRegister => {
            handle_register(&mut req, &db, &config, now_seconds()).await
        }
        RouteAction::AccountBootstrap => {
            handle_bootstrap(&mut req, &env, &db, &config, &path).await
        }
        RouteAction::CreateJob => handle_create_job(&mut req, &env, &db, &config, &path).await,
        RouteAction::Job { job_id, action } => {
            handle_job_action(&mut req, &env, &db, &config, &path, &job_id, action).await
        }
        RouteAction::PurchaseRedeem => {
            handle_purchase_redeem(&mut req, &env, &db, &config, &path).await
        }
        RouteAction::StoreKitNotifications => {
            handle_storekit_notifications(&mut req, &env, &config).await
        }
    }
}

struct Authenticated {
    install_id: String,
    payload: String,
}

/// Authenticate a request either with the dev bearer (development lane only)
/// or the App Attest envelope with exact method/path/payload binding.
async fn authenticate(
    req: &mut Request,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    path: &str,
) -> Result<std::result::Result<Authenticated, AuthFailure>> {
    let authorization = req.headers().get(AUTHORIZATION_HEADER)?;
    if authorization.is_some() {
        if !config.dev_bearer_enabled {
            return Ok(Err(AuthFailure::new(401, types::ERROR_UNAUTHORIZED)));
        }
        let Some(provided) = bearer_token(authorization.as_deref()) else {
            return Ok(Err(AuthFailure::new(401, types::ERROR_UNAUTHORIZED)));
        };
        let expected = match env.secret(DEV_BEARER_TOKEN) {
            Ok(secret) => secret.to_string(),
            Err(_) => return Ok(Err(AuthFailure::new(401, types::ERROR_UNAUTHORIZED))),
        };
        if !token_matches(provided, &expected) {
            return Ok(Err(AuthFailure::new(401, types::ERROR_UNAUTHORIZED)));
        }
        let payload = req.text().await.unwrap_or_default();
        if payload.len() > types::MAX_PAYLOAD_BYTES {
            return Ok(Err(AuthFailure::new(413, "payload_too_large")));
        }
        let install_id = format!("dev-bearer:{}", &token_hash(provided)[..16]);
        return Ok(Ok(Authenticated {
            install_id,
            payload,
        }));
    }

    Ok(app_attest_envelope::authenticate_envelope(
        req,
        db,
        &config.app_id,
        &config.app_attest_environment,
        now_seconds(),
        "POST",
        path,
        types::MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES,
        types::MAX_PAYLOAD_BYTES,
    )
    .await?
    .map(|authenticated| Authenticated {
        install_id: authenticated.install_id,
        payload: authenticated.payload,
    }))
}

/// The subset of PurchaseWorker's bootstrap response the gateway re-shapes
/// into its own wire contract (additive fields on `BootstrapResponse`).
#[derive(serde::Deserialize)]
struct PurchaseBootstrapUpstream {
    account_id: String,
    app_account_token: String,
    balance: types::Balance,
    catalog: Vec<types::CatalogProduct>,
    catalog_sha256: String,
}

async fn handle_bootstrap(
    req: &mut Request,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    path: &str,
) -> Result<Response> {
    let authenticated = match authenticate(req, env, db, config, path).await? {
        Ok(authenticated) => authenticated,
        Err(failure) => return json_error_code(failure.status, failure.code),
    };
    let request: BootstrapRequest = match serde_json::from_str(&authenticated.payload) {
        Ok(request) => request,
        Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
    };
    if request.schema_version != SCHEMA_VERSION {
        return json_error_code(400, types::ERROR_INVALID_REQUEST);
    }

    match config.credit_backend {
        CreditBackend::Dev => {
            // Development fake: install-keyed accounts, fixed grant.
            let account_id = match resolve_account(db, config, &authenticated.install_id).await? {
                Some(account_id) => account_id,
                None => return json_error_code(403, types::ERROR_BOOTSTRAP_REQUIRED),
            };
            let credit =
                DevCreditAuthority::new(env.d1(TRANSCRIPTION_DB)?, config.dev_credit_grant_seconds);
            let balance = match credit.bootstrap(&account_id, now_seconds()).await {
                Ok(balance) => balance,
                Err(error) => {
                    return json_error(
                        503,
                        ErrorResponse::with_detail(error.code(), "credit bootstrap failed"),
                    )
                }
            };
            json_success(
                200,
                &BootstrapResponse {
                    schema_version: SCHEMA_VERSION,
                    account_id,
                    balance,
                    app_account_token: None,
                    catalog: None,
                    catalog_sha256: None,
                    purchases_enabled: None,
                },
            )
        }
        CreditBackend::Purchase => {
            // Parent-plan identity: the verified AppTransaction JWS rides
            // inside the authenticated envelope and PurchaseWorker verifies
            // it before any account exists.
            let Some(jws) = request
                .app_transaction_jws
                .as_deref()
                .filter(|jws| !jws.is_empty())
            else {
                return json_error_code(400, types::ERROR_INVALID_REQUEST);
            };
            let purchase = match PurchaseAuthority::from_env(env) {
                Ok(purchase) => purchase,
                Err(_) => return json_error_code(503, "worker_binding_missing"),
            };
            let upstream_body = serde_json::json!({
                "schema_version": SCHEMA_VERSION,
                "install_key": authenticated.install_id,
                "app_transaction_jws": jws,
            });
            let mut upstream = purchase
                .call_raw("/internal/v1/bootstrap", upstream_body.to_string())
                .await?;
            if !(200..300).contains(&upstream.status_code()) {
                return mirror_json_response(&mut upstream).await;
            }
            let parsed: PurchaseBootstrapUpstream = match upstream.json().await {
                Ok(parsed) => parsed,
                Err(_) => {
                    return json_error_code(503, types::ERROR_INTERNAL);
                }
            };
            storage::link_install_account(
                db,
                &authenticated.install_id,
                &parsed.account_id,
                now_seconds(),
            )
            .await?;
            json_success(
                200,
                &BootstrapResponse {
                    schema_version: SCHEMA_VERSION,
                    account_id: parsed.account_id,
                    balance: parsed.balance,
                    app_account_token: Some(parsed.app_account_token),
                    catalog: Some(parsed.catalog),
                    catalog_sha256: Some(parsed.catalog_sha256),
                    purchases_enabled: Some(config.purchases_enabled),
                },
            )
        }
    }
}

/// Redeem a StoreKit transaction JWS for credits (App Attest / dev bearer
/// authenticated; purchase-backend lanes only; behind the kill switch).
async fn handle_purchase_redeem(
    req: &mut Request,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    path: &str,
) -> Result<Response> {
    if config.credit_backend != CreditBackend::Purchase {
        return json_error_code(503, types::ERROR_FEATURE_DISABLED);
    }
    if !config.purchases_enabled {
        // Kill switch (decision 12): store surfaces disappear; balances,
        // jobs, and notification processing stay untouched.
        return json_error_code(503, types::ERROR_PURCHASES_DISABLED);
    }
    let authenticated = match authenticate(req, env, db, config, path).await? {
        Ok(authenticated) => authenticated,
        Err(failure) => return json_error_code(failure.status, failure.code),
    };
    let request: types::RedeemRequest = match serde_json::from_str(&authenticated.payload) {
        Ok(request) => request,
        Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
    };
    if request.schema_version != SCHEMA_VERSION || request.transaction_jws.is_empty() {
        return json_error_code(400, types::ERROR_INVALID_REQUEST);
    }
    let Some(account_id) = resolve_account(db, config, &authenticated.install_id).await? else {
        return json_error_code(403, types::ERROR_BOOTSTRAP_REQUIRED);
    };
    let purchase = match PurchaseAuthority::from_env(env) {
        Ok(purchase) => purchase,
        Err(_) => return json_error_code(503, "worker_binding_missing"),
    };
    let upstream_body = serde_json::json!({
        "schema_version": SCHEMA_VERSION,
        "account_id": account_id,
        "transaction_jws": request.transaction_jws,
    });
    let mut upstream = purchase
        .call_raw("/internal/v1/redeem", upstream_body.to_string())
        .await?;
    mirror_json_response(&mut upstream).await
}

/// App Store Server Notifications V2: forward the raw signed body to
/// PurchaseWorker, which verifies the payload before reading any field.
/// Never authenticated with App Attest, never behind the purchase kill
/// switch, and fails closed in lanes without a purchase backend.
async fn handle_storekit_notifications(
    req: &mut Request,
    env: &Env,
    config: &AppConfig,
) -> Result<Response> {
    if config.credit_backend != CreditBackend::Purchase {
        return json_error_code(503, types::ERROR_FEATURE_DISABLED);
    }
    let raw = match read_limited_text(req, MAX_NOTIFICATION_BODY_BYTES).await? {
        Ok(raw) => raw,
        Err(response) => return Ok(response),
    };
    if raw.is_empty() {
        return json_error_code(400, types::ERROR_INVALID_REQUEST);
    }
    let purchase = match PurchaseAuthority::from_env(env) {
        Ok(purchase) => purchase,
        Err(_) => return json_error_code(503, "worker_binding_missing"),
    };
    let mut upstream = purchase.call_raw("/internal/v1/notifications", raw).await?;
    mirror_json_response(&mut upstream).await
}

async fn handle_create_job(
    req: &mut Request,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    path: &str,
) -> Result<Response> {
    let authenticated = match authenticate(req, env, db, config, path).await? {
        Ok(authenticated) => authenticated,
        Err(failure) => return json_error_code(failure.status, failure.code),
    };
    let request: JobCreateRequest = match serde_json::from_str(&authenticated.payload) {
        Ok(request) => request,
        Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
    };
    if request.schema_version != SCHEMA_VERSION
        || request.client_request_id.is_empty()
        || request.client_request_id.len() > 64
        || request.episode_id.is_empty()
        || request.episode_id.len() > 128
    {
        return json_error_code(400, types::ERROR_INVALID_REQUEST);
    }
    if let Some(duration) = request.declared_duration_seconds {
        if !duration.is_finite()
            || duration <= 0.0
            || duration > config.max_canonical_duration_seconds
        {
            return json_error_code(400, types::ERROR_DURATION_TOO_LONG);
        }
    }
    // Chained ad detection requires the podcast identity it analyzes under;
    // the titles are optional prompt context with bounded length.
    if request.ad_analysis_requested
        && !request
            .podcast_id
            .as_deref()
            .is_some_and(|id| !id.is_empty() && id.len() <= 256)
    {
        return json_error_code(400, types::ERROR_INVALID_REQUEST);
    }
    if request
        .episode_title
        .as_deref()
        .is_some_and(|title| title.len() > 512)
        || request
            .podcast_title
            .as_deref()
            .is_some_and(|title| title.len() > 512)
    {
        return json_error_code(400, types::ERROR_INVALID_REQUEST);
    }
    // Pass 2 decision 1: a policy-unsafe URL (http, userinfo, IP-literal,
    // unusual port, forbidden host) is no longer a create-time failure — the
    // server just never fetches it and the job goes straight to the
    // exact-device upload path. Only an unparseable URL still rejects.
    let origin_unsafe = match origin::validate_origin_url(&request.enclosure_url) {
        Ok(_) => false,
        Err(origin::OriginUrlError::Invalid) => {
            return json_error_code(400, types::ERROR_INVALID_REQUEST)
        }
        Err(_) => true,
    };

    let Some(account_id) = resolve_account(db, config, &authenticated.install_id).await? else {
        return json_error_code(403, types::ERROR_BOOTSTRAP_REQUIRED);
    };

    // Bound active jobs per account before creating a new mapping; a
    // duplicate clientRequestID still attaches below.
    let candidate_job_id = format!(
        "job-{}",
        random::random_urlsafe_token(16)
            .map_err(|error| worker::Error::RustError(error.to_string()))?
    );
    let existing_active = storage::active_job_count(db, &account_id).await?;
    let canonical_job_id = storage::insert_job_mapping(
        db,
        &candidate_job_id,
        &account_id,
        &request.client_request_id,
        &request.episode_id,
        job::STATE_CREATED,
        now_seconds(),
    )
    .await?;
    let attached_existing = canonical_job_id != candidate_job_id;
    if !attached_existing && existing_active >= config.max_active_jobs_per_account {
        // Roll back the mapping we just inserted; the account is at capacity.
        db.prepare("DELETE FROM jobs WHERE job_id = ?1")
            .bind_refs(&[worker::D1Type::Text(&canonical_job_id)])?
            .run()
            .await?;
        return json_error_code(429, types::ERROR_RATE_LIMITED);
    }

    let namespace = env.durable_object(job::JOB_BINDING)?;
    let stub = namespace.get_by_name(&canonical_job_id)?;
    let message = CreateMessage {
        job_id: canonical_job_id.clone(),
        account_id,
        episode_id: request.episode_id.clone(),
        language_code: request.language_code.clone(),
        declared_duration_seconds: request.declared_duration_seconds,
        // An unsafe URL never reaches the DO — nothing may fetch or store it.
        enclosure_url: if origin_unsafe {
            String::new()
        } else {
            request.enclosure_url.clone()
        },
        device_identity: request.source_identity.clone(),
        origin_unsafe,
        ad_analysis_requested: request.ad_analysis_requested,
        podcast_id: request.podcast_id.clone(),
        episode_title: request.episode_title.clone(),
        podcast_title: request.podcast_title.clone(),
    };
    let internal = internal_post(
        "https://transcription-job.opencast.internal/create",
        serde_json::to_string(&message)?,
    )?;
    stub.fetch_with_request(internal).await
}

async fn handle_job_action(
    req: &mut Request,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    path: &str,
    job_id: &str,
    action: JobAction,
) -> Result<Response> {
    let authenticated = match authenticate(req, env, db, config, path).await? {
        Ok(authenticated) => authenticated,
        Err(failure) => return json_error_code(failure.status, failure.code),
    };
    // Ownership check on every dynamic job route.
    let Some(index_row) = storage::job_index(db, job_id).await? else {
        return json_error_code(404, types::ERROR_JOB_NOT_FOUND);
    };
    let Some(account_id) = resolve_account(db, config, &authenticated.install_id).await? else {
        return json_error_code(403, types::ERROR_BOOTSTRAP_REQUIRED);
    };
    if index_row.account_id != account_id {
        return json_error_code(403, types::ERROR_ACCOUNT_MISMATCH);
    }

    let internal_path = match action {
        JobAction::Source => "/source",
        JobAction::Poll => "/poll",
        JobAction::Result => "/result",
        JobAction::Ack => "/ack",
        JobAction::Cancel => "/cancel",
        JobAction::UploadStart => "/upload/start",
        JobAction::UploadParts => "/upload/parts",
        JobAction::UploadComplete => "/upload/complete",
    };
    // Validate payload schema versions before forwarding.
    let forwarded_body = match action {
        JobAction::Source => {
            let request: types::SourceReportRequest =
                match serde_json::from_str(&authenticated.payload) {
                    Ok(request) => request,
                    Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
                };
            if request.schema_version != SCHEMA_VERSION {
                return json_error_code(400, types::ERROR_INVALID_REQUEST);
            }
            serde_json::json!({ "source_identity": request.source_identity }).to_string()
        }
        JobAction::Poll => {
            if !authenticated.payload.is_empty() {
                let request: types::PollRequest = match serde_json::from_str(&authenticated.payload)
                {
                    Ok(request) => request,
                    Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
                };
                if request.schema_version != SCHEMA_VERSION {
                    return json_error_code(400, types::ERROR_INVALID_REQUEST);
                }
            }
            "{}".to_string()
        }
        JobAction::Ack => {
            let request: types::AckRequest = match serde_json::from_str(&authenticated.payload) {
                Ok(request) => request,
                Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
            };
            if request.schema_version != SCHEMA_VERSION {
                return json_error_code(400, types::ERROR_INVALID_REQUEST);
            }
            serde_json::json!({
                "normalized_transcript_sha256": request.normalized_transcript_sha256,
            })
            .to_string()
        }
        JobAction::UploadStart => {
            let request: types::UploadStartRequest =
                match serde_json::from_str(&authenticated.payload) {
                    Ok(request) => request,
                    Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
                };
            if request.schema_version != SCHEMA_VERSION {
                return json_error_code(400, types::ERROR_INVALID_REQUEST);
            }
            serde_json::json!({ "for_background": request.for_background }).to_string()
        }
        JobAction::UploadParts => {
            let request: types::UploadPartsRequest =
                match serde_json::from_str(&authenticated.payload) {
                    Ok(request) => request,
                    Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
                };
            if request.schema_version != SCHEMA_VERSION
                || request.part_numbers.is_empty()
                || request.part_numbers.len() > job::UPLOAD_MAX_PARTS_PER_BATCH
                || request.part_numbers.iter().any(|number| *number == 0)
            {
                return json_error_code(400, types::ERROR_INVALID_REQUEST);
            }
            serde_json::json!({
                "part_numbers": request.part_numbers,
                "for_background": request.for_background,
            })
            .to_string()
        }
        JobAction::UploadComplete => {
            let request: types::UploadCompleteRequest =
                match serde_json::from_str(&authenticated.payload) {
                    Ok(request) => request,
                    Err(_) => return json_error_code(400, types::ERROR_INVALID_REQUEST),
                };
            if request.schema_version != SCHEMA_VERSION
                || request.parts.is_empty()
                || request.parts.len() > job::UPLOAD_MAX_PART_COUNT as usize
                || request
                    .parts
                    .iter()
                    .any(|part| part.part_number == 0 || part.etag.is_empty())
            {
                return json_error_code(400, types::ERROR_INVALID_REQUEST);
            }
            serde_json::json!({ "parts": request.parts }).to_string()
        }
        JobAction::Result | JobAction::Cancel => "{}".to_string(),
    };

    let namespace = env.durable_object(job::JOB_BINDING)?;
    let stub = namespace.get_by_name(job_id)?;
    let internal = internal_post(
        &format!("https://transcription-job.opencast.internal{internal_path}"),
        forwarded_body,
    )?;
    stub.fetch_with_request(internal).await
}

/// Resolve the account behind an authenticated install. The dev backend
/// auto-creates install-keyed fake accounts (pass 0); the purchase backend
/// only reads links established by a verified bootstrap — `None` means the
/// caller must bootstrap first.
async fn resolve_account(
    db: &worker::D1Database,
    config: &AppConfig,
    install_id: &str,
) -> Result<Option<String>> {
    if config.credit_backend == CreditBackend::Purchase {
        return storage::purchase_account_for_install(db, install_id).await;
    }
    if let Some(existing) = storage::account_for_install(db, install_id).await? {
        return Ok(Some(existing));
    }
    let candidate = format!(
        "acct-{}",
        random::random_urlsafe_token(12)
            .map_err(|error| worker::Error::RustError(error.to_string()))?
    );
    storage::ensure_account(db, install_id, &candidate, now_seconds())
        .await
        .map(Some)
}

// --- App Attest challenge/register (mirrors AdAnalysisWorker) ---

#[derive(serde::Deserialize)]
struct ChallengeRequest {
    install_id: String,
    purpose: String,
}

#[derive(serde::Serialize)]
struct ChallengeResponse {
    challenge_id: String,
    challenge: String,
}

#[derive(serde::Deserialize)]
struct RegisterRequest {
    install_id: String,
    key_id: String,
    challenge_id: String,
    challenge: String,
    attestation_object: String,
}

async fn handle_challenge(
    req: &mut Request,
    env: &Env,
    db: &worker::D1Database,
    now: i64,
) -> Result<Response> {
    let body =
        match read_limited_json::<ChallengeRequest>(req, MAX_CHALLENGE_REQUEST_BODY_BYTES).await? {
            Ok(body) => body,
            Err(response) => return Ok(response),
        };

    if body.install_id.is_empty() || body.purpose != REGISTER_PURPOSE {
        return json_error_code(400, "invalid_challenge_request");
    }

    storage::prune_challenges_before(db, now.saturating_sub(CHALLENGE_RETENTION_SECONDS))
        .await
        .ok();
    storage::prune_challenge_source_buckets_before(
        db,
        now.saturating_sub(CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS),
    )
    .await
    .ok();

    let challenge_window_start = now.saturating_sub(CHALLENGE_LIMIT_WINDOW_SECONDS);
    let source_token = match challenge_source_token(req.headers(), env) {
        Ok(Some(source_token)) => source_token,
        Ok(None) => return json_error_code(400, "missing_challenge_source"),
        Err(_) => return json_error_code(500, "challenge_source_unavailable"),
    };
    let source_challenge_count = storage::increment_challenge_source_bucket(
        db,
        &source_token,
        challenge_bucket_start(now),
        now,
    )
    .await?;
    if !source_challenge_allows_after_increment(source_challenge_count) {
        return json_error_code(429, "challenge_rate_limited");
    }

    let challenge_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    let challenge = random::random_urlsafe_token(32)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    let Some(expires_at) = now.checked_add(CHALLENGE_TTL_SECONDS) else {
        return json_error_code(500, "timestamp_overflow");
    };
    // Per-install and global hourly caps are predicates of this single
    // atomic statement — concurrent requests cannot overshoot them.
    let admitted = storage::insert_challenge_within_limits(
        db,
        &challenge_id,
        &challenge,
        &body.purpose,
        &body.install_id,
        now,
        expires_at,
        challenge_window_start,
    )
    .await?;
    if !admitted {
        return json_error_code(429, "challenge_rate_limited");
    }

    json_success(
        200,
        &ChallengeResponse {
            challenge_id,
            challenge,
        },
    )
}

async fn handle_register(
    req: &mut Request,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<Response> {
    let body =
        match read_limited_json::<RegisterRequest>(req, MAX_REGISTER_REQUEST_BODY_BYTES).await? {
            Ok(body) => body,
            Err(response) => return Ok(response),
        };

    if body.install_id.is_empty()
        || body.key_id.is_empty()
        || body.challenge_id.is_empty()
        || body.challenge.is_empty()
        || body.attestation_object.is_empty()
    {
        return json_error_code(400, "invalid_register_request");
    }
    let key_id = match canonical_key_id(&body.key_id) {
        Ok(key_id) => key_id,
        Err(error) => return json_error_code(400, error.code()),
    };

    let key_count = storage::app_attest_key_count_since(
        db,
        &body.install_id,
        now.saturating_sub(APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS),
    )
    .await?;
    if key_count >= MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY
        && storage::key(db, &body.install_id, &key_id).await?.is_none()
    {
        return json_error_code(429, "app_attest_registration_rate_limited");
    }

    let Some(challenge) = storage::challenge(db, &body.challenge_id).await? else {
        return json_error_code(401, "invalid_challenge");
    };

    if challenge.install_id != body.install_id
        || challenge.purpose != REGISTER_PURPOSE
        || challenge.consumed_at.is_some()
        || challenge.expires_at < now
        || challenge.challenge_hash != challenge_hash(&body.challenge)
    {
        return json_error_code(401, "invalid_challenge");
    }

    if !storage::mark_challenge_consumed(db, &body.challenge_id, now).await? {
        return json_error_code(401, "invalid_challenge");
    }

    let verified = match verify_attestation(
        &body.attestation_object,
        &body.challenge,
        &config.app_id,
        &key_id,
        &config.app_attest_environment,
        now,
    ) {
        Ok(verified) => verified,
        Err(error) => return json_error_code(401, error.code()),
    };

    storage::upsert_key(
        db,
        &body.install_id,
        &key_id,
        &verified.public_key,
        &config.app_id,
        &config.app_attest_environment,
        now,
    )
    .await?;

    json_success(200, &serde_json::json!({ "message": "registered" }))
}

// --- Shared helpers ---

fn required_d1(env: &Env) -> std::result::Result<worker::D1Database, ErrorResponse> {
    env.d1(TRANSCRIPTION_DB)
        .map_err(|_| ErrorResponse::with_detail("worker_binding_missing", TRANSCRIPTION_DB))
}

async fn read_limited_json<T: for<'de> serde::Deserialize<'de>>(
    req: &mut Request,
    max_bytes: usize,
) -> Result<std::result::Result<T, Response>> {
    if request_content_length_exceeds(req.headers(), max_bytes)? {
        return Ok(Err(json_error_code(413, "payload_too_large")?));
    }

    let mut stream = req.stream()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len().saturating_add(chunk.len()) > max_bytes {
            return Ok(Err(json_error_code(413, "payload_too_large")?));
        }
        bytes.extend_from_slice(&chunk);
    }

    match serde_json::from_slice(&bytes) {
        Ok(body) => Ok(Ok(body)),
        Err(_) => Ok(Err(json_error_code(400, "invalid_json")?)),
    }
}

/// Read a raw request body under a byte cap (no JSON parse — the body is
/// forwarded verbatim and verified downstream).
async fn read_limited_text(
    req: &mut Request,
    max_bytes: usize,
) -> Result<std::result::Result<String, Response>> {
    if request_content_length_exceeds(req.headers(), max_bytes)? {
        return Ok(Err(json_error_code(413, "payload_too_large")?));
    }
    let mut stream = req.stream()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len().saturating_add(chunk.len()) > max_bytes {
            return Ok(Err(json_error_code(413, "payload_too_large")?));
        }
        bytes.extend_from_slice(&chunk);
    }
    match String::from_utf8(bytes) {
        Ok(text) => Ok(Ok(text)),
        Err(_) => Ok(Err(json_error_code(400, types::ERROR_INVALID_REQUEST)?)),
    }
}

/// Mirror a PurchaseWorker response (status + JSON body) through the gateway
/// so stable machine codes pass to the caller unchanged.
async fn mirror_json_response(upstream: &mut Response) -> Result<Response> {
    let status = upstream.status_code();
    let body = upstream.text().await.unwrap_or_default();
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    Ok(Response::builder()
        .with_status(status)
        .with_headers(headers)
        .fixed(body.into_bytes()))
}

fn request_content_length_exceeds(headers: &Headers, max_bytes: usize) -> Result<bool> {
    Ok(headers
        .get("content-length")?
        .and_then(|value| value.trim().parse::<usize>().ok())
        .map(|length| length > max_bytes)
        .unwrap_or(false))
}

fn challenge_source_token(headers: &Headers, env: &Env) -> Result<Option<String>> {
    let Some(signal) = challenge_source_signal(headers)? else {
        return Ok(None);
    };
    let secret = env
        .secret(CHALLENGE_SOURCE_HASH_KEY)
        .ok()
        .map(|secret| secret.to_string());
    let environment = env
        .var("APP_ATTEST_ENVIRONMENT")
        .map(|value| value.to_string())
        .unwrap_or_default();
    let Some(key) = challenge_source_hash_key_for_environment(
        secret.as_deref(),
        &environment,
        DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY,
    ) else {
        return Err(worker::Error::RustError(
            "CHALLENGE_SOURCE_HASH_KEY is required".to_string(),
        ));
    };
    Ok(Some(keyed_source_token(&key, &signal)))
}

fn challenge_source_signal(headers: &Headers) -> Result<Option<String>> {
    for name in ["cf-connecting-ip", "true-client-ip"] {
        if let Some(value) = headers.get(name)? {
            let value = value.trim();
            if !value.is_empty() {
                return Ok(Some(value.to_string()));
            }
        }
    }
    Ok(None)
}

fn internal_post(url: &str, body: String) -> Result<Request> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(body.into()));
    Request::new_with_init(url, &init)
}

fn env_flag(env: &Env, name: &str, default_value: bool) -> bool {
    env.var(name)
        .ok()
        .map(|value| value.to_string() == "true")
        .unwrap_or(default_value)
}

fn now_seconds() -> i64 {
    (worker::Date::now().as_millis() / 1_000)
        .try_into()
        .unwrap_or(i64::MAX)
}

fn json_error_code(status: u16, code: &str) -> Result<Response> {
    json_error(status, ErrorResponse::new(code))
}

fn json_error(status: u16, body: ErrorResponse) -> Result<Response> {
    static_response(static_json_response(status, body))
}

fn json_success(status: u16, body: &impl serde::Serialize) -> Result<Response> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    Ok(Response::builder()
        .with_status(status)
        .with_headers(headers)
        .fixed(serde_json::to_vec(body)?))
}

fn static_response(response: StaticResponse) -> Result<Response> {
    let headers = Headers::new();
    for StaticHeader { name, value } in response.headers {
        headers.set(name, &value)?;
    }
    Ok(Response::builder()
        .with_status(response.status)
        .with_headers(headers)
        .fixed(response.body.into_bytes()))
}

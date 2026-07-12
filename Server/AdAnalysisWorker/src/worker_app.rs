use std::time::Duration;

use futures_util::StreamExt;
use opencast_app_attest_core::{
    app_attest::{
        canonical_key_id, challenge_hash, request_client_data_hash, verify_assertion,
        verify_attestation,
    },
    random,
};

use crate::auth::{bearer_token, token_hash, token_matches, AUTHORIZATION_HEADER};
use crate::challenge_limits::{
    challenge_bucket_start, challenge_source_hash_key_for_environment,
    global_challenge_allows_insert, install_challenge_allows_insert,
    source_challenge_allows_after_increment, APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS,
    CHALLENGE_LIMIT_WINDOW_SECONDS, CHALLENGE_RETENTION_SECONDS,
    CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS, CHALLENGE_TTL_SECONDS,
    MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY,
};
use crate::gemini::{parse_error_envelope, parse_generate_content_response};
use crate::prompt::{gemini_generate_content_url, gemini_request_payload};
use crate::retry::{classify_http_status, RetryDecision};
use crate::route::{
    json_response as static_json_response, route_request, Header as StaticHeader, RouteAction,
    StaticResponse, ANALYZE_TRANSCRIPT_PATH, JSON_CONTENT_TYPE,
};
use crate::storage;
use crate::types::{
    resolve_gemini_model, AdAnalysisResponse, ErrorResponse, GEMINI_MODEL_ENV_VAR,
    MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES, MAX_BODY_BYTES, POLICY_NAME, SCHEMA_VERSION,
};
use crate::usage::{
    global_usage_object_name, usage_object_name, UsageAdmitRequest, UsageLimitProfile,
    USAGE_LIMITER_BINDING,
};
use crate::validation::{
    combine_warnings, decode_and_validate_request, validate_content_length, validate_model_output,
    DailyUsage, ValidatedRequest,
};
use crate::windowing::analysis_windows;
use sha2::{Digest, Sha256};
use worker::{
    console_error, durable_object, wasm_bindgen, Date, Delay, DurableObject, Env, Fetch, Headers,
    Method, Request, RequestInit, Response, Result, SqlStorage, SqlStorageValue, State,
};

const AD_ANALYSIS_DB: &str = "AD_ANALYSIS_DB";
const GEMINI_API_KEY: &str = "GEMINI_API_KEY";
const AD_ANALYSIS_CLIENT_TOKEN: &str = "AD_ANALYSIS_CLIENT_TOKEN";
const PUBLIC_AD_ANALYSIS_ENABLED: &str = "PUBLIC_AD_ANALYSIS_ENABLED";
const APPLE_TEAM_ID: &str = "APPLE_TEAM_ID";
const APPLE_BUNDLE_ID: &str = "APPLE_BUNDLE_ID";
const APP_ATTEST_ENVIRONMENT: &str = "APP_ATTEST_ENVIRONMENT";
const CHALLENGE_SOURCE_HASH_KEY: &str = "CHALLENGE_SOURCE_HASH_KEY";
const REGISTER_PURPOSE: &str = "register";
const MAX_CHALLENGE_REQUEST_BODY_BYTES: usize = 1024;
const MAX_REGISTER_REQUEST_BODY_BYTES: usize = 48 * 1024;
const MAX_GEMINI_ATTEMPTS: usize = 5;

pub async fn handle_request(mut req: Request, env: Env) -> Result<Response> {
    let method = req.method();
    let path = req.path();
    let enabled = env_flag(&env, PUBLIC_AD_ANALYSIS_ENABLED, false);

    match route_request(method.as_ref(), &path, enabled) {
        RouteAction::Static(response) => static_response(response),
        RouteAction::AppAttestChallenge => {
            let db = match required_d1(&env, AD_ANALYSIS_DB) {
                Ok(db) => db,
                Err(error) => return json_error(503, error),
            };
            handle_challenge(&mut req, &env, &db, now_seconds()).await
        }
        RouteAction::AppAttestRegister => {
            let db = match required_d1(&env, AD_ANALYSIS_DB) {
                Ok(db) => db,
                Err(error) => return json_error(503, error),
            };
            let config = match AppConfig::from_env(&env) {
                Ok(config) => config,
                Err(error) => return json_error(503, error),
            };
            handle_register(&mut req, &db, &config, now_seconds()).await
        }
        RouteAction::AnalyzeTranscript => analyze_transcript(&mut req, &env).await,
    }
}

#[derive(Clone)]
struct AppConfig {
    app_id: String,
    app_attest_environment: String,
}

impl AppConfig {
    fn from_env(env: &Env) -> std::result::Result<Self, ErrorResponse> {
        let team_id = required_var(env, APPLE_TEAM_ID)?;
        let bundle_id = required_var(env, APPLE_BUNDLE_ID)?;
        let environment = required_var(env, APP_ATTEST_ENVIRONMENT)?;
        if !matches!(environment.as_str(), "development" | "production") {
            return Err(ErrorResponse::with_detail(
                "worker_env_invalid",
                "APP_ATTEST_ENVIRONMENT must be development or production",
            ));
        }

        Ok(Self {
            app_id: format!("{team_id}.{bundle_id}"),
            app_attest_environment: environment,
        })
    }
}

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

#[derive(serde::Deserialize)]
struct AuthenticatedEnvelope {
    install_id: Option<String>,
    key_id: Option<String>,
    payload: Option<String>,
    assertion: Option<String>,
}

struct AuthenticatedPayload {
    key_id: String,
    payload: String,
}

struct AuthFailure {
    status: u16,
    code: &'static str,
}

impl AuthFailure {
    fn new(status: u16, code: &'static str) -> Self {
        Self { status, code }
    }
}

fn required_var(env: &Env, name: &'static str) -> std::result::Result<String, ErrorResponse> {
    env.var(name)
        .map(|value| value.to_string())
        .map_err(|_| ErrorResponse::with_detail("worker_env_missing", name.to_string()))
}

fn required_secret(env: &Env, name: &'static str) -> std::result::Result<String, ErrorResponse> {
    env.secret(name)
        .map(|secret| secret.to_string())
        .map_err(|_| ErrorResponse::with_detail("worker_secret_missing", name.to_string()))
}

fn required_d1(
    env: &Env,
    name: &'static str,
) -> std::result::Result<worker::D1Database, ErrorResponse> {
    env.d1(name)
        .map_err(|_| ErrorResponse::with_detail("worker_binding_missing", name.to_string()))
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

    let global_challenge_count =
        storage::global_challenge_count_since(db, challenge_window_start).await?;
    if !global_challenge_allows_insert(global_challenge_count) {
        return json_error_code(429, "challenge_rate_limited");
    }

    let challenge_count =
        storage::challenge_count_since(db, &body.install_id, challenge_window_start).await?;
    if !install_challenge_allows_insert(challenge_count) {
        return json_error_code(429, "challenge_rate_limited");
    }

    let challenge_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    let challenge = random::random_urlsafe_token(32)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    let Some(expires_at) = now.checked_add(CHALLENGE_TTL_SECONDS) else {
        return json_error_code(500, "timestamp_overflow");
    };
    storage::insert_challenge(
        db,
        &challenge_id,
        &challenge,
        &body.purpose,
        &body.install_id,
        now,
        expires_at,
    )
    .await?;

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

async fn analyze_transcript(req: &mut Request, env: &Env) -> Result<Response> {
    let authorization = req.headers().get(AUTHORIZATION_HEADER)?;
    if authorization.is_some() {
        return analyze_transcript_with_bearer(req, env, authorization.as_deref()).await;
    }
    analyze_transcript_with_envelope(req, env).await
}

async fn analyze_transcript_with_bearer(
    req: &mut Request,
    env: &Env,
    authorization: Option<&str>,
) -> Result<Response> {
    let Some(provided_token) = bearer_token(authorization) else {
        return json_error_code(401, "unauthorized");
    };
    let client_token = match required_secret(env, AD_ANALYSIS_CLIENT_TOKEN) {
        Ok(client_token) => client_token,
        Err(error) => return json_error(503, error),
    };
    if !token_matches(provided_token, &client_token) {
        return json_error_code(401, "unauthorized");
    }

    if let Err(error) = validate_content_length(req.headers().get("content-length")?.as_deref()) {
        return json_error(error.http_status(), ErrorResponse::new(error.code()));
    }

    let body = req.bytes().await?;
    let validated = match decode_and_validate_request(&body) {
        Ok(validated) => validated,
        Err(error) => return json_error(error.http_status(), ErrorResponse::new(error.code())),
    };

    analyze_validated_request(
        env,
        validated,
        &usage_object_name(&token_hash(provided_token), day_index()),
        UsageLimitProfile::Bearer,
    )
    .await
}

async fn analyze_transcript_with_envelope(req: &mut Request, env: &Env) -> Result<Response> {
    let db = match required_d1(env, AD_ANALYSIS_DB) {
        Ok(db) => db,
        Err(error) => return json_error(503, error),
    };
    let config = match AppConfig::from_env(env) {
        Ok(config) => config,
        Err(error) => return json_error(503, error),
    };
    let authenticated = match authenticate_envelope(
        req,
        &db,
        &config,
        now_seconds(),
        "POST",
        ANALYZE_TRANSCRIPT_PATH,
        MAX_BODY_BYTES,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(failure) => return json_error_code(failure.status, failure.code),
    };
    let validated = match decode_and_validate_request(authenticated.payload.as_bytes()) {
        Ok(validated) => validated,
        Err(error) => return json_error(error.http_status(), ErrorResponse::new(error.code())),
    };
    let subject = format!("app-attest-key:{}", token_hash(&authenticated.key_id));
    analyze_validated_request(
        env,
        validated,
        &usage_object_name(&subject, day_index()),
        UsageLimitProfile::AppAttestKey,
    )
    .await
}

async fn analyze_validated_request(
    env: &Env,
    validated: ValidatedRequest,
    usage_object_name: &str,
    usage_profile: UsageLimitProfile,
) -> Result<Response> {
    let gemini_api_key = match required_secret(env, GEMINI_API_KEY) {
        Ok(key) => key,
        Err(error) => return json_error(503, error),
    };

    if let Some(response) = admit_spend_caps(
        env,
        usage_object_name,
        usage_profile,
        day_index(),
        validated.estimate.estimated_input_tokens,
    )
    .await?
    {
        return Ok(response);
    }

    let model = resolve_gemini_model(
        env.var(GEMINI_MODEL_ENV_VAR)
            .ok()
            .map(|value| value.to_string())
            .as_deref(),
    );
    let gemini_url = gemini_generate_content_url(model);

    let mut combined_model_output = crate::validation::ModelOutput::from_spans(Vec::new());
    let mut combined_usage = None;
    let mut gemini_warnings = Vec::new();
    for window in analysis_windows(&validated.request) {
        let payload = gemini_request_payload(&window);
        let response_body =
            match call_gemini_with_retry(&gemini_api_key, &gemini_url, &payload).await {
                Ok(body) => body,
                Err(error) => return json_error(error.status, error.body),
            };

        // Malformed/truncated model output degrades this window to zero spans
        // plus warnings — never a whole-request 502 (step-4 PLAN §A5). One
        // full re-request first: temp-0 truncation is deterministic in
        // content but retries are cheap relative to a parked analysis.
        let mut parsed = parse_generate_content_response(&response_body);
        if parsed.output.is_none() {
            if let Ok(retry_body) =
                call_gemini_with_retry(&gemini_api_key, &gemini_url, &payload).await
            {
                let retried = parse_generate_content_response(&retry_body);
                combined_usage = combine_usage(combined_usage, parsed.usage.take());
                gemini_warnings.append(&mut parsed.warnings);
                parsed = retried;
            }
        }

        combined_usage = combine_usage(combined_usage, parsed.usage);
        gemini_warnings.extend(parsed.warnings);
        match parsed.output {
            Some(mut model_output) => {
                combined_model_output.spans.append(&mut model_output.spans);
                combined_model_output.malformed_span_count = combined_model_output
                    .malformed_span_count
                    .saturating_add(model_output.malformed_span_count);
            }
            None => {
                let code = parsed
                    .failure
                    .map(|failure| failure.code())
                    .unwrap_or("malformed_model_json");
                gemini_warnings.push(format!("{code}_skipped"));
            }
        }
    }

    let (spans, validation_warnings) =
        validate_model_output(&validated.request, combined_model_output);
    let response = AdAnalysisResponse {
        schema_version: SCHEMA_VERSION,
        request_id: validated.request.request_id,
        model: model.to_string(),
        policy: POLICY_NAME.to_string(),
        spans,
        warnings: combine_warnings(validation_warnings, gemini_warnings),
        usage: combined_usage,
    };
    json_success(200, &response)
}

async fn authenticate_envelope(
    req: &mut Request,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
    method: &str,
    path: &'static str,
    max_payload_bytes: usize,
) -> Result<std::result::Result<AuthenticatedPayload, AuthFailure>> {
    let body = match read_limited_json::<AuthenticatedEnvelope>(
        req,
        MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES,
    )
    .await?
    {
        Ok(body) => body,
        Err(response) => {
            return Ok(Err(AuthFailure::new(
                response.status_code(),
                if response.status_code() == 413 {
                    "payload_too_large"
                } else {
                    "invalid_json"
                },
            )))
        }
    };
    let payload = body.payload.unwrap_or_default();
    if payload.len() > max_payload_bytes {
        return Ok(Err(AuthFailure::new(413, "payload_too_large")));
    }
    let Some(assertion) = body.assertion.as_deref() else {
        return Ok(Err(AuthFailure::new(401, "missing_assertion")));
    };
    let (Some(install_id), Some(raw_key_id)) = (body.install_id.as_deref(), body.key_id.as_deref())
    else {
        return Ok(Err(AuthFailure::new(401, "unknown_key")));
    };
    let key_id = match canonical_key_id(raw_key_id) {
        Ok(key_id) => key_id,
        Err(error) => return Ok(Err(AuthFailure::new(401, error.code()))),
    };

    let Some(key) = storage::key(db, install_id, &key_id).await? else {
        return Ok(Err(AuthFailure::new(401, "unknown_key")));
    };

    if key.app_id != config.app_id {
        return Ok(Err(AuthFailure::new(401, "invalid_app_id")));
    }

    if key.environment != config.app_attest_environment {
        return Ok(Err(AuthFailure::new(401, "invalid_environment")));
    }

    let previous_counter = match u32::try_from(key.sign_counter) {
        Ok(counter) => counter,
        Err(_) => return Ok(Err(AuthFailure::new(401, "invalid_counter"))),
    };
    let client_data_hash = request_client_data_hash(method, path, &payload);

    let verified = match verify_assertion(
        assertion,
        &client_data_hash,
        &config.app_id,
        &key.public_key,
        previous_counter,
    ) {
        Ok(verified) => verified,
        Err(error) => return Ok(Err(AuthFailure::new(401, error.code()))),
    };

    let next_counter = i64::from(verified.sign_counter);
    if !storage::update_key_counter(db, install_id, &key_id, key.sign_counter, next_counter, now)
        .await?
    {
        return Ok(Err(AuthFailure::new(401, "invalid_counter")));
    }

    Ok(Ok(AuthenticatedPayload { key_id, payload }))
}

async fn admit_spend_caps(
    env: &Env,
    usage_object_name: &str,
    usage_profile: UsageLimitProfile,
    day_index: u64,
    estimated_input_tokens: u64,
) -> Result<Option<Response>> {
    if let Some(response) = admit_usage(
        env,
        usage_object_name,
        usage_profile,
        estimated_input_tokens,
    )
    .await?
    {
        return Ok(Some(response));
    }

    admit_usage(
        env,
        &global_usage_object_name(day_index),
        UsageLimitProfile::Global,
        estimated_input_tokens,
    )
    .await
}

async fn admit_usage(
    env: &Env,
    object_name: &str,
    profile: UsageLimitProfile,
    estimated_input_tokens: u64,
) -> Result<Option<Response>> {
    let namespace = env.durable_object(USAGE_LIMITER_BINDING)?;
    let stub = namespace.get_by_name(object_name)?;
    let body = serde_json::to_string(&UsageAdmitRequest {
        estimated_input_tokens,
        profile,
    })?;
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;

    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(body.into()));

    let request = Request::new_with_init("https://usage-limiter.opencast.internal/admit", &init)?;
    let mut response = stub.fetch_with_request(request).await?;
    let status = response.status_code();
    if status == 200 {
        let _: DailyUsage = response.json().await?;
        return Ok(None);
    }

    let error = response
        .json::<ErrorResponse>()
        .await
        .unwrap_or_else(|_| ErrorResponse::new("usage_limiter_error"));
    Ok(Some(json_response(
        if status == 429 { 429 } else { 503 },
        error,
    )?))
}

#[durable_object(fetch)]
pub struct AdAnalysisUsageLimiter {
    sql: SqlStorage,
}

impl DurableObject for AdAnalysisUsageLimiter {
    fn new(state: State, _env: Env) -> Self {
        let sql = state.storage().sql();
        sql.exec(
            "CREATE TABLE IF NOT EXISTS daily_usage (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                request_count INTEGER NOT NULL,
                estimated_input_tokens INTEGER NOT NULL
            );",
            None,
        )
        .expect("create usage limiter table");
        Self { sql }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        if req.method() != Method::Post {
            return json_error(405, ErrorResponse::new("method_not_allowed"));
        }

        let admit_request = match req.json::<UsageAdmitRequest>().await {
            Ok(request) => request,
            Err(_) => return json_error(400, ErrorResponse::new("malformed_json")),
        };
        let current_usage = self.current_usage()?;
        let next_usage = match current_usage.admitting_with_limits(
            admit_request.estimated_input_tokens,
            admit_request.profile.limits(),
        ) {
            Ok(usage) => usage,
            Err(error) => return json_error(429, ErrorResponse::new(error.code())),
        };
        self.write_usage(&next_usage)?;
        json_success(200, &next_usage)
    }
}

impl AdAnalysisUsageLimiter {
    fn current_usage(&self) -> Result<DailyUsage> {
        let rows: Vec<DailyUsageRow> = self
            .sql
            .exec(
                "SELECT request_count, estimated_input_tokens FROM daily_usage WHERE id = 1 LIMIT 1;",
                None,
            )?
            .to_array()?;
        Ok(rows
            .first()
            .map(DailyUsageRow::daily_usage)
            .unwrap_or_default())
    }

    fn write_usage(&self, usage: &DailyUsage) -> Result<()> {
        self.sql.exec(
            "INSERT INTO daily_usage (id, request_count, estimated_input_tokens)
             VALUES (1, ?, ?)
             ON CONFLICT(id) DO UPDATE SET
                request_count = excluded.request_count,
                estimated_input_tokens = excluded.estimated_input_tokens;",
            vec![
                SqlStorageValue::Integer(usage.request_count as i64),
                SqlStorageValue::Integer(usage.estimated_input_tokens as i64),
            ],
        )?;
        Ok(())
    }
}

#[derive(serde::Deserialize)]
struct DailyUsageRow {
    request_count: i64,
    estimated_input_tokens: i64,
}

impl DailyUsageRow {
    fn daily_usage(&self) -> DailyUsage {
        DailyUsage {
            request_count: self.request_count.max(0) as u64,
            estimated_input_tokens: self.estimated_input_tokens.max(0) as u64,
        }
    }
}

struct UpstreamError {
    status: u16,
    body: ErrorResponse,
}

async fn call_gemini_with_retry(
    gemini_api_key: &str,
    gemini_url: &str,
    payload: &serde_json::Value,
) -> std::result::Result<String, UpstreamError> {
    let payload_string = serde_json::to_string(payload).map_err(|error| UpstreamError {
        status: 500,
        body: ErrorResponse::with_detail("gemini_payload_error", error.to_string()),
    })?;
    let mut last_error = UpstreamError {
        status: 502,
        body: ErrorResponse::new("gemini_unavailable"),
    };

    for attempt in 1..=MAX_GEMINI_ATTEMPTS {
        let mut response = match call_gemini_once(gemini_api_key, gemini_url, &payload_string).await
        {
            Ok(response) => response,
            Err(error) => {
                last_error = error;
                if attempt < MAX_GEMINI_ATTEMPTS {
                    Delay::from(Duration::from_secs(backoff_seconds(attempt))).await;
                    continue;
                }
                break;
            }
        };

        let status = response.status_code();
        let retry_after = response.headers().get("retry-after").ok().flatten();
        let text = response.text().await.unwrap_or_default();
        if (200..300).contains(&status) {
            return Ok(text);
        }

        let error_body = parse_error_envelope(&text);
        match classify_http_status(status, retry_after.as_deref(), error_body.as_ref()) {
            RetryDecision::Retry {
                retry_after_seconds,
            } if attempt < MAX_GEMINI_ATTEMPTS => {
                let seconds = retry_after_seconds.unwrap_or_else(|| backoff_seconds(attempt));
                Delay::from(Duration::from_secs(seconds)).await;
                last_error = UpstreamError {
                    status: 503,
                    body: ErrorResponse::new("gemini_retry_exhausted"),
                };
            }
            RetryDecision::HardQuota => {
                return Err(UpstreamError {
                    status: 503,
                    body: ErrorResponse::new("gemini_quota_exhausted"),
                });
            }
            _ => {
                return Err(UpstreamError {
                    status: upstream_status(status),
                    body: ErrorResponse::with_detail(
                        "gemini_http_error",
                        format!("status {status}"),
                    ),
                });
            }
        }
    }

    Err(last_error)
}

async fn call_gemini_once(
    gemini_api_key: &str,
    gemini_url: &str,
    payload_string: &str,
) -> std::result::Result<Response, UpstreamError> {
    let headers = Headers::new();
    headers
        .set("content-type", JSON_CONTENT_TYPE)
        .map_err(worker_error)?;
    headers
        .set("x-goog-api-key", gemini_api_key)
        .map_err(worker_error)?;

    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(payload_string.into()));

    let request = Request::new_with_init(gemini_url, &init).map_err(worker_error)?;
    Fetch::Request(request).send().await.map_err(worker_error)
}

fn worker_error(error: worker::Error) -> UpstreamError {
    console_error!("Worker error: {error:?}");
    UpstreamError {
        status: 502,
        body: ErrorResponse::new("worker_fetch_error"),
    }
}

fn backoff_seconds(attempt: usize) -> u64 {
    (1u64 << attempt.min(4)).min(20)
}

fn upstream_status(status: u16) -> u16 {
    if status == 429 || (500..600).contains(&status) {
        503
    } else {
        502
    }
}

fn combine_usage(
    lhs: Option<crate::types::GeminiUsage>,
    rhs: Option<crate::types::GeminiUsage>,
) -> Option<crate::types::GeminiUsage> {
    match (lhs, rhs) {
        (Some(lhs), Some(rhs)) => Some(crate::types::GeminiUsage {
            prompt_token_count: lhs
                .prompt_token_count
                .saturating_add(rhs.prompt_token_count),
            candidates_token_count: lhs
                .candidates_token_count
                .saturating_add(rhs.candidates_token_count),
            total_token_count: lhs.total_token_count.saturating_add(rhs.total_token_count),
        }),
        (Some(lhs), None) => Some(lhs),
        (None, Some(rhs)) => Some(rhs),
        (None, None) => None,
    }
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

fn request_content_length_exceeds(headers: &Headers, max_bytes: usize) -> Result<bool> {
    Ok(content_length_exceeds(
        headers.get("content-length")?.as_deref(),
        max_bytes,
    ))
}

fn content_length_exceeds(content_length: Option<&str>, max_bytes: usize) -> bool {
    content_length
        .and_then(|value| value.trim().parse::<usize>().ok())
        .map(|length| length > max_bytes)
        .unwrap_or(false)
}

fn challenge_source_token(headers: &Headers, env: &Env) -> Result<Option<String>> {
    let Some(signal) = challenge_source_signal(headers)? else {
        return Ok(None);
    };
    let Some(key) = challenge_source_hash_key(env)? else {
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

fn challenge_source_hash_key(env: &Env) -> Result<Option<String>> {
    if let Ok(secret) = env.secret(CHALLENGE_SOURCE_HASH_KEY) {
        return Ok(Some(secret.to_string()));
    }

    let environment = env
        .var(APP_ATTEST_ENVIRONMENT)
        .map(|value| value.to_string())
        .unwrap_or_default();
    Ok(challenge_source_hash_key_for_environment(
        None,
        &environment,
    ))
}

fn keyed_source_token(key: &str, source_signal: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.as_bytes());
    hasher.update([0]);
    hasher.update(source_signal.as_bytes());
    hex::encode(hasher.finalize())
}

fn env_flag(env: &Env, name: &str, default_value: bool) -> bool {
    env.var(name)
        .ok()
        .map(|value| value.to_string() == "true")
        .unwrap_or(default_value)
}

fn now_seconds() -> i64 {
    (Date::now().as_millis() / 1_000)
        .try_into()
        .unwrap_or(i64::MAX)
}

fn day_index() -> u64 {
    Date::now().as_millis() / 86_400_000
}

fn json_error_code(status: u16, code: &'static str) -> Result<Response> {
    json_error(status, ErrorResponse::new(code))
}

fn json_error(status: u16, body: ErrorResponse) -> Result<Response> {
    static_response(static_json_response(status, body))
}

fn json_response(status: u16, body: ErrorResponse) -> Result<Response> {
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

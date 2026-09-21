use crate::app_attest::{canonical_key_id, challenge_hash, verify_attestation};
use crate::challenge_limits::{
    challenge_bucket_start, challenge_source_hash_key_for_environment, keyed_source_token,
    source_challenge_allows_after_increment, APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS,
    CHALLENGE_LIMIT_WINDOW_SECONDS, CHALLENGE_RETENTION_SECONDS,
    CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS, CHALLENGE_TTL_SECONDS,
    MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY, MAX_CHALLENGES_PER_SOURCE_PER_HOUR,
    MAX_GLOBAL_CHALLENGES_PER_HOUR,
};
use crate::route::{
    content_length_exceeds, diagnostic_endpoint_path, parse_env_flag, public_write_endpoint,
    DEBUG_SEND_TEST_PUSH_PATH, DEVICES_REGISTER_PATH, DEVICES_UNREGISTER_PATH, INSTALL_DELETE_PATH,
    SECURE_HELLO_PATH, SUBSCRIPTIONS_SYNC_PATH,
};
use crate::{
    apns, feed_admission, random, route, storage,
    subscription_admission::{
        admit_pending_enqueue, stale_subscription_urls, subscription_count_error,
        MAX_EXPECTED_PUBLIC_ROLLOUT_INSTALLS_PER_DAY, MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY,
        MAX_SUBSCRIPTIONS_PER_INSTALL,
    },
    subscription_payloads::{AcceptedSubscription, AcceptedSubscriptionHealth},
};
use futures_util::StreamExt;
use opencast_app_attest_core::app_attest_envelope::{self, AuthFailure, AuthenticatedPayload};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use worker::{Env, Headers, Request, Response, Result};

const APP_ATTEST_DB: &str = "APP_ATTEST_DB";
const REGISTER_PURPOSE: &str = "register";
const CHALLENGE_SOURCE_HASH_KEY: &str = "CHALLENGE_SOURCE_HASH_KEY";
const DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY: &str = "opencast-development-challenge-source-key";
const SECURE_ATTEMPT_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const FEED_ATTEMPT_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
// APNs debugging value decays in days; the attempts table exists for
// diagnosis, not audit.
const PUSH_SEND_ATTEMPT_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const DELETED_SUBSCRIPTION_RETENTION_SECONDS: i64 = 90 * 24 * 60 * 60;
// A DoS bound on an authenticated endpoint, not a quota: 96 KiB covers the
// full 200-subscription set at ~490-byte URLs. The sync is a full-set
// declaration (any absent subscription is marked deleted), so client-side
// chunking is never an option — a chunked request would mass-unsubscribe
// everything outside its chunk. Raise this cap instead.
const MAX_SUBSCRIPTION_SYNC_PAYLOAD_BYTES: usize = 96 * 1024;
const MAX_CHALLENGE_REQUEST_BODY_BYTES: usize = 1024;
const MAX_REGISTER_REQUEST_BODY_BYTES: usize = 48 * 1024;
const MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES: usize =
    MAX_SUBSCRIPTION_SYNC_PAYLOAD_BYTES + 16 * 1024;
const MAX_SMALL_AUTHENTICATED_PAYLOAD_BYTES: usize = 4 * 1024;
const MAX_DEVICES_PER_INSTALL: i64 = 5;

const _: () = assert!(
    MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY
        >= MAX_SUBSCRIPTIONS_PER_INSTALL as i64 * MAX_EXPECTED_PUBLIC_ROLLOUT_INSTALLS_PER_DAY
);
const _: () = assert!(MAX_GLOBAL_CHALLENGES_PER_HOUR > MAX_CHALLENGES_PER_SOURCE_PER_HOUR);

#[derive(Clone)]
struct AppConfig {
    app_id: String,
    deletion_hash_key: Option<String>,
    bundle_id: String,
    app_attest_environment: String,
    apns_environment: apns::ApnsEnvironment,
}

impl AppConfig {
    fn deletion_fence(&self, install: &str) -> Result<String> {
        let key = self.deletion_hash_key.as_deref().ok_or_else(|| {
            worker::Error::RustError(
                "CHALLENGE_SOURCE_HASH_KEY required for deletion fencing".into(),
            )
        })?;
        Ok(keyed_source_token(
            key,
            &serde_json::to_string(&["notification-deletion-v1", install])?,
        ))
    }

    fn from_env(env: &Env) -> Result<Self> {
        let team_id = env.var("APPLE_TEAM_ID")?.to_string();
        let bundle_id = env.var("APPLE_BUNDLE_ID")?.to_string();
        let environment = env.var("APP_ATTEST_ENVIRONMENT")?.to_string();
        if !matches!(environment.as_str(), "development" | "production") {
            return Err(worker::Error::RustError(
                "APP_ATTEST_ENVIRONMENT must be development or production".to_string(),
            ));
        }
        let apns_environment = env.var("APNS_ENVIRONMENT")?.to_string();
        let Some(apns_environment) = apns::ApnsEnvironment::parse(&apns_environment) else {
            return Err(worker::Error::RustError(
                "APNS_ENVIRONMENT must be development or production".to_string(),
            ));
        };

        Ok(Self {
            app_id: format!("{team_id}.{bundle_id}"),
            deletion_hash_key: challenge_source_hash_key(env)?,
            bundle_id,
            app_attest_environment: environment,
            apns_environment,
        })
    }
}

#[derive(Deserialize)]
struct ChallengeRequest {
    install_id: String,
    purpose: String,
}

#[derive(Serialize)]
struct ChallengeResponse {
    challenge_id: String,
    challenge: String,
}

#[derive(Deserialize)]
struct RegisterRequest {
    install_id: String,
    key_id: String,
    challenge_id: String,
    challenge: String,
    attestation_object: String,
}

#[derive(Deserialize)]
struct RegisterDevicePayload {
    #[serde(default)]
    capabilities: Vec<String>,
    device_token: String,
    apns_environment: String,
}

#[derive(Deserialize)]
struct UnregisterDevicePayload {
    device_token: Option<String>,
    device_token_hash: Option<String>,
}

#[derive(Deserialize)]
struct DebugSendTestPushPayload {
    title: Option<String>,
    body: Option<String>,
}

#[derive(Deserialize)]
struct SyncSubscriptionsPayload {
    subscriptions: Vec<SyncSubscriptionInput>,
}

#[derive(Deserialize)]
struct SyncSubscriptionInput {
    feed_url: String,
    notifications_enabled: bool,
}

#[derive(Serialize)]
struct SyncSubscriptionsResponse {
    message: &'static str,
    accepted: Vec<AcceptedSubscription>,
    rejected: Vec<RejectedSubscription>,
    pending: Vec<PendingSubscription>,
    registration_ready: bool,
}

#[derive(Serialize)]
struct RejectedSubscription {
    feed_url: String,
    error: &'static str,
}

#[derive(Serialize)]
struct PendingSubscription {
    feed_url: String,
}

struct AdmittedSubscription {
    canonical_url: String,
    source_url: String,
    host: String,
    notifications_enabled: bool,
}

struct ApnsSendResult {
    apns_status: Option<u16>,
    apns_id: Option<String>,
    apns_error: Option<String>,
}

#[derive(Serialize)]
struct TestPushResponse {
    message: &'static str,
    apns_status: Option<u16>,
    apns_id: Option<String>,
    apns_error: Option<String>,
}

pub async fn handle_request(mut req: Request, env: Env) -> Result<Response> {
    let capability = env
        .var("NOTIFICATION_CAPABILITY")
        .map(|v| v.to_string())
        .unwrap_or_default();
    if capability == "feed_control" {
        return crate::feed_control::handle(req, env).await;
    }
    if capability == "feed_observations" {
        return crate::observation::runtime::handle(req, env).await;
    }
    if !capability.is_empty() {
        return crate::delivery::handle(req, env, &capability).await;
    }
    let method = req.method();
    let path = req.path();

    if path == "/health" {
        return route_response(route::handle_request(method.as_ref(), &path));
    }

    let config = AppConfig::from_env(&env)?;
    let db = env.d1(APP_ATTEST_DB)?;
    let now = now_seconds();

    if diagnostic_endpoint_path(&path) && !debug_endpoints_enabled(&env) {
        return json_error(404, "not_found");
    }
    if public_write_endpoint(method.as_ref(), &path) && !public_notifications_enabled(&env) {
        return json_error(503, "public_notifications_disabled");
    }

    match (method.as_ref(), path.as_str()) {
        ("POST", "/v1/app-attest/challenge") => handle_challenge(&mut req, &env, &db, now).await,
        ("POST", "/v1/app-attest/register") => handle_register(&mut req, &db, &config, now).await,
        ("POST", SECURE_HELLO_PATH) => handle_secure_hello(&mut req, &db, &config, now).await,
        ("POST", DEVICES_REGISTER_PATH) => {
            handle_register_device(&mut req, &db, &config, now).await
        }
        ("POST", DEVICES_UNREGISTER_PATH) => {
            handle_unregister_device(&mut req, &db, &config, now).await
        }
        ("POST", INSTALL_DELETE_PATH) => handle_delete_install(&mut req, &db, &config, now).await,
        ("POST", DEBUG_SEND_TEST_PUSH_PATH) => {
            handle_debug_send_test_push(&mut req, &env, &db, &config, now).await
        }
        ("POST", SUBSCRIPTIONS_SYNC_PATH) => {
            handle_sync_subscriptions(&mut req, &db, &config, now).await
        }
        (
            "GET",
            "/v1/app-attest/challenge"
            | "/v1/app-attest/register"
            | SECURE_HELLO_PATH
            | DEVICES_REGISTER_PATH
            | DEVICES_UNREGISTER_PATH
            | INSTALL_DELETE_PATH
            | DEBUG_SEND_TEST_PUSH_PATH
            | SUBSCRIPTIONS_SYNC_PATH,
        ) => json_error(405, "method_not_allowed"),
        _ => json_error(404, "not_found"),
    }
}

pub async fn handle_scheduled(env: Env) -> Result<()> {
    if crate::delivery::reconcile(&env).await.is_err() {
        worker::console_warn!("notification reconciliation failed; continuing maintenance");
    }
    let db = env.d1(APP_ATTEST_DB)?;
    let now = now_seconds();
    if !crate::delivery::db::permitted(&env, &db, "cleanup").await? {
        return Ok(());
    }
    // Authentication and subscription retention also serve the queued engine.
    storage::prune_challenges_before(&db, now.saturating_sub(CHALLENGE_RETENTION_SECONDS))
        .await
        .ok();
    storage::prune_challenge_source_buckets_before(
        &db,
        now.saturating_sub(CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS),
    )
    .await
    .ok();
    // Retention lives on the cron path so a quiet request lane still prunes.
    // The admission/secure prunes also keep their request-time call sites.
    // Best-effort like the challenge prunes above; counts are logged so the
    // post-deploy cron watch can verify the sweeps run and settle.
    let push_attempts_pruned = storage::prune_push_send_attempts_before(
        &db,
        now.saturating_sub(PUSH_SEND_ATTEMPT_RETENTION_SECONDS),
    )
    .await
    .unwrap_or(0);
    let admission_attempts_pruned = storage::prune_feed_admission_attempts_before(
        &db,
        now.saturating_sub(FEED_ATTEMPT_RETENTION_SECONDS),
    )
    .await
    .unwrap_or(0);
    let secure_attempts_pruned = storage::prune_secure_attempts_before(
        &db,
        now.saturating_sub(SECURE_ATTEMPT_RETENTION_SECONDS),
    )
    .await
    .unwrap_or(0);
    let subscriptions_gcd = storage::gc_deleted_subscriptions_before(
        &db,
        now.saturating_sub(DELETED_SUBSCRIPTION_RETENTION_SECONDS),
    )
    .await
    .unwrap_or(0);
    worker::console_log!(
        "scheduled retention: push_attempts={} admission_attempts={} secure_attempts={} deleted_subscriptions={}",
        push_attempts_pruned,
        admission_attempts_pruned,
        secure_attempts_pruned,
        subscriptions_gcd,
    );
    Ok(())
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
        return json_error(400, "invalid_challenge_request");
    }

    let challenge_window_start = now.saturating_sub(CHALLENGE_LIMIT_WINDOW_SECONDS);
    let source_token = match challenge_source_token(req.headers(), env) {
        Ok(Some(source_token)) => source_token,
        Ok(None) => return json_error(400, "missing_challenge_source"),
        Err(_) => return json_error(500, "challenge_source_unavailable"),
    };
    let source_challenge_count = storage::increment_challenge_source_bucket(
        db,
        &source_token,
        challenge_bucket_start(now),
        now,
    )
    .await?;
    if !source_challenge_allows_after_increment(source_challenge_count) {
        return json_error(429, "challenge_rate_limited");
    }

    let challenge_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    let challenge = random::random_urlsafe_token(32)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    let Some(expires_at) = now.checked_add(CHALLENGE_TTL_SECONDS) else {
        return json_error(500, "timestamp_overflow");
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
        return json_error(429, "challenge_rate_limited");
    }

    json_response(
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
        return json_error(400, "invalid_register_request");
    }
    let key_id = match canonical_key_id(&body.key_id) {
        Ok(key_id) => key_id,
        Err(error) => return json_error(400, error.code()),
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
        return json_error(429, "app_attest_registration_rate_limited");
    }

    let Some(challenge) = storage::challenge(db, &body.challenge_id).await? else {
        return json_error(401, "invalid_challenge");
    };

    if challenge.install_id != body.install_id
        || challenge.purpose != REGISTER_PURPOSE
        || challenge.consumed_at.is_some()
        || challenge.expires_at < now
        || challenge.challenge_hash != challenge_hash(&body.challenge)
    {
        return json_error(401, "invalid_challenge");
    }

    if !storage::mark_challenge_consumed(db, &body.challenge_id, now).await? {
        return json_error(401, "invalid_challenge");
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
        Err(error) => return json_error(401, error.code()),
    };

    if !storage::upsert_key_for_challenge(
        db,
        &body.install_id,
        &key_id,
        &verified.public_key,
        &config.app_id,
        &config.app_attest_environment,
        now,
        &body.challenge_id,
    )
    .await?
    {
        return json_error(401, "invalid_challenge");
    }

    json_response(200, &json!({ "message": "registered" }))
}

async fn handle_secure_hello(
    req: &mut Request,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<Response> {
    let authenticated = match authenticate_envelope(
        req,
        db,
        config,
        now,
        "POST",
        SECURE_HELLO_PATH,
        MAX_SMALL_AUTHENTICATED_PAYLOAD_BYTES,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(failure) => return respond_to_auth_failure(db, failure, true, now).await,
    };

    record_secure_attempt(
        db,
        &authenticated.install_id,
        &authenticated.key_id,
        true,
        None,
        now,
    )
    .await
    .ok();

    json_response(200, &json!({ "message": "hello world" }))
}

async fn handle_register_device(
    req: &mut Request,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<Response> {
    let authenticated = match authenticate_envelope(
        req,
        db,
        config,
        now,
        "POST",
        DEVICES_REGISTER_PATH,
        MAX_SMALL_AUTHENTICATED_PAYLOAD_BYTES,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(failure) => return respond_to_auth_failure(db, failure, false, now).await,
    };
    let payload = match decode_payload::<RegisterDevicePayload>(&authenticated.payload) {
        Ok(payload) => payload,
        Err(response) => return response,
    };

    if !apns::validate_apns_environment(&payload.apns_environment) {
        return json_error(400, "invalid_apns_environment");
    }
    if !apns::apns_environment_matches(&payload.apns_environment, config.apns_environment) {
        return json_error(400, "apns_environment_mismatch");
    }

    let token = match apns::normalize_device_token(&payload.device_token) {
        Ok(token) => token,
        Err(error) => return json_error(400, error.code()),
    };

    if !storage::device_exists(db, &authenticated.install_id, &token.hash).await? {
        let enabled_count = storage::enabled_device_count_for_install(
            db,
            &authenticated.install_id,
            &payload.apns_environment,
            &config.bundle_id,
        )
        .await?;
        if enabled_count >= MAX_DEVICES_PER_INSTALL {
            worker::console_warn!(
                "device register rejected: device_limit_exceeded install={} enabled_devices={}",
                logged_install_id(&authenticated.install_id),
                enabled_count
            );
            return json_error(429, "device_limit_exceeded");
        }
    }

    storage::upsert_device(
        db,
        storage::DeviceUpsert {
            install_id: &authenticated.install_id,
            key_id: &authenticated.key_id,
            device_token: &token.value,
            device_token_hash: &token.hash,
            apns_environment: &payload.apns_environment,
            bundle_id: &config.bundle_id,
            notifications_enabled: true,
            job_capable: payload
                .capabilities
                .iter()
                .any(|c| c == "job_completion_v1"),
            now,
        },
    )
    .await?;

    json_response(200, &json!({ "message": "registered" }))
}

async fn handle_unregister_device(
    req: &mut Request,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<Response> {
    let authenticated = match authenticate_envelope(
        req,
        db,
        config,
        now,
        "POST",
        DEVICES_UNREGISTER_PATH,
        MAX_SMALL_AUTHENTICATED_PAYLOAD_BYTES,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(failure) => return respond_to_auth_failure(db, failure, false, now).await,
    };
    let payload = match decode_payload::<UnregisterDevicePayload>(&authenticated.payload) {
        Ok(payload) => payload,
        Err(response) => return response,
    };

    let device_token_hash = match device_token_hash_from_unregister_payload(payload) {
        Some(hash) => hash,
        None => return json_error(400, "invalid_device_token"),
    };

    storage::disable_device(db, &authenticated.install_id, &device_token_hash, now).await?;

    json_response(200, &json!({ "message": "unregistered" }))
}

async fn handle_delete_install(
    req: &mut Request,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<Response> {
    let authenticated = match authenticate_envelope(
        req,
        db,
        config,
        now,
        "POST",
        INSTALL_DELETE_PATH,
        MAX_SMALL_AUTHENTICATED_PAYLOAD_BYTES,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(failure) => return respond_to_auth_failure(db, failure, false, now).await,
    };

    storage::delete_install_data(
        db,
        &authenticated.install_id,
        &config.deletion_fence(&authenticated.install_id)?,
        now,
    )
    .await?;

    json_response(200, &json!({ "message": "deleted" }))
}

async fn handle_debug_send_test_push(
    req: &mut Request,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<Response> {
    let authenticated = match authenticate_envelope(
        req,
        db,
        config,
        now,
        "POST",
        DEBUG_SEND_TEST_PUSH_PATH,
        MAX_SMALL_AUTHENTICATED_PAYLOAD_BYTES,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(failure) => return respond_to_auth_failure(db, failure, false, now).await,
    };
    let payload = match decode_payload::<DebugSendTestPushPayload>(&authenticated.payload) {
        Ok(payload) => payload,
        Err(response) => return response,
    };
    let Some(device) = storage::latest_enabled_device(
        db,
        &authenticated.install_id,
        config.apns_environment.as_str(),
    )
    .await?
    else {
        return json_error(404, "no_registered_device");
    };

    let request = match apns::diagnostic_push_request(
        &device.device_token,
        &config.bundle_id,
        config.apns_environment,
        payload.title.as_deref(),
        payload.body.as_deref(),
    ) {
        Ok(request) => request,
        Err(error) => return json_error(400, error.code()),
    };
    let send_result = send_apns_request(
        env,
        request,
        &authenticated.install_id,
        &device,
        db,
        config.apns_environment,
        now,
    )
    .await?;

    json_response(200, &send_result)
}

async fn handle_sync_subscriptions(
    req: &mut Request,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<Response> {
    let authenticated = match authenticate_envelope(
        req,
        db,
        config,
        now,
        "POST",
        SUBSCRIPTIONS_SYNC_PATH,
        MAX_SUBSCRIPTION_SYNC_PAYLOAD_BYTES,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(failure) => return respond_to_auth_failure(db, failure, false, now).await,
    };
    let payload = match decode_payload::<SyncSubscriptionsPayload>(&authenticated.payload) {
        Ok(payload) => payload,
        Err(response) => return response,
    };

    if let Some(error) = subscription_count_error(payload.subscriptions.len()) {
        return json_error(400, error);
    }

    // Every write this sync produces — pending feed rows, admission-attempt
    // history, subscription upserts, and stale-subscription deletes — is
    // collected here and flushed in one D1 batch. A 200-feed first sync is
    // then a handful of IN-list reads plus one batched write instead of
    // several D1 subrequests per feed.
    let mut writes: Vec<worker::D1PreparedStatement> = Vec::new();
    let mut rejected = Vec::new();
    let mut admitted_by_url: BTreeMap<String, AdmittedSubscription> = BTreeMap::new();
    for subscription in payload.subscriptions {
        match feed_admission::admit_feed_url(&subscription.feed_url) {
            Ok(admitted) => {
                admitted_by_url
                    .entry(admitted.canonical_url.clone())
                    .and_modify(|existing| {
                        existing.notifications_enabled |= subscription.notifications_enabled;
                    })
                    .or_insert(AdmittedSubscription {
                        canonical_url: admitted.canonical_url,
                        source_url: admitted.source_url,
                        host: admitted.host,
                        notifications_enabled: subscription.notifications_enabled,
                    });
            }
            Err(error) => {
                writes.push(feed_admission_attempt_statement(
                    db,
                    &authenticated.install_id,
                    &authenticated.key_id,
                    None,
                    false,
                    Some(error.code()),
                    now,
                )?);
                rejected.push(RejectedSubscription {
                    feed_url: subscription.feed_url,
                    error: error.code(),
                });
            }
        }
    }

    let mut accepted = Vec::new();
    let mut pending = Vec::new();
    let mut accepted_urls = BTreeSet::new();
    let day_start = now.saturating_sub(24 * 60 * 60);
    let mut accepted_new_feeds =
        storage::accepted_admission_count_since(db, &authenticated.install_id, day_start).await?;
    let mut accepted_new_feeds_globally =
        storage::global_accepted_admission_count_since(db, day_start).await?;

    let admitted_urls = admitted_by_url
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    let mut known_feeds = storage::feed_summaries(db, &admitted_urls).await?;

    // Host budgets are only consulted for feeds we do not know yet, so read
    // them for exactly that host set in one pass.
    let unknown_hosts = admitted_by_url
        .values()
        .filter(|admitted| !known_feeds.contains_key(&admitted.canonical_url))
        .map(|admitted| admitted.host.as_str())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let mut accepted_new_feeds_by_host =
        storage::accepted_admission_counts_for_hosts_since(db, &unknown_hosts, day_start).await?;

    for admitted in admitted_by_url.into_values() {
        writes.push(crate::delivery::db::ensure_feed(
            db,
            &admitted.canonical_url,
            now,
        )?);
        if let Some(feed) = known_feeds.remove(&admitted.canonical_url) {
            writes.push(storage::upsert_feed_subscription_statement(
                db,
                &authenticated.install_id,
                &admitted.canonical_url,
                admitted.notifications_enabled,
                now,
                &authenticated.key_id,
            )?);
            accepted_urls.insert(admitted.canonical_url.clone());
            accepted.push(AcceptedSubscription {
                feed_url: admitted.canonical_url,
                title: feed.title,
                health: Some(AcceptedSubscriptionHealth {
                    consecutive_failures: feed.consecutive_failures,
                    last_http_status: feed.last_http_status,
                    last_error: feed.last_error,
                    last_polled_at: feed.last_polled_at,
                }),
            });
            continue;
        }

        let host_accepted_count = accepted_new_feeds_by_host
            .entry(admitted.host.clone())
            .or_insert(0);

        // Unknown feeds admit lazily: the enqueue consumes admission budget
        // and writes the subscription plus a baseline-less feed row now, and
        // the scheduled tick performs the real admission fetch on its first
        // pass. That keeps a large first sync fast instead of running one
        // live RSS fetch per new feed against the client's timeout.
        match admit_pending_enqueue(
            &mut accepted_new_feeds,
            host_accepted_count,
            &mut accepted_new_feeds_globally,
        ) {
            Ok(()) => {
                writes.push(storage::insert_pending_feed_statement(
                    db,
                    &admitted.canonical_url,
                    &admitted.source_url,
                    now,
                )?);
                writes.push(feed_admission_attempt_statement(
                    db,
                    &authenticated.install_id,
                    &authenticated.key_id,
                    Some(&admitted.host),
                    true,
                    None,
                    now,
                )?);
                writes.push(storage::upsert_feed_subscription_statement(
                    db,
                    &authenticated.install_id,
                    &admitted.canonical_url,
                    admitted.notifications_enabled,
                    now,
                    &authenticated.key_id,
                )?);
                accepted_urls.insert(admitted.canonical_url.clone());
                pending.push(PendingSubscription {
                    feed_url: admitted.canonical_url,
                });
            }
            Err(error) => {
                writes.push(feed_admission_attempt_statement(
                    db,
                    &authenticated.install_id,
                    &authenticated.key_id,
                    Some(&admitted.host),
                    false,
                    Some(error),
                    now,
                )?);
                rejected.push(RejectedSubscription {
                    feed_url: admitted.source_url,
                    error,
                });
            }
        }
    }

    let existing_subscriptions =
        storage::install_subscription_feed_urls(db, &authenticated.install_id).await?;
    for feed_url in stale_subscription_urls(
        existing_subscriptions
            .into_iter()
            .map(|subscription| subscription.feed_url),
        &accepted_urls,
    ) {
        writes.push(storage::mark_subscription_deleted_statement(
            db,
            &authenticated.install_id,
            &feed_url,
            now,
            &authenticated.key_id,
        )?);
    }

    storage::run_write_batch(db, writes).await?;

    storage::prune_feed_admission_attempts_before(
        db,
        now.saturating_sub(FEED_ATTEMPT_RETENTION_SECONDS),
    )
    .await
    .ok();

    json_response(
        200,
        &SyncSubscriptionsResponse {
            message: "synced",
            accepted,
            rejected,
            pending,
            registration_ready: storage::registration_ready(
                db,
                &authenticated.install_id,
                config.apns_environment.as_str(),
                &config.bundle_id,
            )
            .await?,
        },
    )
}

fn logged_install_id(install_id: &str) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(&Sha256::digest(install_id.as_bytes())[..8])
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
    let result = app_attest_envelope::authenticate_envelope(
        req,
        db,
        &config.app_id,
        &config.app_attest_environment,
        now,
        method,
        path,
        MAX_AUTHENTICATED_ENVELOPE_BODY_BYTES,
        max_payload_bytes,
    )
    .await?;
    Ok(result)
}

async fn respond_to_auth_failure(
    db: &worker::D1Database,
    failure: AuthFailure,
    records_secure_attempt: bool,
    now: i64,
) -> Result<Response> {
    if records_secure_attempt {
        if let (Some(install_id), Some(key_id)) =
            (failure.install_id.as_deref(), failure.key_id.as_deref())
        {
            record_secure_attempt(db, install_id, key_id, false, Some(failure.code), now)
                .await
                .ok();
        }
    }

    json_error(failure.status, failure.code)
}

fn debug_endpoints_enabled(env: &Env) -> bool {
    env_flag(env, "DEBUG_ENDPOINTS_ENABLED", false)
}

fn public_notifications_enabled(env: &Env) -> bool {
    env_flag(env, "PUBLIC_NOTIFICATIONS_ENABLED", false)
}

fn env_flag(env: &Env, name: &str, default_value: bool) -> bool {
    parse_env_flag(
        env.var(name).ok().map(|value| value.to_string()),
        default_value,
    )
}

async fn read_limited_json<T: for<'de> Deserialize<'de>>(
    req: &mut Request,
    max_bytes: usize,
) -> Result<std::result::Result<T, Response>> {
    if request_content_length_exceeds(req.headers(), max_bytes)? {
        return Ok(Err(json_error(413, "payload_too_large")?));
    }

    let mut stream = req.stream()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len().saturating_add(chunk.len()) > max_bytes {
            return Ok(Err(json_error(413, "payload_too_large")?));
        }
        bytes.extend_from_slice(&chunk);
    }

    match serde_json::from_slice(&bytes) {
        Ok(body) => Ok(Ok(body)),
        Err(_) => Ok(Err(json_error(400, "invalid_json")?)),
    }
}

fn request_content_length_exceeds(headers: &Headers, max_bytes: usize) -> Result<bool> {
    Ok(content_length_exceeds(
        headers.get("content-length")?.as_deref(),
        max_bytes,
    ))
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
        .var("APP_ATTEST_ENVIRONMENT")
        .map(|value| value.to_string())
        .unwrap_or_default();
    Ok(challenge_source_hash_key_for_environment(
        None,
        &environment,
        DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY,
    ))
}

fn decode_payload<T: for<'de> Deserialize<'de>>(
    payload: &str,
) -> std::result::Result<T, Result<Response>> {
    serde_json::from_str(payload).map_err(|_| json_error(400, "invalid_payload"))
}

fn device_token_hash_from_unregister_payload(payload: UnregisterDevicePayload) -> Option<String> {
    if let Some(token) = payload.device_token {
        return apns::normalize_device_token(&token)
            .ok()
            .map(|token| token.hash);
    }

    payload
        .device_token_hash
        .filter(|hash| apns::validate_device_token_hash(hash))
}

async fn send_apns_request(
    env: &Env,
    request: apns::PushRequest,
    install_id: &str,
    device: &storage::DeviceRow,
    db: &worker::D1Database,
    apns_environment: apns::ApnsEnvironment,
    now: i64,
) -> Result<TestPushResponse> {
    if !crate::delivery::control(db, "diagnostic_send").await? {
        return Ok(TestPushResponse {
            message: "send_disabled",
            apns_status: None,
            apns_id: None,
            apns_error: None,
        });
    }
    let result = match crate::delivery::send::diagnostic(
        db,
        env,
        install_id,
        &device.device_token_hash,
        request,
    )
    .await?
    {
        Some(outcome) => ApnsSendResult {
            apns_status: Some(outcome.status),
            apns_id: outcome.apns_id,
            apns_error: (!outcome.reason.is_empty()).then_some(outcome.reason),
        },
        None => ApnsSendResult {
            apns_status: None,
            apns_id: None,
            apns_error: Some("fetch_failed".into()),
        },
    };
    record_push_send_attempt(
        db,
        install_id,
        &device.device_token_hash,
        apns_environment.as_str(),
        result.apns_status,
        result.apns_id.as_deref(),
        result.apns_error.as_deref(),
        now,
    )
    .await?;

    Ok(TestPushResponse {
        message: if result.apns_status == Some(200) {
            "sent"
        } else if result.apns_status.is_some() {
            "apns_error"
        } else {
            "apns_fetch_failed"
        },
        apns_status: result.apns_status,
        apns_id: result.apns_id,
        apns_error: result.apns_error,
    })
}

async fn record_push_send_attempt(
    db: &worker::D1Database,
    install_id: &str,
    device_token_hash: &str,
    apns_environment: &str,
    apns_status: Option<u16>,
    apns_id: Option<&str>,
    apns_error: Option<&str>,
    now: i64,
) -> Result<()> {
    let attempt_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    storage::insert_push_send_attempt(
        db,
        storage::PushSendAttemptInsert {
            attempt_id: &attempt_id,
            install_id: Some(install_id),
            device_token_hash: Some(device_token_hash),
            apns_environment,
            apns_status: apns_status.map(i32::from),
            apns_id,
            apns_error,
            created_at: now,
        },
    )
    .await
}

fn feed_admission_attempt_statement(
    db: &worker::D1Database,
    install_id: &str,
    key_id: &str,
    host: Option<&str>,
    accepted: bool,
    error_code: Option<&str>,
    now: i64,
) -> Result<worker::D1PreparedStatement> {
    let attempt_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    storage::insert_feed_admission_attempt_statement(
        db,
        storage::FeedAdmissionAttemptInsert {
            attempt_id: &attempt_id,
            install_id,
            key_id,
            host,
            accepted,
            error_code,
            created_at: now,
        },
    )
}

async fn record_secure_attempt(
    db: &worker::D1Database,
    install_id: &str,
    key_id: &str,
    accepted: bool,
    error_code: Option<&str>,
    now: i64,
) -> Result<()> {
    let attempt_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    storage::insert_secure_attempt(
        db,
        &attempt_id,
        Some(install_id),
        Some(key_id),
        accepted,
        error_code,
        now,
    )
    .await?;

    storage::prune_secure_attempts_before(db, now.saturating_sub(SECURE_ATTEMPT_RETENTION_SECONDS))
        .await?;

    Ok(())
}

fn now_seconds() -> i64 {
    (worker::js_sys::Date::now() / 1000.0) as i64
}

fn route_response(routed: route::RouteResponse) -> Result<Response> {
    let headers = Headers::new();
    for header in routed.headers {
        headers.set(header.name, header.value)?;
    }

    Ok(Response::from_bytes(routed.body.as_bytes().to_vec())?
        .with_status(routed.status)
        .with_headers(headers))
}

fn json_response<T: Serialize>(status: u16, body: &T) -> Result<Response> {
    Ok(Response::from_json(body)?.with_status(status))
}

fn json_error(status: u16, code: &str) -> Result<Response> {
    match code {
        "method_not_allowed" => static_json_response(status, route::METHOD_NOT_ALLOWED_JSON),
        "not_found" => static_json_response(status, route::NOT_FOUND_JSON),
        _ => json_response(status, &json!({ "error": code })),
    }
}

fn static_json_response(status: u16, body: &'static str) -> Result<Response> {
    let headers = Headers::new();
    headers.set("content-type", route::JSON_CONTENT_TYPE)?;
    Ok(Response::from_bytes(body.as_bytes().to_vec())?
        .with_status(status)
        .with_headers(headers))
}

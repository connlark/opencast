use crate::app_attest::{canonical_key_id, challenge_hash, verify_attestation};
use crate::challenge_limits::{
    challenge_bucket_start, challenge_source_hash_key_for_environment, keyed_source_token,
    source_challenge_allows_after_increment, APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS,
    CHALLENGE_LIMIT_WINDOW_SECONDS, CHALLENGE_RETENTION_SECONDS,
    CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS, CHALLENGE_TTL_SECONDS,
    MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY, MAX_CHALLENGES_PER_SOURCE_PER_HOUR,
    MAX_GLOBAL_CHALLENGES_PER_HOUR,
};
use crate::poll_decisions::{
    episode_should_notify_subscription, episodes_to_notify, feed_failure_retry_seconds,
    feed_poll_chunks, fetch_with_deadline, latest_polled_episode, FEED_FETCH_TIMEOUT_SECONDS,
};
use crate::route::{
    content_length_exceeds, diagnostic_endpoint_path, parse_env_flag, public_write_endpoint,
    ADMIN_TEST_POLL_FEED_PATH, DEBUG_POLL_SUBSCRIPTIONS_PATH, DEBUG_SEND_TEST_PUSH_PATH,
    DEVICES_REGISTER_PATH, DEVICES_UNREGISTER_PATH, INSTALL_DELETE_PATH, SECURE_HELLO_PATH,
    SUBSCRIPTIONS_SYNC_PATH,
};
use crate::{
    apns, feed_admission,
    feed_fetch::{
        append_limited_feed_body_chunk, feed_response_disposition,
        identity_feed_content_length_exceeds, same_origin, FeedBodyAppendError, FeedFetchError,
        FeedResponseDisposition, FEED_USER_AGENT, MAX_FEED_BODY_BYTES,
    },
    feed_identity, notification_retry, poll_scheduling, random, route, rss, storage,
    subscription_admission::{
        admit_pending_enqueue, stale_subscription_urls, subscription_count_error,
        MAX_EXPECTED_PUBLIC_ROLLOUT_INSTALLS_PER_DAY, MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY,
        MAX_SUBSCRIPTIONS_PER_INSTALL,
    },
    subscription_payloads::{AcceptedSubscription, AcceptedSubscriptionHealth},
};
use futures_util::future::join_all;
use futures_util::StreamExt;
use opencast_app_attest_core::app_attest_envelope::{self, AuthFailure, AuthenticatedPayload};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;
use worker::{
    Delay, Env, Fetch, Headers, Method, Request, RequestInit, RequestRedirect, Response, Result,
};

const APP_ATTEST_DB: &str = "APP_ATTEST_DB";
const APNS_CERT_BINDING: &str = "APNS_CERT";
const REGISTER_PURPOSE: &str = "register";
const CHALLENGE_SOURCE_HASH_KEY: &str = "CHALLENGE_SOURCE_HASH_KEY";
const DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY: &str = "opencast-development-challenge-source-key";
const SECURE_ATTEMPT_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const FEED_ATTEMPT_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
// APNs debugging value decays in days; the attempts table exists for
// diagnosis, not audit.
const PUSH_SEND_ATTEMPT_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const DELETED_SUBSCRIPTION_RETENTION_SECONDS: i64 = 90 * 24 * 60 * 60;
const UNSUBSCRIBED_FEED_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const MAX_FEED_GC_PER_SCHEDULED_RUN: i64 = 50;
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
const MAX_ADMIN_TEST_POLL_FEED_REQUEST_BODY_BYTES: usize = 4 * 1024;
const MAX_DEVICES_PER_INSTALL: i64 = 5;
const FEED_POLL_INTERVAL_SECONDS: i64 = poll_scheduling::HOT_INTERVAL_SECONDS;
const MAX_FEEDS_PER_SCHEDULED_RUN: i64 = 50;
const MAX_FEEDS_PER_MANUAL_POLL: usize = 10;
const MAX_FEED_REDIRECTS: usize = 5;

const _: () = assert!(
    MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY
        >= MAX_SUBSCRIPTIONS_PER_INSTALL as i64 * MAX_EXPECTED_PUBLIC_ROLLOUT_INSTALLS_PER_DAY
);
const _: () = assert!(MAX_GLOBAL_CHALLENGES_PER_HOUR > MAX_CHALLENGES_PER_SOURCE_PER_HOUR);

#[derive(Clone)]
struct AppConfig {
    app_id: String,
    bundle_id: String,
    app_attest_environment: String,
    apns_environment: apns::ApnsEnvironment,
}

impl AppConfig {
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

#[derive(Deserialize)]
struct DebugPollSubscriptionsPayload {
    feed_url: Option<String>,
}

#[derive(Deserialize)]
struct AdminTestPollFeedPayload {
    feed_url: String,
}

#[derive(Serialize, Default)]
struct PollSubscriptionsResponse {
    message: &'static str,
    feeds_polled: usize,
    feeds_changed: usize,
    notifications_attempted: usize,
    apns_200_count: usize,
    deduped_count: usize,
    first_error: Option<String>,
}

#[derive(Deserialize)]
struct ApnsErrorResponse {
    reason: String,
}

struct AdmittedSubscription {
    canonical_url: String,
    source_url: String,
    host: String,
    notifications_enabled: bool,
}

struct FetchedFeed {
    status: u16,
    body: String,
    etag: Option<String>,
    last_modified: Option<String>,
}

enum FeedFetchOutcome {
    NotModified { status: u16 },
    Fetched(FetchedFeed),
}

#[derive(Default)]
struct EpisodeSendCounts {
    attempted: usize,
    apns_200: usize,
    deduped: usize,
    retryable_failures: usize,
    truncated_fanouts: usize,
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
        ("POST", DEBUG_POLL_SUBSCRIPTIONS_PATH) => {
            handle_debug_poll_subscriptions(&mut req, &env, &db, &config, now).await
        }
        ("POST", ADMIN_TEST_POLL_FEED_PATH) => {
            handle_admin_test_poll_feed(&mut req, &env, &db, &config, now).await
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
            | SUBSCRIPTIONS_SYNC_PATH
            | DEBUG_POLL_SUBSCRIPTIONS_PATH
            | ADMIN_TEST_POLL_FEED_PATH,
        ) => json_error(405, "method_not_allowed"),
        _ => json_error(404, "not_found"),
    }
}

pub async fn handle_scheduled(env: Env) -> Result<()> {
    let config = AppConfig::from_env(&env)?;
    let db = env.d1(APP_ATTEST_DB)?;
    let now = now_seconds();
    let feeds = storage::due_feed_rows(
        &db,
        now,
        MAX_FEEDS_PER_SCHEDULED_RUN,
        config.apns_environment.as_str(),
    )
    .await?;
    if feeds.len() == MAX_FEEDS_PER_SCHEDULED_RUN as usize {
        worker::console_warn!(
            "scheduled drain saturated: due feeds hit MAX_FEEDS_PER_SCHEDULED_RUN={}",
            MAX_FEEDS_PER_SCHEDULED_RUN
        );
    }
    // Optimistic per-feed claims keep an overlapping invocation (a tick that
    // ran long) from double-fetching the same due rows. Manual/debug polls
    // deliberately bypass the claim: they poll regardless of dueness.
    let mut claimed = Vec::with_capacity(feeds.len());
    for feed in feeds {
        if storage::claim_due_feed(
            &db,
            &feed.feed_url,
            now,
            now.saturating_add(FEED_POLL_INTERVAL_SECONDS),
        )
        .await?
        {
            claimed.push(feed);
        }
    }
    let summary = poll_feeds(claimed, &env, &db, &config, now).await?;
    worker::console_log!(
        "scheduled poll: polled={} changed={} sends={}",
        summary.feeds_polled,
        summary.feeds_changed,
        summary.notifications_attempted
    );
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
    let feed_gc = storage::gc_unsubscribed_feeds(
        &db,
        now.saturating_sub(UNSUBSCRIBED_FEED_RETENTION_SECONDS),
        MAX_FEED_GC_PER_SCHEDULED_RUN,
    )
    .await
    .unwrap_or_default();
    worker::console_log!(
        "scheduled retention: push_attempts={} admission_attempts={} secure_attempts={} deleted_subscriptions={} feeds={} feed_sends={}",
        push_attempts_pruned,
        admission_attempts_pruned,
        secure_attempts_pruned,
        subscriptions_gcd,
        feed_gc.feeds_deleted,
        feed_gc.sends_deleted
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

    storage::delete_install_data(db, &authenticated.install_id).await?;

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
    let Ok(fetcher) = env.service(APNS_CERT_BINDING) else {
        return json_error(500, "apns_binding_missing");
    };

    let send_result = send_apns_request(
        fetcher,
        request,
        &authenticated.install_id,
        &device,
        db,
        config.apns_environment,
        now,
    )
    .await?;

    if notification_retry::should_disable_device(
        send_result.apns_status,
        send_result.apns_error.as_deref(),
    ) {
        storage::disable_device(
            db,
            &authenticated.install_id,
            &device.device_token_hash,
            now,
        )
        .await?;
    }

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
        if let Some(feed) = known_feeds.remove(&admitted.canonical_url) {
            writes.push(storage::upsert_feed_subscription_statement(
                db,
                &authenticated.install_id,
                &admitted.canonical_url,
                admitted.notifications_enabled,
                now,
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
                    FEED_POLL_INTERVAL_SECONDS,
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
        },
    )
}

async fn handle_debug_poll_subscriptions(
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
        DEBUG_POLL_SUBSCRIPTIONS_PATH,
        MAX_SMALL_AUTHENTICATED_PAYLOAD_BYTES,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(failure) => return respond_to_auth_failure(db, failure, false, now).await,
    };
    let payload = match decode_payload::<DebugPollSubscriptionsPayload>(&authenticated.payload) {
        Ok(payload) => payload,
        Err(response) => return response,
    };

    let feeds = if let Some(feed_url) = payload.feed_url {
        let admitted = match feed_admission::admit_feed_url(&feed_url) {
            Ok(admitted) => admitted,
            Err(error) => return json_error(400, error.code()),
        };
        match storage::subscribed_feed_row(db, &authenticated.install_id, &admitted.canonical_url)
            .await?
        {
            Some(feed) => vec![feed],
            None => return json_error(403, "feed_not_subscribed"),
        }
    } else {
        let mut feeds = storage::subscribed_feed_rows(db, &authenticated.install_id).await?;
        feeds.truncate(MAX_FEEDS_PER_MANUAL_POLL);
        feeds
    };

    let response = poll_feeds(feeds, env, db, config, now).await?;
    json_response(200, &response)
}

async fn handle_admin_test_poll_feed(
    req: &mut Request,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<Response> {
    if !admin_test_endpoints_enabled(env) {
        return json_error(404, "not_found");
    }
    if !admin_request_is_authorized(req, env)? {
        return json_error(401, "unauthorized");
    }

    let body = match read_limited_json::<AdminTestPollFeedPayload>(
        req,
        MAX_ADMIN_TEST_POLL_FEED_REQUEST_BODY_BYTES,
    )
    .await?
    {
        Ok(body) => body,
        Err(response) => return Ok(response),
    };
    let admitted = match feed_admission::admit_feed_url(&body.feed_url) {
        Ok(admitted) => admitted,
        Err(error) => return json_error(400, error.code()),
    };
    let Some(feed) = storage::feed_poll_row(db, &admitted.canonical_url).await? else {
        return json_error(403, "feed_not_admitted");
    };
    if storage::enabled_subscription_count_for_feed(db, &admitted.canonical_url).await? == 0 {
        return json_error(403, "feed_not_subscribed");
    }

    let response = poll_feeds(vec![feed], env, db, config, now).await?;
    json_response(200, &response)
}

async fn poll_feeds(
    feeds: Vec<storage::FeedPollRow>,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> Result<PollSubscriptionsResponse> {
    let mut response = PollSubscriptionsResponse {
        message: "polled",
        ..PollSubscriptionsResponse::default()
    };

    for chunk in feed_poll_chunks(feeds) {
        let results = join_all(
            chunk
                .into_iter()
                .map(|feed| poll_one_feed(feed, env, db, config, now)),
        )
        .await;
        for result in results {
            response.feeds_polled += 1;
            match result {
                Ok(counts) => {
                    if counts.changed {
                        response.feeds_changed += 1;
                    }
                    response.notifications_attempted += counts.sends.attempted;
                    response.apns_200_count += counts.sends.apns_200;
                    response.deduped_count += counts.sends.deduped;
                }
                Err(error) => {
                    if response.first_error.is_none() {
                        response.first_error = Some(error);
                    }
                }
            }
        }
    }

    storage::prune_feed_poll_attempts_before(
        db,
        now.saturating_sub(FEED_ATTEMPT_RETENTION_SECONDS),
    )
    .await
    .ok();

    Ok(response)
}

struct PollOneFeedResult {
    changed: bool,
    sends: EpisodeSendCounts,
}

async fn poll_one_feed(
    feed: storage::FeedPollRow,
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    now: i64,
) -> std::result::Result<PollOneFeedResult, String> {
    let started_at = now_seconds();
    match fetch_with_deadline(
        fetch_feed(
            &feed.source_url,
            feed.etag.as_deref(),
            feed.last_modified.as_deref(),
        ),
        Delay::from(Duration::from_secs(FEED_FETCH_TIMEOUT_SECONDS)),
        FeedFetchError::FetchFailed,
    )
    .await
    {
        Ok(FeedFetchOutcome::NotModified { status }) => {
            let poll_interval_seconds = poll_scheduling::poll_interval_seconds(
                feed.publish_cadence_seconds,
                feed.latest_episode_published_at,
                now,
            );
            storage::update_feed_poll_not_modified(
                db,
                &feed.feed_url,
                now.saturating_add(poll_interval_seconds),
                poll_interval_seconds,
                now,
            )
            .await
            .map_err(|error| error.to_string())?;
            record_feed_poll_attempt(
                db,
                &feed.feed_url,
                Some(status),
                false,
                None,
                None,
                started_at,
            )
            .await
            .map_err(|error| error.to_string())?;
            Ok(PollOneFeedResult {
                changed: false,
                sends: EpisodeSendCounts::default(),
            })
        }
        Ok(FeedFetchOutcome::Fetched(fetched)) => {
            let FetchedFeed {
                status,
                body,
                etag,
                last_modified,
            } = fetched;
            let parsed_result = rss::parse_rss(&body, &feed.feed_url);
            drop(body);
            let parsed = match parsed_result {
                Ok(parsed) => parsed,
                Err(error) => {
                    record_feed_poll_failure(
                        db,
                        &feed,
                        Some(status),
                        error.code(),
                        error.is_persistent_compatibility(),
                        started_at,
                        now,
                    )
                    .await
                    .map_err(|error| error.to_string())?;
                    return Err(format!("{}: {}", feed.feed_url, error.code()));
                }
            };
            let latest = match latest_polled_episode(&parsed) {
                Ok(latest) => latest,
                Err(error_code) => {
                    record_feed_poll_failure(
                        db,
                        &feed,
                        Some(status),
                        error_code,
                        false,
                        started_at,
                        now,
                    )
                    .await
                    .map_err(|error| error.to_string())?;
                    return Err(format!("{}: {}", feed.feed_url, error_code));
                }
            };
            let changed = feed
                .latest_episode_id
                .as_deref()
                .map(|known| known != latest.id)
                .unwrap_or(false);
            // Oldest-first so devices receive a catch-up burst in
            // chronological order; each episode takes its own send-ledger
            // claims and per-device gate, and J's per-episode collapse IDs
            // keep the burst individually visible.
            let mut sends = EpisodeSendCounts::default();
            for episode in episodes_to_notify(&feed, &parsed) {
                let episode_fingerprint = feed_identity::episode_notification_fingerprint(
                    feed_identity::EpisodeNotificationFingerprintInput {
                        title: &episode.title,
                        guid: episode.guid.as_deref(),
                        audio_url: episode.audio_url.as_deref(),
                        duration_seconds: episode.duration_seconds,
                        summary: episode.summary.as_deref(),
                        show_notes_html: episode.show_notes_html.as_deref(),
                        episode_id: &episode.id,
                    },
                );
                let episode_sends = send_episode_notifications(
                    env,
                    db,
                    config,
                    &feed.feed_url,
                    &parsed.title,
                    parsed.artwork_url.as_deref(),
                    episode,
                    episode_fingerprint.as_deref(),
                    now,
                )
                .await
                .map_err(|error| error.to_string())?;
                sends.attempted += episode_sends.attempted;
                sends.apns_200 += episode_sends.apns_200;
                sends.deduped += episode_sends.deduped;
                sends.retryable_failures += episode_sends.retryable_failures;
                sends.truncated_fanouts += episode_sends.truncated_fanouts;
            }
            let publish_cadence_seconds = feed_publish_cadence_seconds(&parsed);
            let poll_interval_seconds = poll_scheduling::poll_interval_seconds(
                publish_cadence_seconds,
                latest.published_at,
                now,
            );
            let completion = notification_retry::feed_poll_completion(
                notification_retry::FeedPollCompletionInput {
                    previous_etag: feed.etag.as_deref(),
                    previous_last_modified: feed.last_modified.as_deref(),
                    previous_episode_id: feed.latest_episode_id.as_deref(),
                    previous_episode_title: feed.latest_episode_title.as_deref(),
                    previous_episode_published_at: feed.latest_episode_published_at,
                    fetched_etag: etag.as_deref(),
                    fetched_last_modified: last_modified.as_deref(),
                    fetched_episode_id: &latest.id,
                    fetched_episode_title: &latest.title,
                    fetched_episode_published_at: latest.published_at,
                    computed_poll_interval_seconds: poll_interval_seconds,
                    retryable_failures: sends.retryable_failures,
                    truncated_fanouts: sends.truncated_fanouts,
                    now,
                },
            );

            storage::update_feed_poll_success(
                db,
                storage::FeedPollSuccess {
                    feed_url: &feed.feed_url,
                    title: Some(&parsed.title),
                    website_url: parsed.website_url.as_deref(),
                    etag: completion.etag,
                    last_modified: completion.last_modified,
                    latest_episode_id: completion.latest_episode_id,
                    latest_episode_title: completion.latest_episode_title,
                    latest_episode_published_at: completion.latest_episode_published_at,
                    http_status: i32::from(status),
                    next_poll_at: completion.next_poll_at,
                    poll_interval_seconds,
                    publish_cadence_seconds,
                    now,
                },
            )
            .await
            .map_err(|error| error.to_string())?;
            if feed.baseline_established_at.is_none() {
                // First successful poll of a pending-admission feed: arm the
                // back-catalog guard. Admission never notifies — `changed`
                // is structurally false while no latest_episode_id was
                // stored, so this pass only establishes the baseline.
                storage::establish_feed_baseline(db, &feed.feed_url, now)
                    .await
                    .map_err(|error| error.to_string())?;
            }
            record_feed_poll_attempt(
                db,
                &feed.feed_url,
                Some(status),
                changed,
                changed.then_some(latest.id.as_str()),
                None,
                started_at,
            )
            .await
            .map_err(|error| error.to_string())?;

            Ok(PollOneFeedResult { changed, sends })
        }
        Err(error) => {
            let code = error.code();
            record_feed_poll_failure(
                db,
                &feed,
                error.http_status(),
                code,
                error.is_persistent_compatibility(),
                started_at,
                now,
            )
            .await
            .map_err(|error| error.to_string())?;
            Err(format!("{}: {}", feed.feed_url, code))
        }
    }
}

async fn fetch_feed(
    source_url: &str,
    etag: Option<&str>,
    last_modified: Option<&str>,
) -> std::result::Result<FeedFetchOutcome, FeedFetchError> {
    let mut current_url = source_url.to_string();
    let original_url = url::Url::parse(source_url).map_err(|_| FeedFetchError::FetchFailed)?;

    for redirect_count in 0..=MAX_FEED_REDIRECTS {
        let parsed_current_url =
            url::Url::parse(&current_url).map_err(|_| FeedFetchError::FetchFailed)?;
        let headers = Headers::new();
        // UA-less fetches trip host WAFs into 403 -> six-hour backoff; one
        // unconditional identity serves both the poll and admission paths.
        headers
            .set("user-agent", FEED_USER_AGENT)
            .map_err(|_| FeedFetchError::FetchFailed)?;
        if same_origin(&parsed_current_url, &original_url) {
            if let Some(etag) = etag {
                headers
                    .set("if-none-match", etag)
                    .map_err(|_| FeedFetchError::FetchFailed)?;
            }
            if let Some(last_modified) = last_modified {
                headers
                    .set("if-modified-since", last_modified)
                    .map_err(|_| FeedFetchError::FetchFailed)?;
            }
        }

        let mut init = RequestInit::new();
        init.with_method(Method::Get)
            .with_headers(headers)
            .with_redirect(RequestRedirect::Manual);
        let request =
            Request::new_with_init(&current_url, &init).map_err(|_| FeedFetchError::FetchFailed)?;
        let mut response = Fetch::Request(request)
            .send()
            .await
            .map_err(|_| FeedFetchError::FetchFailed)?;
        let status = response.status_code();

        match feed_response_disposition(status) {
            FeedResponseDisposition::NotModified => {
                return Ok(FeedFetchOutcome::NotModified { status });
            }
            FeedResponseDisposition::Redirect => {
                if redirect_count == MAX_FEED_REDIRECTS {
                    return Err(FeedFetchError::TooManyRedirects);
                }
                let location = response
                    .headers()
                    .get("location")
                    .map_err(|_| FeedFetchError::FetchFailed)?
                    .ok_or(FeedFetchError::MissingRedirectLocation)?;
                let next = parsed_current_url
                    .join(&location)
                    .map_err(|_| FeedFetchError::InvalidRedirect)?;
                feed_admission::admit_feed_url(next.as_str())
                    .map_err(|_| FeedFetchError::InvalidRedirect)?;
                current_url = next.to_string();
                continue;
            }
            FeedResponseDisposition::Other => {}
        }
        if status != 200 {
            return Err(FeedFetchError::HTTPStatus(status));
        }

        let etag = response
            .headers()
            .get("etag")
            .map_err(|_| FeedFetchError::FetchFailed)?;
        let last_modified = response
            .headers()
            .get("last-modified")
            .map_err(|_| FeedFetchError::FetchFailed)?;
        let body = read_feed_body(&mut response).await?;

        return Ok(FeedFetchOutcome::Fetched(FetchedFeed {
            status,
            body,
            etag,
            last_modified,
        }));
    }

    Err(FeedFetchError::TooManyRedirects)
}

fn feed_publish_cadence_seconds(parsed: &rss::ParsedFeed) -> Option<i64> {
    let mut published_at: Vec<i64> = parsed
        .episodes
        .iter()
        .filter_map(|episode| episode.published_at)
        .collect();
    poll_scheduling::publish_cadence_seconds(&mut published_at)
}

async fn read_feed_body(response: &mut Response) -> std::result::Result<String, FeedFetchError> {
    let content_length = response
        .headers()
        .get("content-length")
        .map_err(|_| FeedFetchError::FetchFailed)?;
    let content_encoding = response
        .headers()
        .get("content-encoding")
        .map_err(|_| FeedFetchError::FetchFailed)?;
    if identity_feed_content_length_exceeds(
        content_length.as_deref(),
        content_encoding.as_deref(),
        MAX_FEED_BODY_BYTES,
    ) {
        return Err(FeedFetchError::OversizedBody);
    }

    let mut stream = response.stream().map_err(|_| FeedFetchError::FetchFailed)?;
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| FeedFetchError::FetchFailed)?;
        match append_limited_feed_body_chunk(&mut bytes, &chunk, MAX_FEED_BODY_BYTES) {
            Ok(()) => {}
            Err(FeedBodyAppendError::Oversized) => {
                return Err(FeedFetchError::OversizedBody);
            }
            Err(FeedBodyAppendError::AllocationFailed) => {
                return Err(FeedFetchError::FetchFailed);
            }
        }
    }

    String::from_utf8(bytes).map_err(|_| FeedFetchError::InvalidBodyEncoding)
}

async fn send_episode_notifications(
    env: &Env,
    db: &worker::D1Database,
    config: &AppConfig,
    feed_url: &str,
    podcast_title: &str,
    podcast_artwork_url: Option<&str>,
    episode: &rss::ParsedEpisode,
    episode_fingerprint: Option<&str>,
    now: i64,
) -> Result<EpisodeSendCounts> {
    // No publish date means no subscription can predate the episode (the
    // back-catalog guard below rejects every device), so skip the reads.
    let Some(episode_published_at) = episode.published_at else {
        return Ok(EpisodeSendCounts::default());
    };
    let released = storage::release_stale_episode_send_claims(
        db,
        feed_url,
        &episode.id,
        episode_fingerprint,
        now.saturating_sub(notification_retry::STALE_SEND_CLAIM_SECONDS),
    )
    .await?;
    if released > 0 {
        worker::console_warn!(
            "released {released} stale send claims for {feed_url} episode {}",
            episode.id
        );
    }
    // One extra row tells us whether the page was cut short.
    let page_limit = notification_retry::MAX_EPISODE_FANOUT_DEVICES_PER_POLL + 1;
    let mut devices = storage::episode_fanout_devices(
        db,
        storage::EpisodeFanoutQuery {
            feed_url,
            apns_environment: config.apns_environment.as_str(),
            episode_published_at,
            episode_id: &episode.id,
            episode_fingerprint,
            limit: page_limit as i64,
        },
    )
    .await?;
    if devices.is_empty() {
        return Ok(EpisodeSendCounts::default());
    }
    let mut counts = EpisodeSendCounts::default();
    if devices.len() >= page_limit {
        devices.truncate(notification_retry::MAX_EPISODE_FANOUT_DEVICES_PER_POLL);
        counts.truncated_fanouts = 1;
        worker::console_warn!(
            "fanout for {feed_url} episode {} truncated at {} devices; continuing next poll",
            episode.id,
            notification_retry::MAX_EPISODE_FANOUT_DEVICES_PER_POLL
        );
    }
    let Ok(fetcher) = env.service(APNS_CERT_BINDING) else {
        return Err(worker::Error::RustError("apns_binding_missing".to_string()));
    };

    for device in devices {
        if !episode_should_notify_subscription(episode, device.subscription_created_at) {
            continue;
        }

        let request = match apns::episode_delivery_push_request(
            &device.device_token,
            &config.bundle_id,
            config.apns_environment,
            apns::EpisodeNotification {
                podcast_title,
                episode_title: &episode.title,
                episode_summary: episode.summary.as_deref(),
                show_notes_html: episode.show_notes_html.as_deref(),
                duration_seconds: episode.duration_seconds,
                podcast_artwork_url,
                episode_artwork_url: episode.artwork_url.as_deref(),
                feed_url,
                episode_id: &episode.id,
            },
            now,
        ) {
            Ok(request) => request,
            Err(_) => continue,
        };

        let send_id = random::random_urlsafe_token(16)
            .map_err(|error| worker::Error::RustError(error.to_string()))?;
        let claimed = storage::claim_episode_notification_send(
            db,
            storage::EpisodeNotificationSendClaim {
                send_id: &send_id,
                install_id: &device.install_id,
                device_token_hash: &device.device_token_hash,
                feed_url,
                episode_id: &episode.id,
                episode_fingerprint,
                apns_environment: config.apns_environment.as_str(),
                now,
            },
        )
        .await?;
        if !claimed {
            counts.deduped += 1;
            continue;
        }

        counts.attempted += 1;
        let result = perform_apns_request(fetcher.clone(), request).await?;
        if result.apns_status == Some(200) {
            counts.apns_200 += 1;
        }

        // Everything the outcome implies lands in one D1 batch: the audit
        // row, the claim's outcome (or its release for a retryable failure,
        // which is what lets the next poll claim the device again), and the
        // device disable for a dead token.
        let attempt_id = random::random_urlsafe_token(16)
            .map_err(|error| worker::Error::RustError(error.to_string()))?;
        let mut writes = vec![storage::insert_push_send_attempt_statement(
            db,
            storage::PushSendAttemptInsert {
                attempt_id: &attempt_id,
                install_id: Some(&device.install_id),
                device_token_hash: Some(&device.device_token_hash),
                apns_environment: config.apns_environment.as_str(),
                apns_status: result.apns_status.map(i32::from),
                apns_id: result.apns_id.as_deref(),
                apns_error: result.apns_error.as_deref(),
                created_at: now,
            },
        )?];
        if notification_retry::retryable_apns_failure(
            result.apns_status,
            result.apns_error.as_deref(),
        ) {
            counts.retryable_failures += 1;
            writes.push(storage::delete_episode_notification_send_statement(
                db, &send_id,
            )?);
        } else {
            writes.push(storage::update_episode_notification_send_statement(
                db,
                storage::EpisodeNotificationSendOutcome {
                    send_id: &send_id,
                    apns_status: result.apns_status.map(i32::from),
                    apns_id: result.apns_id.as_deref(),
                    apns_error: result.apns_error.as_deref(),
                    now,
                },
            )?);
        }
        if notification_retry::should_disable_device(
            result.apns_status,
            result.apns_error.as_deref(),
        ) {
            writes.push(storage::disable_device_statement(
                db,
                &device.install_id,
                &device.device_token_hash,
                now,
            )?);
        }
        storage::run_write_batch(db, writes).await?;
    }

    Ok(counts)
}

async fn record_feed_poll_failure(
    db: &worker::D1Database,
    feed: &storage::FeedPollRow,
    http_status: Option<u16>,
    error_code: &str,
    persistent_compatibility: bool,
    started_at: i64,
    now: i64,
) -> Result<()> {
    let failures = feed.consecutive_failures.saturating_add(1);
    let retry_seconds = feed_failure_retry_seconds(
        failures,
        persistent_compatibility,
        worker::js_sys::Math::random(),
    );
    storage::update_feed_poll_failure(
        db,
        &feed.feed_url,
        http_status.map(i32::from),
        error_code,
        failures,
        now.saturating_add(retry_seconds),
        now,
    )
    .await?;
    record_feed_poll_attempt(
        db,
        &feed.feed_url,
        http_status,
        false,
        None,
        Some(error_code),
        started_at,
    )
    .await
}

async fn record_feed_poll_attempt(
    db: &worker::D1Database,
    feed_url: &str,
    http_status: Option<u16>,
    changed: bool,
    new_episode_id: Option<&str>,
    error_code: Option<&str>,
    started_at: i64,
) -> Result<()> {
    let attempt_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    storage::insert_feed_poll_attempt(
        db,
        storage::FeedPollAttemptInsert {
            attempt_id: &attempt_id,
            feed_url,
            http_status: http_status.map(i32::from),
            changed,
            new_episode_id,
            error_code,
            started_at,
            finished_at: now_seconds(),
        },
    )
    .await
}

/// The logging convention for install identity: a 16-hex SHA-256 prefix —
/// enough to correlate log lines, never the raw install id.
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
    app_attest_envelope::authenticate_envelope(
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
    .await
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

fn admin_test_endpoints_enabled(env: &Env) -> bool {
    env_flag(env, "ADMIN_TEST_ENDPOINTS_ENABLED", false)
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

fn admin_request_is_authorized(req: &Request, env: &Env) -> Result<bool> {
    let expected_token = env.secret("ADMIN_TEST_TOKEN")?.to_string();
    let Some(authorization) = req.headers().get("authorization")? else {
        return Ok(false);
    };
    let Some(token) = authorization.strip_prefix("Bearer ") else {
        return Ok(false);
    };

    Ok(timing_safe_equal(token, &expected_token))
}

fn timing_safe_equal(left: &str, right: &str) -> bool {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let max_length = left.len().max(right.len());
    let mut difference = left.len() ^ right.len();

    for index in 0..max_length {
        let left_byte = left.get(index).copied().unwrap_or(0);
        let right_byte = right.get(index).copied().unwrap_or(0);
        difference |= usize::from(left_byte ^ right_byte);
    }

    difference == 0
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
    fetcher: worker::Fetcher,
    request: apns::PushRequest,
    install_id: &str,
    device: &storage::DeviceRow,
    db: &worker::D1Database,
    apns_environment: apns::ApnsEnvironment,
    now: i64,
) -> Result<TestPushResponse> {
    let result = perform_apns_request(fetcher, request).await?;
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

async fn perform_apns_request(
    fetcher: worker::Fetcher,
    request: apns::PushRequest,
) -> Result<ApnsSendResult> {
    let headers = Headers::new();
    for (name, value) in request.headers {
        headers.set(name, &value)?;
    }

    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(worker::wasm_bindgen::JsValue::from_str(&request.body)));

    let mut apns_response = match fetcher.fetch(request.url, Some(init)).await {
        Ok(response) => response,
        Err(_) => {
            return Ok(ApnsSendResult {
                apns_status: None,
                apns_id: None,
                apns_error: Some("fetch_failed".to_string()),
            });
        }
    };

    let apns_status = apns_response.status_code();
    let apns_id = apns_response.headers().get("apns-id")?;
    let apns_error = if apns_status == 200 {
        None
    } else {
        apns_error_reason(&mut apns_response).await
    };

    Ok(ApnsSendResult {
        apns_status: Some(apns_status),
        apns_id,
        apns_error,
    })
}

async fn apns_error_reason(response: &mut Response) -> Option<String> {
    let text = response.text().await.ok()?;
    if text.is_empty() {
        return None;
    }

    serde_json::from_str::<ApnsErrorResponse>(&text)
        .map(|body| body.reason)
        .ok()
        .or_else(|| Some(text.chars().take(200).collect()))
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

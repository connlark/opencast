use crate::app_attest::{canonical_key_id, challenge_hash, verify_attestation};
use crate::challenge_limits::{
    challenge_bucket_start, challenge_source_hash_key_for_environment,
    global_challenge_allows_insert, install_challenge_allows_insert, keyed_source_token,
    source_challenge_allows_after_increment, APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS,
    CHALLENGE_LIMIT_WINDOW_SECONDS, CHALLENGE_RETENTION_SECONDS,
    CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS, CHALLENGE_TTL_SECONDS,
    MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY, MAX_CHALLENGES_PER_SOURCE_PER_HOUR,
    MAX_GLOBAL_CHALLENGES_PER_HOUR,
};
use crate::poll_decisions::{
    changed_episode_should_notify, episode_should_notify_subscription, latest_polled_episode,
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
        append_limited_feed_body_chunk, feed_content_length_exceeds, feed_response_disposition,
        same_origin, FeedResponseDisposition, MAX_FEED_BODY_BYTES,
    },
    feed_identity, notification_retry, poll_scheduling, random, route, rss, storage,
    subscription_admission::{
        feed_admission_error, subscription_count_error, FeedAdmissionStatus,
        MAX_EXPECTED_PUBLIC_ROLLOUT_INSTALLS_PER_DAY, MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY,
        MAX_SUBSCRIPTIONS_PER_INSTALL,
    },
};
use futures_util::StreamExt;
use opencast_app_attest_core::app_attest_envelope::{self, AuthFailure, AuthenticatedPayload};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use worker::{
    Env, Fetch, Headers, Method, Request, RequestInit, RequestRedirect, Response, Result,
};

const APP_ATTEST_DB: &str = "APP_ATTEST_DB";
const APNS_CERT_BINDING: &str = "APNS_CERT";
const REGISTER_PURPOSE: &str = "register";
const CHALLENGE_SOURCE_HASH_KEY: &str = "CHALLENGE_SOURCE_HASH_KEY";
const DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY: &str = "opencast-development-challenge-source-key";
const SECURE_ATTEMPT_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const FEED_ATTEMPT_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const MAX_SUBSCRIPTION_SYNC_PAYLOAD_BYTES: usize = 48 * 1024;
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
const MAX_BACKOFF_SECONDS: i64 = 6 * 60 * 60;

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
}

#[derive(Serialize)]
struct AcceptedSubscription {
    feed_url: String,
    title: Option<String>,
}

#[derive(Serialize)]
struct RejectedSubscription {
    feed_url: String,
    error: &'static str,
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

#[derive(Debug, Clone)]
enum FeedFetchError {
    InvalidRedirect,
    TooManyRedirects,
    FetchFailed,
    MissingRedirectLocation,
    HTTPStatus(u16),
    OversizedBody,
    InvalidBodyEncoding,
}

impl FeedFetchError {
    fn code(&self) -> &'static str {
        match self {
            FeedFetchError::InvalidRedirect => "invalid_redirect",
            FeedFetchError::TooManyRedirects => "too_many_redirects",
            FeedFetchError::FetchFailed => "fetch_failed",
            FeedFetchError::MissingRedirectLocation => "missing_redirect_location",
            FeedFetchError::HTTPStatus(_) => "http_error",
            FeedFetchError::OversizedBody => "oversized_body",
            FeedFetchError::InvalidBodyEncoding => "invalid_body_encoding",
        }
    }

    fn http_status(&self) -> Option<u16> {
        match self {
            FeedFetchError::HTTPStatus(status) => Some(*status),
            _ => None,
        }
    }
}

#[derive(Default)]
struct EpisodeSendCounts {
    attempted: usize,
    apns_200: usize,
    deduped: usize,
    retryable_failures: usize,
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
    let summary = poll_feeds(feeds, &env, &db, &config, now).await?;
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

    let global_challenge_count =
        storage::global_challenge_count_since(db, challenge_window_start).await?;
    if !global_challenge_allows_insert(global_challenge_count) {
        return json_error(429, "challenge_rate_limited");
    }

    let challenge_count =
        storage::challenge_count_since(db, &body.install_id, challenge_window_start).await?;
    if !install_challenge_allows_insert(challenge_count) {
        return json_error(429, "challenge_rate_limited");
    }

    let challenge_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    let challenge = random::random_urlsafe_token(32)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    let Some(expires_at) = now.checked_add(CHALLENGE_TTL_SECONDS) else {
        return json_error(500, "timestamp_overflow");
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
                authenticated.install_id,
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
                record_feed_admission_attempt(
                    db,
                    &authenticated.install_id,
                    &authenticated.key_id,
                    None,
                    false,
                    Some(error.code()),
                    now,
                )
                .await
                .ok();
                rejected.push(RejectedSubscription {
                    feed_url: subscription.feed_url,
                    error: error.code(),
                });
            }
        }
    }

    let mut accepted = Vec::new();
    let mut accepted_urls = BTreeSet::new();
    let day_start = now.saturating_sub(24 * 60 * 60);
    let mut accepted_new_feeds =
        storage::accepted_admission_count_since(db, &authenticated.install_id, day_start).await?;
    let mut accepted_new_feeds_globally =
        storage::global_accepted_admission_count_since(db, day_start).await?;
    let mut accepted_new_feeds_by_host: BTreeMap<String, i64> = BTreeMap::new();

    for admitted in admitted_by_url.into_values() {
        if let Some(feed) = storage::feed_summary(db, &admitted.canonical_url).await? {
            storage::upsert_feed_subscription(
                db,
                &authenticated.install_id,
                &admitted.canonical_url,
                admitted.notifications_enabled,
                now,
            )
            .await?;
            accepted_urls.insert(admitted.canonical_url.clone());
            accepted.push(AcceptedSubscription {
                feed_url: admitted.canonical_url,
                title: feed.title,
            });
            continue;
        }

        let host_accepted_count =
            if let Some(count) = accepted_new_feeds_by_host.get(&admitted.host) {
                *count
            } else {
                let count =
                    storage::accepted_admission_count_for_host_since(db, &admitted.host, day_start)
                        .await?;
                accepted_new_feeds_by_host.insert(admitted.host.clone(), count);
                count
            };
        if let Some(error) = feed_admission_error(
            FeedAdmissionStatus::New,
            accepted_new_feeds,
            host_accepted_count,
            accepted_new_feeds_globally,
        ) {
            record_feed_admission_attempt(
                db,
                &authenticated.install_id,
                &authenticated.key_id,
                Some(&admitted.host),
                false,
                Some(error),
                now,
            )
            .await
            .ok();
            rejected.push(RejectedSubscription {
                feed_url: admitted.source_url,
                error,
            });
            continue;
        }

        match admit_new_feed(db, &authenticated, &admitted, now).await {
            Ok(title) => {
                accepted_new_feeds += 1;
                accepted_new_feeds_globally += 1;
                if let Some(count) = accepted_new_feeds_by_host.get_mut(&admitted.host) {
                    *count += 1;
                }
                storage::upsert_feed_subscription(
                    db,
                    &authenticated.install_id,
                    &admitted.canonical_url,
                    admitted.notifications_enabled,
                    now,
                )
                .await?;
                accepted_urls.insert(admitted.canonical_url.clone());
                accepted.push(AcceptedSubscription {
                    feed_url: admitted.canonical_url,
                    title: Some(title),
                });
            }
            Err(error) => {
                record_feed_admission_attempt(
                    db,
                    &authenticated.install_id,
                    &authenticated.key_id,
                    Some(&admitted.host),
                    false,
                    Some(error),
                    now,
                )
                .await
                .ok();
                rejected.push(RejectedSubscription {
                    feed_url: admitted.source_url,
                    error,
                });
            }
        }
    }

    let existing_subscriptions =
        storage::install_subscription_feed_urls(db, &authenticated.install_id).await?;
    for subscription in existing_subscriptions {
        if !accepted_urls.contains(&subscription.feed_url) {
            storage::mark_subscription_deleted(
                db,
                &authenticated.install_id,
                &subscription.feed_url,
                now,
            )
            .await?;
        }
    }

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

async fn admit_new_feed(
    db: &worker::D1Database,
    authenticated: &AuthenticatedPayload,
    admitted: &AdmittedSubscription,
    now: i64,
) -> std::result::Result<String, &'static str> {
    let fetched = match fetch_feed(&admitted.source_url, None, None).await {
        Ok(FeedFetchOutcome::Fetched(fetched)) => fetched,
        Ok(FeedFetchOutcome::NotModified { .. }) => return Err("unexpected_not_modified"),
        Err(error) => return Err(error.code()),
    };
    let feed =
        rss::parse_rss(&fetched.body, &admitted.canonical_url).map_err(|error| error.code())?;
    let latest = feed.episodes.first();
    let publish_cadence_seconds = feed_publish_cadence_seconds(&feed);
    let latest_episode_published_at = latest.and_then(|episode| episode.published_at);
    let poll_interval_seconds = poll_scheduling::poll_interval_seconds(
        publish_cadence_seconds,
        latest_episode_published_at,
        now,
    );

    storage::upsert_feed_baseline(
        db,
        storage::FeedBaselineUpsert {
            feed_url: &admitted.canonical_url,
            source_url: &admitted.source_url,
            title: Some(&feed.title),
            website_url: feed.website_url.as_deref(),
            etag: fetched.etag.as_deref(),
            last_modified: fetched.last_modified.as_deref(),
            latest_episode_id: latest.map(|episode| episode.id.as_str()),
            latest_episode_title: latest.map(|episode| episode.title.as_str()),
            latest_episode_published_at,
            poll_interval_seconds,
            publish_cadence_seconds,
            now,
        },
    )
    .await
    .map_err(|_| "database_error")?;

    record_feed_admission_attempt(
        db,
        &authenticated.install_id,
        &authenticated.key_id,
        Some(&admitted.host),
        true,
        None,
        now,
    )
    .await
    .ok();

    Ok(feed.title)
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

    for feed in feeds {
        response.feeds_polled += 1;
        match poll_one_feed(feed, env, db, config, now).await {
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
    match fetch_feed(
        &feed.source_url,
        feed.etag.as_deref(),
        feed.last_modified.as_deref(),
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
            let parsed = match rss::parse_rss(&fetched.body, &feed.feed_url) {
                Ok(parsed) => parsed,
                Err(error) => {
                    record_feed_poll_failure(
                        db,
                        &feed,
                        Some(fetched.status),
                        error.code(),
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
                        Some(fetched.status),
                        error_code,
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
            let should_notify = changed && changed_episode_should_notify(&feed, latest);
            let sends = if should_notify {
                let episode_fingerprint = feed_identity::episode_notification_fingerprint(
                    feed_identity::EpisodeNotificationFingerprintInput {
                        title: &latest.title,
                        guid: latest.guid.as_deref(),
                        audio_url: latest.audio_url.as_deref(),
                        duration_seconds: latest.duration_seconds,
                        summary: latest.summary.as_deref(),
                        show_notes_html: latest.show_notes_html.as_deref(),
                        episode_id: &latest.id,
                    },
                );
                send_episode_notifications(
                    env,
                    db,
                    config,
                    &feed.feed_url,
                    &parsed.title,
                    parsed.artwork_url.as_deref(),
                    latest,
                    episode_fingerprint.as_deref(),
                    now,
                )
                .await
                .map_err(|error| error.to_string())?
            } else {
                EpisodeSendCounts::default()
            };
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
                    fetched_etag: fetched.etag.as_deref(),
                    fetched_last_modified: fetched.last_modified.as_deref(),
                    fetched_episode_id: &latest.id,
                    fetched_episode_title: &latest.title,
                    fetched_episode_published_at: latest.published_at,
                    computed_poll_interval_seconds: poll_interval_seconds,
                    retryable_failures: sends.retryable_failures,
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
                    http_status: i32::from(fetched.status),
                    next_poll_at: completion.next_poll_at,
                    poll_interval_seconds,
                    publish_cadence_seconds,
                    now,
                },
            )
            .await
            .map_err(|error| error.to_string())?;
            record_feed_poll_attempt(
                db,
                &feed.feed_url,
                Some(fetched.status),
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
            record_feed_poll_failure(db, &feed, error.http_status(), code, started_at, now)
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
    if feed_content_length_exceeds(content_length.as_deref(), MAX_FEED_BODY_BYTES) {
        return Err(FeedFetchError::OversizedBody);
    }

    let mut stream = response.stream().map_err(|_| FeedFetchError::FetchFailed)?;
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| FeedFetchError::FetchFailed)?;
        if !append_limited_feed_body_chunk(&mut bytes, &chunk, MAX_FEED_BODY_BYTES) {
            return Err(FeedFetchError::OversizedBody);
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
    let devices =
        storage::enabled_devices_for_feed(db, feed_url, config.apns_environment.as_str()).await?;
    if devices.is_empty() {
        return Ok(EpisodeSendCounts::default());
    }
    let Ok(fetcher) = env.service(APNS_CERT_BINDING) else {
        return Err(worker::Error::RustError("apns_binding_missing".to_string()));
    };

    let mut counts = EpisodeSendCounts::default();
    for device in devices {
        if !episode_should_notify_subscription(episode, device.subscription_created_at) {
            continue;
        }

        let request = match apns::episode_push_request(
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
        record_push_send_attempt(
            db,
            &device.install_id,
            &device.device_token_hash,
            config.apns_environment.as_str(),
            result.apns_status,
            result.apns_id.as_deref(),
            result.apns_error.as_deref(),
            now,
        )
        .await?;
        storage::update_episode_notification_send(
            db,
            storage::EpisodeNotificationSendOutcome {
                send_id: &send_id,
                apns_status: result.apns_status.map(i32::from),
                apns_id: result.apns_id.as_deref(),
                apns_error: result.apns_error.as_deref(),
                now,
            },
        )
        .await?;

        if notification_retry::should_disable_device(
            result.apns_status,
            result.apns_error.as_deref(),
        ) {
            storage::disable_device(db, &device.install_id, &device.device_token_hash, now).await?;
        }
        if notification_retry::retryable_apns_failure(
            result.apns_status,
            result.apns_error.as_deref(),
        ) {
            counts.retryable_failures += 1;
            storage::delete_episode_notification_send(db, &send_id).await?;
        }
    }

    Ok(counts)
}

async fn record_feed_poll_failure(
    db: &worker::D1Database,
    feed: &storage::FeedPollRow,
    http_status: Option<u16>,
    error_code: &str,
    started_at: i64,
    now: i64,
) -> Result<()> {
    let failures = feed.consecutive_failures.saturating_add(1);
    storage::update_feed_poll_failure(
        db,
        &feed.feed_url,
        http_status.map(i32::from),
        error_code,
        failures,
        now.saturating_add(backoff_seconds(failures)),
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

fn backoff_seconds(failures: i64) -> i64 {
    let exponent = u32::try_from(failures.saturating_sub(1).min(8)).unwrap_or(0);
    FEED_POLL_INTERVAL_SECONDS
        .saturating_mul(2_i64.saturating_pow(exponent))
        .min(MAX_BACKOFF_SECONDS)
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

async fn record_feed_admission_attempt(
    db: &worker::D1Database,
    install_id: &str,
    key_id: &str,
    host: Option<&str>,
    accepted: bool,
    error_code: Option<&str>,
    now: i64,
) -> Result<()> {
    let attempt_id = random::random_urlsafe_token(16)
        .map_err(|error| worker::Error::RustError(error.to_string()))?;
    storage::insert_feed_admission_attempt(
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
    .await
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

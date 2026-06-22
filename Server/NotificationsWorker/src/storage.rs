#![cfg_attr(all(test, not(target_arch = "wasm32")), allow(dead_code))]

use crate::{app_attest::challenge_hash, d1_changes::changed_exactly_one_row};
use serde::Deserialize;
use worker::{D1Database, D1Type, Result};

#[derive(Debug, Deserialize)]
pub struct ChallengeRow {
    pub challenge_hash: String,
    pub purpose: String,
    pub install_id: String,
    pub expires_at: i64,
    pub consumed_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct AppAttestKeyRow {
    pub public_key: Vec<u8>,
    pub sign_counter: i64,
    pub app_id: String,
    pub environment: String,
}

#[derive(Debug, Deserialize)]
pub struct DeviceRow {
    pub device_token: String,
    pub device_token_hash: String,
}

#[derive(Debug, Deserialize)]
pub struct FeedSummaryRow {
    pub title: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct FeedPollRow {
    pub feed_url: String,
    pub source_url: String,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub latest_episode_id: Option<String>,
    pub latest_episode_title: Option<String>,
    pub latest_episode_published_at: Option<i64>,
    pub baseline_established_at: Option<i64>,
    pub consecutive_failures: i64,
    pub poll_interval_seconds: i64,
}

#[derive(Debug, Deserialize)]
pub struct InstallSubscriptionRow {
    pub feed_url: String,
}

#[derive(Debug, Deserialize)]
pub struct EnabledDeviceRow {
    pub install_id: String,
    pub device_token: String,
    pub device_token_hash: String,
    pub subscription_created_at: i64,
}

#[derive(Debug, Deserialize)]
struct CountRow {
    count: i64,
}

pub struct FeedPollSuccess<'a> {
    pub feed_url: &'a str,
    pub title: Option<&'a str>,
    pub website_url: Option<&'a str>,
    pub etag: Option<&'a str>,
    pub last_modified: Option<&'a str>,
    pub latest_episode_id: Option<&'a str>,
    pub latest_episode_title: Option<&'a str>,
    pub latest_episode_published_at: Option<i64>,
    pub http_status: i32,
    pub next_poll_at: i64,
    pub now: i64,
}

pub struct FeedBaselineUpsert<'a> {
    pub feed_url: &'a str,
    pub source_url: &'a str,
    pub title: Option<&'a str>,
    pub website_url: Option<&'a str>,
    pub etag: Option<&'a str>,
    pub last_modified: Option<&'a str>,
    pub latest_episode_id: Option<&'a str>,
    pub latest_episode_title: Option<&'a str>,
    pub latest_episode_published_at: Option<i64>,
    pub poll_interval_seconds: i64,
    pub now: i64,
}

pub struct DeviceUpsert<'a> {
    pub install_id: &'a str,
    pub key_id: &'a str,
    pub device_token: &'a str,
    pub device_token_hash: &'a str,
    pub apns_environment: &'a str,
    pub bundle_id: &'a str,
    pub notifications_enabled: bool,
    pub now: i64,
}

pub struct PushSendAttemptInsert<'a> {
    pub attempt_id: &'a str,
    pub install_id: Option<&'a str>,
    pub device_token_hash: Option<&'a str>,
    pub apns_environment: &'a str,
    pub apns_status: Option<i32>,
    pub apns_id: Option<&'a str>,
    pub apns_error: Option<&'a str>,
    pub created_at: i64,
}

pub struct FeedAdmissionAttemptInsert<'a> {
    pub attempt_id: &'a str,
    pub install_id: &'a str,
    pub key_id: &'a str,
    pub host: Option<&'a str>,
    pub accepted: bool,
    pub error_code: Option<&'a str>,
    pub created_at: i64,
}

pub struct FeedPollAttemptInsert<'a> {
    pub attempt_id: &'a str,
    pub feed_url: &'a str,
    pub http_status: Option<i32>,
    pub changed: bool,
    pub new_episode_id: Option<&'a str>,
    pub error_code: Option<&'a str>,
    pub started_at: i64,
    pub finished_at: i64,
}

pub struct EpisodeNotificationSendClaim<'a> {
    pub send_id: &'a str,
    pub install_id: &'a str,
    pub device_token_hash: &'a str,
    pub feed_url: &'a str,
    pub episode_id: &'a str,
    pub episode_fingerprint: Option<&'a str>,
    pub apns_environment: &'a str,
    pub now: i64,
}

pub struct EpisodeNotificationSendOutcome<'a> {
    pub send_id: &'a str,
    pub apns_status: Option<i32>,
    pub apns_id: Option<&'a str>,
    pub apns_error: Option<&'a str>,
    pub now: i64,
}

const MAX_STORED_FEED_TITLE_CHARS: usize = 512;
const MAX_STORED_EPISODE_TITLE_CHARS: usize = 512;

const DUE_FEED_ROWS_SQL: &str = "SELECT feed_url, source_url, etag, last_modified, latest_episode_id, latest_episode_title, latest_episode_published_at, baseline_established_at, consecutive_failures, poll_interval_seconds \
         FROM feeds \
         WHERE (next_poll_at IS NULL OR next_poll_at <= ?1) \
           AND EXISTS ( \
             SELECT 1 \
             FROM feed_subscriptions \
             WHERE feed_subscriptions.feed_url = feeds.feed_url \
               AND feed_subscriptions.notifications_enabled = 1 \
               AND feed_subscriptions.deleted_at IS NULL \
               AND EXISTS ( \
                 SELECT 1 \
                 FROM devices \
                 WHERE devices.install_id = feed_subscriptions.install_id \
                   AND devices.notifications_enabled = 1 \
                   AND devices.apns_environment = ?2 \
               ) \
           ) \
         ORDER BY COALESCE(next_poll_at, 0), updated_at \
         LIMIT ?3";

const ENABLED_DEVICES_FOR_FEED_SQL: &str = "SELECT devices.install_id, devices.device_token, devices.device_token_hash, feed_subscriptions.created_at AS subscription_created_at \
         FROM devices \
         INNER JOIN feed_subscriptions ON feed_subscriptions.install_id = devices.install_id \
         WHERE feed_subscriptions.feed_url = ?1 \
           AND feed_subscriptions.notifications_enabled = 1 \
           AND feed_subscriptions.deleted_at IS NULL \
           AND devices.apns_environment = ?2 \
           AND devices.notifications_enabled = 1 \
           AND NOT EXISTS ( \
             SELECT 1 \
             FROM devices newer \
             WHERE newer.install_id = devices.install_id \
               AND newer.apns_environment = devices.apns_environment \
               AND newer.bundle_id = devices.bundle_id \
               AND newer.notifications_enabled = 1 \
               AND ( \
                 newer.last_seen_at > devices.last_seen_at \
                 OR (newer.last_seen_at = devices.last_seen_at AND newer.device_token_hash > devices.device_token_hash) \
               ) \
           ) \
         ORDER BY devices.install_id";

pub async fn insert_challenge(
    db: &D1Database,
    challenge_id: &str,
    challenge: &str,
    purpose: &str,
    install_id: &str,
    created_at: i64,
    expires_at: i64,
) -> Result<()> {
    let hash = challenge_hash(challenge);
    let args = [
        D1Type::Text(challenge_id),
        D1Type::Text(&hash),
        D1Type::Text(purpose),
        D1Type::Text(install_id),
        d1_i64(created_at),
        d1_i64(expires_at),
    ];

    db.prepare(
        "INSERT INTO app_attest_challenges \
         (challenge_id, challenge_hash, purpose, install_id, created_at, expires_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn challenge(db: &D1Database, challenge_id: &str) -> Result<Option<ChallengeRow>> {
    let args = [D1Type::Text(challenge_id)];
    db.prepare(
        "SELECT challenge_hash, purpose, install_id, expires_at, consumed_at \
         FROM app_attest_challenges \
         WHERE challenge_id = ?1 \
         LIMIT 1",
    )
    .bind_refs(&args)?
    .first::<ChallengeRow>(None)
    .await
}

pub async fn challenge_count_since(db: &D1Database, install_id: &str, since: i64) -> Result<i64> {
    let args = [D1Type::Text(install_id), d1_i64(since)];
    let row = db
        .prepare(
            "SELECT COUNT(*) AS count \
             FROM app_attest_challenges \
             WHERE install_id = ?1 AND created_at >= ?2",
        )
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn global_challenge_count_since(db: &D1Database, since: i64) -> Result<i64> {
    let args = [d1_i64(since)];
    let row = db
        .prepare(
            "SELECT COUNT(*) AS count \
             FROM app_attest_challenges \
             WHERE created_at >= ?1",
        )
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn increment_challenge_source_bucket(
    db: &D1Database,
    source_token: &str,
    window_start: i64,
    now: i64,
) -> Result<i64> {
    let args = [
        D1Type::Text(source_token),
        d1_i64(window_start),
        d1_i64(now),
    ];
    db.prepare(
        "INSERT INTO app_attest_challenge_source_buckets \
         (source_token, window_start, request_count, updated_at) \
         VALUES (?1, ?2, 1, ?3) \
         ON CONFLICT(source_token, window_start) DO UPDATE SET \
         request_count = app_attest_challenge_source_buckets.request_count + 1, \
         updated_at = excluded.updated_at",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    let row = db
        .prepare(
            "SELECT request_count AS count \
             FROM app_attest_challenge_source_buckets \
             WHERE source_token = ?1 AND window_start = ?2 \
             LIMIT 1",
        )
        .bind_refs(&args[..2])?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn prune_challenge_source_buckets_before(db: &D1Database, cutoff: i64) -> Result<()> {
    let args = [d1_i64(cutoff)];
    db.prepare("DELETE FROM app_attest_challenge_source_buckets WHERE updated_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

pub async fn prune_challenges_before(db: &D1Database, cutoff: i64) -> Result<()> {
    let args = [d1_i64(cutoff)];
    db.prepare("DELETE FROM app_attest_challenges WHERE created_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

pub async fn mark_challenge_consumed(
    db: &D1Database,
    challenge_id: &str,
    consumed_at: i64,
) -> Result<bool> {
    let args = [d1_i64(consumed_at), D1Type::Text(challenge_id)];
    let result = db
        .prepare(
            "UPDATE app_attest_challenges \
             SET consumed_at = ?1 \
             WHERE challenge_id = ?2 AND consumed_at IS NULL",
        )
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(changed_exactly_one_row(
        result.meta()?.and_then(|meta| meta.changes),
    ))
}

pub async fn upsert_key(
    db: &D1Database,
    install_id: &str,
    key_id: &str,
    public_key: &[u8],
    app_id: &str,
    environment: &str,
    now: i64,
) -> Result<()> {
    let sign_counter = 0_i64;
    let args = [
        D1Type::Text(install_id),
        D1Type::Text(key_id),
        D1Type::Blob(public_key),
        d1_i64(sign_counter),
        D1Type::Text(app_id),
        D1Type::Text(environment),
        d1_i64(now),
        d1_i64(now),
    ];

    db.prepare(
        "INSERT INTO app_attest_keys \
         (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) \
         ON CONFLICT(install_id, key_id) DO UPDATE SET \
         public_key = excluded.public_key, \
         sign_counter = MAX(app_attest_keys.sign_counter, excluded.sign_counter), \
         app_id = excluded.app_id, \
         environment = excluded.environment, \
         last_used_at = excluded.last_used_at",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn key(
    db: &D1Database,
    install_id: &str,
    key_id: &str,
) -> Result<Option<AppAttestKeyRow>> {
    let args = [D1Type::Text(install_id), D1Type::Text(key_id)];
    db.prepare(
        "SELECT public_key, sign_counter, app_id, environment \
         FROM app_attest_keys \
         WHERE install_id = ?1 AND key_id = ?2 \
         LIMIT 1",
    )
    .bind_refs(&args)?
    .first::<AppAttestKeyRow>(None)
    .await
}

pub async fn app_attest_key_count_since(
    db: &D1Database,
    install_id: &str,
    since: i64,
) -> Result<i64> {
    let args = [D1Type::Text(install_id), d1_i64(since)];
    let row = db
        .prepare(
            "SELECT COUNT(*) AS count \
             FROM app_attest_keys \
             WHERE install_id = ?1 AND created_at >= ?2",
        )
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn update_key_counter(
    db: &D1Database,
    install_id: &str,
    key_id: &str,
    previous_counter: i64,
    next_counter: i64,
    now: i64,
) -> Result<bool> {
    let args = [
        d1_i64(next_counter),
        d1_i64(now),
        D1Type::Text(install_id),
        D1Type::Text(key_id),
        d1_i64(previous_counter),
    ];

    let result = db
        .prepare(
            "UPDATE app_attest_keys \
             SET sign_counter = ?1, last_used_at = ?2 \
             WHERE install_id = ?3 AND key_id = ?4 AND sign_counter = ?5",
        )
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(changed_exactly_one_row(
        result.meta()?.and_then(|meta| meta.changes),
    ))
}

pub async fn insert_secure_attempt(
    db: &D1Database,
    attempt_id: &str,
    install_id: Option<&str>,
    key_id: Option<&str>,
    accepted: bool,
    error_code: Option<&str>,
    created_at: i64,
) -> Result<()> {
    let install_id = install_id.map(D1Type::Text).unwrap_or(D1Type::Null);
    let key_id = key_id.map(D1Type::Text).unwrap_or(D1Type::Null);
    let error_code = error_code.map(D1Type::Text).unwrap_or(D1Type::Null);
    let args = [
        D1Type::Text(attempt_id),
        install_id,
        key_id,
        D1Type::Integer(i32::from(accepted)),
        error_code,
        d1_i64(created_at),
    ];

    db.prepare(
        "INSERT INTO secure_hello_attempts \
         (attempt_id, install_id, key_id, accepted, error_code, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn prune_secure_attempts_before(db: &D1Database, cutoff: i64) -> Result<()> {
    let args = [d1_i64(cutoff)];
    db.prepare("DELETE FROM secure_hello_attempts WHERE created_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

pub async fn upsert_device(db: &D1Database, device: DeviceUpsert<'_>) -> Result<()> {
    let args = [
        D1Type::Text(device.install_id),
        D1Type::Text(device.key_id),
        D1Type::Text(device.device_token),
        D1Type::Text(device.device_token_hash),
        D1Type::Text(device.apns_environment),
        D1Type::Text(device.bundle_id),
        D1Type::Integer(i32::from(device.notifications_enabled)),
        d1_i64(device.now),
        d1_i64(device.now),
    ];

    db.prepare(
        "INSERT INTO devices \
         (install_id, key_id, device_token, device_token_hash, apns_environment, bundle_id, notifications_enabled, created_at, last_seen_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) \
         ON CONFLICT(install_id, device_token_hash) DO UPDATE SET \
         key_id = excluded.key_id, \
         device_token = excluded.device_token, \
         apns_environment = excluded.apns_environment, \
         bundle_id = excluded.bundle_id, \
         notifications_enabled = excluded.notifications_enabled, \
         last_seen_at = excluded.last_seen_at",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    let cleanup_args = [
        D1Type::Text(""),
        D1Type::Integer(0),
        d1_i64(device.now),
        D1Type::Text(device.install_id),
        D1Type::Text(device.apns_environment),
        D1Type::Text(device.bundle_id),
        D1Type::Text(device.device_token_hash),
    ];
    db.prepare(
        "UPDATE devices \
         SET device_token = ?1, notifications_enabled = ?2, last_seen_at = ?3 \
         WHERE install_id = ?4 \
           AND apns_environment = ?5 \
           AND bundle_id = ?6 \
           AND device_token_hash <> ?7 \
           AND notifications_enabled = 1",
    )
    .bind_refs(&cleanup_args)?
    .run()
    .await?;

    Ok(())
}

pub async fn disable_device(
    db: &D1Database,
    install_id: &str,
    device_token_hash: &str,
    now: i64,
) -> Result<()> {
    let args = [
        D1Type::Text(""),
        D1Type::Integer(0),
        d1_i64(now),
        D1Type::Text(install_id),
        D1Type::Text(device_token_hash),
    ];

    db.prepare(
        "UPDATE devices \
         SET device_token = ?1, notifications_enabled = ?2, last_seen_at = ?3 \
         WHERE install_id = ?4 AND device_token_hash = ?5",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn device_exists(
    db: &D1Database,
    install_id: &str,
    device_token_hash: &str,
) -> Result<bool> {
    let args = [D1Type::Text(install_id), D1Type::Text(device_token_hash)];
    let row = db
        .prepare(
            "SELECT COUNT(*) AS count \
             FROM devices \
             WHERE install_id = ?1 AND device_token_hash = ?2",
        )
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0) > 0)
}

pub async fn device_count_for_install(db: &D1Database, install_id: &str) -> Result<i64> {
    let args = [D1Type::Text(install_id)];
    let row = db
        .prepare("SELECT COUNT(*) AS count FROM devices WHERE install_id = ?1")
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn latest_enabled_device(
    db: &D1Database,
    install_id: &str,
    apns_environment: &str,
) -> Result<Option<DeviceRow>> {
    let args = [D1Type::Text(install_id), D1Type::Text(apns_environment)];
    db.prepare(
        "SELECT device_token, device_token_hash \
         FROM devices \
         WHERE install_id = ?1 AND apns_environment = ?2 AND notifications_enabled = 1 \
         ORDER BY last_seen_at DESC \
         LIMIT 1",
    )
    .bind_refs(&args)?
    .first::<DeviceRow>(None)
    .await
}

pub async fn insert_push_send_attempt(
    db: &D1Database,
    attempt: PushSendAttemptInsert<'_>,
) -> Result<()> {
    let install_id = attempt.install_id.map(D1Type::Text).unwrap_or(D1Type::Null);
    let device_token_hash = attempt
        .device_token_hash
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let apns_status = attempt
        .apns_status
        .map(D1Type::Integer)
        .unwrap_or(D1Type::Null);
    let apns_id = attempt.apns_id.map(D1Type::Text).unwrap_or(D1Type::Null);
    let apns_error = attempt.apns_error.map(D1Type::Text).unwrap_or(D1Type::Null);
    let args = [
        D1Type::Text(attempt.attempt_id),
        install_id,
        device_token_hash,
        D1Type::Text(attempt.apns_environment),
        apns_status,
        apns_id,
        apns_error,
        d1_i64(attempt.created_at),
    ];

    db.prepare(
        "INSERT INTO push_send_attempts \
         (attempt_id, install_id, device_token_hash, apns_environment, apns_status, apns_id, apns_error, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn feed_summary(db: &D1Database, feed_url: &str) -> Result<Option<FeedSummaryRow>> {
    let args = [D1Type::Text(feed_url)];
    db.prepare("SELECT title FROM feeds WHERE feed_url = ?1 LIMIT 1")
        .bind_refs(&args)?
        .first::<FeedSummaryRow>(None)
        .await
}

pub async fn accepted_admission_count_since(
    db: &D1Database,
    install_id: &str,
    since: i64,
) -> Result<i64> {
    let args = [D1Type::Text(install_id), d1_i64(since)];
    let row = db
        .prepare(
            "SELECT COUNT(*) AS count \
             FROM feed_admission_attempts \
             WHERE install_id = ?1 AND accepted = 1 AND created_at >= ?2",
        )
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn accepted_admission_count_for_host_since(
    db: &D1Database,
    host: &str,
    since: i64,
) -> Result<i64> {
    let args = [D1Type::Text(host), d1_i64(since)];
    let row = db
        .prepare(
            "SELECT COUNT(*) AS count \
             FROM feed_admission_attempts \
             WHERE host = ?1 AND accepted = 1 AND created_at >= ?2",
        )
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn global_accepted_admission_count_since(db: &D1Database, since: i64) -> Result<i64> {
    let args = [d1_i64(since)];
    let row = db
        .prepare(
            "SELECT COUNT(*) AS count \
             FROM feed_admission_attempts \
             WHERE accepted = 1 AND created_at >= ?1",
        )
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn upsert_feed_baseline(db: &D1Database, baseline: FeedBaselineUpsert<'_>) -> Result<()> {
    let title = baseline
        .title
        .map(|value| truncated_chars(value, MAX_STORED_FEED_TITLE_CHARS));
    let latest_episode_title = baseline
        .latest_episode_title
        .map(|value| truncated_chars(value, MAX_STORED_EPISODE_TITLE_CHARS));
    let title = title.as_deref().map(D1Type::Text).unwrap_or(D1Type::Null);
    let website_url = baseline
        .website_url
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let etag = baseline.etag.map(D1Type::Text).unwrap_or(D1Type::Null);
    let last_modified = baseline
        .last_modified
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let latest_episode_id = baseline
        .latest_episode_id
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let latest_episode_title = latest_episode_title
        .as_deref()
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let latest_episode_published_at = baseline
        .latest_episode_published_at
        .map(d1_i64)
        .unwrap_or(D1Type::Null);
    let args = [
        D1Type::Text(baseline.feed_url),
        D1Type::Text(baseline.source_url),
        title,
        website_url,
        etag,
        last_modified,
        latest_episode_id,
        latest_episode_title,
        latest_episode_published_at,
        d1_i64(baseline.now),
        d1_i64(baseline.now.saturating_add(baseline.poll_interval_seconds)),
        d1_i64(baseline.poll_interval_seconds),
        d1_i64(baseline.now),
        d1_i64(baseline.now),
    ];

    db.prepare(
        "INSERT INTO feeds \
         (feed_url, source_url, title, website_url, etag, last_modified, latest_episode_id, latest_episode_title, latest_episode_published_at, baseline_established_at, next_poll_at, poll_interval_seconds, consecutive_failures, created_at, updated_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 0, ?13, ?14) \
         ON CONFLICT(feed_url) DO UPDATE SET \
         source_url = excluded.source_url, \
         title = excluded.title, \
         website_url = excluded.website_url, \
         etag = excluded.etag, \
         last_modified = excluded.last_modified, \
         latest_episode_id = COALESCE(feeds.latest_episode_id, excluded.latest_episode_id), \
         latest_episode_title = COALESCE(feeds.latest_episode_title, excluded.latest_episode_title), \
         latest_episode_published_at = COALESCE(feeds.latest_episode_published_at, excluded.latest_episode_published_at), \
         baseline_established_at = COALESCE(feeds.baseline_established_at, excluded.baseline_established_at), \
         next_poll_at = excluded.next_poll_at, \
         poll_interval_seconds = excluded.poll_interval_seconds, \
         consecutive_failures = 0, \
         last_error = NULL, \
         updated_at = excluded.updated_at",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn upsert_feed_subscription(
    db: &D1Database,
    install_id: &str,
    feed_url: &str,
    notifications_enabled: bool,
    now: i64,
) -> Result<()> {
    let args = [
        D1Type::Text(install_id),
        D1Type::Text(feed_url),
        D1Type::Integer(i32::from(notifications_enabled)),
        d1_i64(now),
        d1_i64(now),
    ];

    db.prepare(
        "INSERT INTO feed_subscriptions \
         (install_id, feed_url, notifications_enabled, created_at, updated_at, deleted_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, NULL) \
         ON CONFLICT(install_id, feed_url) DO UPDATE SET \
         created_at = CASE \
           WHEN feed_subscriptions.notifications_enabled = 1 AND feed_subscriptions.deleted_at IS NULL \
           THEN feed_subscriptions.created_at \
           ELSE excluded.created_at \
         END, \
         notifications_enabled = excluded.notifications_enabled, \
         updated_at = excluded.updated_at, \
         deleted_at = NULL",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn install_subscription_feed_urls(
    db: &D1Database,
    install_id: &str,
) -> Result<Vec<InstallSubscriptionRow>> {
    let args = [D1Type::Text(install_id)];
    db.prepare(
        "SELECT feed_url \
         FROM feed_subscriptions \
         WHERE install_id = ?1 AND deleted_at IS NULL",
    )
    .bind_refs(&args)?
    .all()
    .await?
    .results::<InstallSubscriptionRow>()
}

pub async fn mark_subscription_deleted(
    db: &D1Database,
    install_id: &str,
    feed_url: &str,
    now: i64,
) -> Result<()> {
    let args = [
        d1_i64(now),
        D1Type::Text(install_id),
        D1Type::Text(feed_url),
    ];
    db.prepare(
        "UPDATE feed_subscriptions \
         SET notifications_enabled = 0, updated_at = ?1, deleted_at = ?1 \
         WHERE install_id = ?2 AND feed_url = ?3 AND deleted_at IS NULL",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn delete_install_data(db: &D1Database, install_id: &str) -> Result<()> {
    let args = [D1Type::Text(install_id)];
    db.batch(
        [
            "DELETE FROM episode_notification_sends WHERE install_id = ?1",
            "DELETE FROM push_send_attempts WHERE install_id = ?1",
            "DELETE FROM feed_admission_attempts WHERE install_id = ?1",
            "DELETE FROM feed_subscriptions WHERE install_id = ?1",
            "DELETE FROM devices WHERE install_id = ?1",
            "DELETE FROM secure_hello_attempts WHERE install_id = ?1",
            "DELETE FROM app_attest_challenges WHERE install_id = ?1",
            "DELETE FROM app_attest_keys WHERE install_id = ?1",
        ]
        .into_iter()
        .map(|statement| db.prepare(statement).bind_refs(&args))
        .collect::<Result<Vec<_>>>()?,
    )
    .await?;

    Ok(())
}

pub async fn insert_feed_admission_attempt(
    db: &D1Database,
    attempt: FeedAdmissionAttemptInsert<'_>,
) -> Result<()> {
    let host = attempt.host.map(D1Type::Text).unwrap_or(D1Type::Null);
    let error_code = attempt.error_code.map(D1Type::Text).unwrap_or(D1Type::Null);
    let args = [
        D1Type::Text(attempt.attempt_id),
        D1Type::Text(attempt.install_id),
        D1Type::Text(attempt.key_id),
        host,
        D1Type::Integer(i32::from(attempt.accepted)),
        error_code,
        d1_i64(attempt.created_at),
    ];

    db.prepare(
        "INSERT INTO feed_admission_attempts \
         (attempt_id, install_id, key_id, host, accepted, error_code, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn prune_feed_admission_attempts_before(db: &D1Database, cutoff: i64) -> Result<()> {
    let args = [d1_i64(cutoff)];
    db.prepare("DELETE FROM feed_admission_attempts WHERE created_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

pub async fn prune_feed_poll_attempts_before(db: &D1Database, cutoff: i64) -> Result<()> {
    let args = [d1_i64(cutoff)];
    db.prepare("DELETE FROM feed_poll_attempts WHERE started_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

pub async fn due_feed_rows(
    db: &D1Database,
    now: i64,
    limit: i64,
    apns_environment: &str,
) -> Result<Vec<FeedPollRow>> {
    let args = [d1_i64(now), D1Type::Text(apns_environment), d1_i64(limit)];
    db.prepare(DUE_FEED_ROWS_SQL)
        .bind_refs(&args)?
        .all()
        .await?
        .results::<FeedPollRow>()
}

pub async fn subscribed_feed_rows(db: &D1Database, install_id: &str) -> Result<Vec<FeedPollRow>> {
    let args = [D1Type::Text(install_id)];
    db.prepare(
        "SELECT feeds.feed_url, feeds.source_url, feeds.etag, feeds.last_modified, feeds.latest_episode_id, feeds.latest_episode_title, feeds.latest_episode_published_at, feeds.baseline_established_at, feeds.consecutive_failures, feeds.poll_interval_seconds \
         FROM feeds \
         INNER JOIN feed_subscriptions ON feed_subscriptions.feed_url = feeds.feed_url \
         WHERE feed_subscriptions.install_id = ?1 \
           AND feed_subscriptions.notifications_enabled = 1 \
           AND feed_subscriptions.deleted_at IS NULL \
         ORDER BY feeds.feed_url",
    )
    .bind_refs(&args)?
    .all()
    .await?
    .results::<FeedPollRow>()
}

pub async fn subscribed_feed_row(
    db: &D1Database,
    install_id: &str,
    feed_url: &str,
) -> Result<Option<FeedPollRow>> {
    let args = [D1Type::Text(install_id), D1Type::Text(feed_url)];
    db.prepare(
        "SELECT feeds.feed_url, feeds.source_url, feeds.etag, feeds.last_modified, feeds.latest_episode_id, feeds.latest_episode_title, feeds.latest_episode_published_at, feeds.baseline_established_at, feeds.consecutive_failures, feeds.poll_interval_seconds \
         FROM feeds \
         INNER JOIN feed_subscriptions ON feed_subscriptions.feed_url = feeds.feed_url \
         WHERE feed_subscriptions.install_id = ?1 \
           AND feeds.feed_url = ?2 \
           AND feed_subscriptions.notifications_enabled = 1 \
           AND feed_subscriptions.deleted_at IS NULL \
         LIMIT 1",
    )
    .bind_refs(&args)?
    .first::<FeedPollRow>(None)
    .await
}

pub async fn feed_poll_row(db: &D1Database, feed_url: &str) -> Result<Option<FeedPollRow>> {
    let args = [D1Type::Text(feed_url)];
    db.prepare(
        "SELECT feed_url, source_url, etag, last_modified, latest_episode_id, latest_episode_title, latest_episode_published_at, baseline_established_at, consecutive_failures, poll_interval_seconds \
         FROM feeds \
         WHERE feed_url = ?1 \
         LIMIT 1",
    )
    .bind_refs(&args)?
    .first::<FeedPollRow>(None)
    .await
}

pub async fn enabled_subscription_count_for_feed(db: &D1Database, feed_url: &str) -> Result<i64> {
    let args = [D1Type::Text(feed_url)];
    let row = db
        .prepare(
            "SELECT COUNT(*) AS count \
             FROM feed_subscriptions \
             WHERE feed_url = ?1 \
               AND notifications_enabled = 1 \
               AND deleted_at IS NULL",
        )
        .bind_refs(&args)?
        .first::<CountRow>(None)
        .await?;

    Ok(row.map(|row| row.count).unwrap_or(0))
}

pub async fn enabled_devices_for_feed(
    db: &D1Database,
    feed_url: &str,
    apns_environment: &str,
) -> Result<Vec<EnabledDeviceRow>> {
    let args = [D1Type::Text(feed_url), D1Type::Text(apns_environment)];
    db.prepare(ENABLED_DEVICES_FOR_FEED_SQL)
        .bind_refs(&args)?
        .all()
        .await?
        .results::<EnabledDeviceRow>()
}

pub async fn update_feed_poll_not_modified(
    db: &D1Database,
    feed_url: &str,
    next_poll_at: i64,
    now: i64,
) -> Result<()> {
    let args = [d1_i64(now), d1_i64(next_poll_at), D1Type::Text(feed_url)];
    db.prepare(
        "UPDATE feeds \
         SET last_polled_at = ?1, next_poll_at = ?2, consecutive_failures = 0, last_http_status = 304, last_error = NULL, updated_at = ?1 \
         WHERE feed_url = ?3",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn update_feed_poll_success(db: &D1Database, success: FeedPollSuccess<'_>) -> Result<()> {
    let title = success
        .title
        .map(|value| truncated_chars(value, MAX_STORED_FEED_TITLE_CHARS));
    let latest_episode_title = success
        .latest_episode_title
        .map(|value| truncated_chars(value, MAX_STORED_EPISODE_TITLE_CHARS));
    let title = title.as_deref().map(D1Type::Text).unwrap_or(D1Type::Null);
    let website_url = success
        .website_url
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let etag = success.etag.map(D1Type::Text).unwrap_or(D1Type::Null);
    let last_modified = success
        .last_modified
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let latest_episode_id = success
        .latest_episode_id
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let latest_episode_title = latest_episode_title
        .as_deref()
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let latest_episode_published_at = success
        .latest_episode_published_at
        .map(d1_i64)
        .unwrap_or(D1Type::Null);
    let args = [
        title,
        website_url,
        etag,
        last_modified,
        latest_episode_id,
        latest_episode_title,
        latest_episode_published_at,
        d1_i64(success.now),
        d1_i64(success.next_poll_at),
        D1Type::Integer(success.http_status),
        D1Type::Text(success.feed_url),
    ];

    db.prepare(
        "UPDATE feeds \
         SET title = ?1, website_url = ?2, etag = ?3, last_modified = ?4, latest_episode_id = ?5, latest_episode_title = ?6, latest_episode_published_at = ?7, last_polled_at = ?8, next_poll_at = ?9, consecutive_failures = 0, last_http_status = ?10, last_error = NULL, updated_at = ?8 \
         WHERE feed_url = ?11",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn update_feed_poll_failure(
    db: &D1Database,
    feed_url: &str,
    http_status: Option<i32>,
    error_code: &str,
    consecutive_failures: i64,
    next_poll_at: i64,
    now: i64,
) -> Result<()> {
    let http_status = http_status.map(D1Type::Integer).unwrap_or(D1Type::Null);
    let args = [
        http_status,
        D1Type::Text(error_code),
        d1_i64(consecutive_failures),
        d1_i64(now),
        d1_i64(next_poll_at),
        D1Type::Text(feed_url),
    ];

    db.prepare(
        "UPDATE feeds \
         SET last_http_status = ?1, last_error = ?2, consecutive_failures = ?3, last_polled_at = ?4, next_poll_at = ?5, updated_at = ?4 \
         WHERE feed_url = ?6",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn insert_feed_poll_attempt(
    db: &D1Database,
    attempt: FeedPollAttemptInsert<'_>,
) -> Result<()> {
    let http_status = attempt
        .http_status
        .map(D1Type::Integer)
        .unwrap_or(D1Type::Null);
    let new_episode_id = attempt
        .new_episode_id
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let error_code = attempt.error_code.map(D1Type::Text).unwrap_or(D1Type::Null);
    let args = [
        D1Type::Text(attempt.attempt_id),
        D1Type::Text(attempt.feed_url),
        http_status,
        D1Type::Integer(i32::from(attempt.changed)),
        new_episode_id,
        error_code,
        d1_i64(attempt.started_at),
        d1_i64(attempt.finished_at),
    ];

    db.prepare(
        "INSERT INTO feed_poll_attempts \
         (attempt_id, feed_url, http_status, changed, new_episode_id, error_code, started_at, finished_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn claim_episode_notification_send(
    db: &D1Database,
    claim: EpisodeNotificationSendClaim<'_>,
) -> Result<bool> {
    let episode_fingerprint = claim
        .episode_fingerprint
        .map(D1Type::Text)
        .unwrap_or(D1Type::Null);
    let args = [
        D1Type::Text(claim.send_id),
        D1Type::Text(claim.install_id),
        D1Type::Text(claim.device_token_hash),
        D1Type::Text(claim.feed_url),
        D1Type::Text(claim.episode_id),
        episode_fingerprint,
        D1Type::Text(claim.apns_environment),
        d1_i64(claim.now),
        d1_i64(claim.now),
    ];

    let result = db
        .prepare(
            "INSERT OR IGNORE INTO episode_notification_sends \
             (send_id, install_id, device_token_hash, feed_url, episode_id, episode_fingerprint, apns_environment, created_at, updated_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        )
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(changed_exactly_one_row(
        result.meta()?.and_then(|meta| meta.changes),
    ))
}

pub async fn update_episode_notification_send(
    db: &D1Database,
    outcome: EpisodeNotificationSendOutcome<'_>,
) -> Result<()> {
    let apns_status = outcome
        .apns_status
        .map(D1Type::Integer)
        .unwrap_or(D1Type::Null);
    let apns_id = outcome.apns_id.map(D1Type::Text).unwrap_or(D1Type::Null);
    let apns_error = outcome.apns_error.map(D1Type::Text).unwrap_or(D1Type::Null);
    let args = [
        apns_status,
        apns_id,
        apns_error,
        d1_i64(outcome.now),
        D1Type::Text(outcome.send_id),
    ];

    db.prepare(
        "UPDATE episode_notification_sends \
         SET apns_status = ?1, apns_id = ?2, apns_error = ?3, updated_at = ?4 \
         WHERE send_id = ?5",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    Ok(())
}

pub async fn delete_episode_notification_send(db: &D1Database, send_id: &str) -> Result<()> {
    let args = [D1Type::Text(send_id)];
    db.prepare("DELETE FROM episode_notification_sends WHERE send_id = ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

fn d1_i64(value: i64) -> D1Type<'static> {
    // worker 0.8 binds D1 Integer as i32. Current counters are u32 and
    // timestamps are second-resolution Unix values, both exactly representable
    // below JS Number's 53-bit integer precision ceiling used by D1 Real.
    debug_assert!((-9_007_199_254_740_991..=9_007_199_254_740_991).contains(&value));
    D1Type::Real(value as f64)
}

fn truncated_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use rusqlite::{params, Connection};

    const NOW: i64 = 1_780_000_000;
    const CURRENT_APNS_ENVIRONMENT: &str = "production";
    const OTHER_APNS_ENVIRONMENT: &str = "development";

    fn setup_db() -> Connection {
        let db = Connection::open_in_memory().expect("open in-memory sqlite");
        apply_migrations_through_0007(&db);
        db.execute_batch(include_str!(
            "../migrations/0008_cleanup_superseded_device_tokens.sql"
        ))
        .expect("cleanup superseded devices");
        db
    }

    fn setup_db_through_0007() -> Connection {
        let db = Connection::open_in_memory().expect("open in-memory sqlite");
        apply_migrations_through_0007(&db);
        db
    }

    fn apply_migrations_through_0007(db: &Connection) {
        db.execute_batch(include_str!("../migrations/0001_app_attest.sql"))
            .expect("create app attest tables");
        db.execute_batch(include_str!("../migrations/0002_devices.sql"))
            .expect("create device tables");
        db.execute_batch(include_str!("../migrations/0003_feed_notifications.sql"))
            .expect("create feed tables");
        db.execute_batch(include_str!("../migrations/0004_public_rollout_caps.sql"))
            .expect("create rollout indexes");
        db.execute_batch(include_str!(
            "../migrations/0005_global_challenge_rate_limit.sql"
        ))
        .expect("create global challenge indexes");
        db.execute_batch(include_str!(
            "../migrations/0006_challenge_source_buckets.sql"
        ))
        .expect("create source challenge buckets");
        db.execute_batch(include_str!(
            "../migrations/0007_notification_fingerprint_and_device_token_cleanup.sql"
        ))
        .expect("create notification fingerprint index");
    }

    fn insert_feed(db: &Connection, feed_url: &str, next_poll_at: Option<i64>, updated_at: i64) {
        db.execute(
            "INSERT INTO feeds \
             (feed_url, source_url, next_poll_at, poll_interval_seconds, consecutive_failures, created_at, updated_at) \
             VALUES (?1, ?1, ?2, 900, 0, ?3, ?4)",
            params![feed_url, next_poll_at, NOW - 100, updated_at],
        )
        .expect("insert feed");
    }

    fn insert_subscription(
        db: &Connection,
        install_id: &str,
        feed_url: &str,
        notifications_enabled: bool,
        deleted_at: Option<i64>,
    ) {
        db.execute(
            "INSERT INTO feed_subscriptions \
             (install_id, feed_url, notifications_enabled, created_at, updated_at, deleted_at) \
             VALUES (?1, ?2, ?3, ?4, ?4, ?5)",
            params![
                install_id,
                feed_url,
                i32::from(notifications_enabled),
                NOW - 50,
                deleted_at
            ],
        )
        .expect("insert subscription");
    }

    fn insert_device(
        db: &Connection,
        install_id: &str,
        device_token_hash: &str,
        apns_environment: &str,
        notifications_enabled: bool,
    ) {
        insert_device_seen(
            db,
            install_id,
            device_token_hash,
            apns_environment,
            notifications_enabled,
            NOW - 25,
        );
    }

    fn insert_device_seen(
        db: &Connection,
        install_id: &str,
        device_token_hash: &str,
        apns_environment: &str,
        notifications_enabled: bool,
        last_seen_at: i64,
    ) {
        db.execute(
            "INSERT INTO devices \
             (install_id, key_id, device_token, device_token_hash, apns_environment, bundle_id, notifications_enabled, created_at, last_seen_at) \
             VALUES (?1, 'key', ?2, ?3, ?4, 'com.connor.opencast', ?5, ?6, ?6)",
            params![
                install_id,
                format!("token-{device_token_hash}"),
                device_token_hash,
                apns_environment,
                i32::from(notifications_enabled),
                last_seen_at
            ],
        )
        .expect("insert device");
    }

    fn activate_feed(db: &Connection, feed_url: &str, install_id: &str) {
        insert_subscription(db, install_id, feed_url, true, None);
        insert_device(
            db,
            install_id,
            &format!("{install_id}-token"),
            CURRENT_APNS_ENVIRONMENT,
            true,
        );
    }

    fn due_feed_urls(db: &Connection, now: i64, limit: i64, apns_environment: &str) -> Vec<String> {
        let mut statement = db
            .prepare(DUE_FEED_ROWS_SQL)
            .expect("prepare due-feed query");
        statement
            .query_map(params![now, apns_environment, limit], |row| {
                row.get::<_, String>("feed_url")
            })
            .expect("query due feeds")
            .collect::<Result<Vec<_>, _>>()
            .expect("read due feed rows")
    }

    fn enabled_device_hashes(
        db: &Connection,
        feed_url: &str,
        apns_environment: &str,
    ) -> Vec<String> {
        let mut statement = db
            .prepare(ENABLED_DEVICES_FOR_FEED_SQL)
            .expect("prepare enabled-device query");
        statement
            .query_map(params![feed_url, apns_environment], |row| {
                row.get::<_, String>("device_token_hash")
            })
            .expect("query enabled devices")
            .collect::<Result<Vec<_>, _>>()
            .expect("read enabled devices")
    }

    fn insert_episode_send(
        db: &Connection,
        send_id: &str,
        episode_id: &str,
        episode_fingerprint: Option<&str>,
        apns_status: Option<i64>,
    ) -> usize {
        db.execute(
            "INSERT OR IGNORE INTO episode_notification_sends \
             (send_id, install_id, device_token_hash, feed_url, episode_id, episode_fingerprint, apns_environment, apns_status, created_at, updated_at) \
             VALUES (?1, 'install-a', 'token-a', 'https://example.com/feed.xml', ?2, ?3, 'production', ?4, ?5, ?5)",
            params![send_id, episode_id, episode_fingerprint, apns_status, NOW],
        )
        .expect("insert episode send")
    }

    #[test]
    fn due_feed_rows_excludes_feed_without_subscriptions() {
        let db = setup_db();
        insert_feed(&db, "https://example.com/no-subs.xml", Some(NOW - 1), NOW);

        assert!(due_feed_urls(&db, NOW, 10, CURRENT_APNS_ENVIRONMENT).is_empty());
    }

    #[test]
    fn due_feed_rows_excludes_deleted_subscription() {
        let db = setup_db();
        let feed_url = "https://example.com/deleted.xml";
        insert_feed(&db, feed_url, Some(NOW - 1), NOW);
        insert_subscription(&db, "install-a", feed_url, true, Some(NOW - 10));
        insert_device(&db, "install-a", "token-a", CURRENT_APNS_ENVIRONMENT, true);

        assert!(due_feed_urls(&db, NOW, 10, CURRENT_APNS_ENVIRONMENT).is_empty());
    }

    #[test]
    fn due_feed_rows_excludes_disabled_subscription() {
        let db = setup_db();
        let feed_url = "https://example.com/disabled-sub.xml";
        insert_feed(&db, feed_url, Some(NOW - 1), NOW);
        insert_subscription(&db, "install-a", feed_url, false, None);
        insert_device(&db, "install-a", "token-a", CURRENT_APNS_ENVIRONMENT, true);

        assert!(due_feed_urls(&db, NOW, 10, CURRENT_APNS_ENVIRONMENT).is_empty());
    }

    #[test]
    fn due_feed_rows_excludes_enabled_subscription_without_enabled_device() {
        let db = setup_db();
        let disabled_device_feed = "https://example.com/disabled-device.xml";
        let missing_device_feed = "https://example.com/missing-device.xml";
        insert_feed(&db, disabled_device_feed, Some(NOW - 1), NOW);
        insert_subscription(&db, "install-a", disabled_device_feed, true, None);
        insert_device(&db, "install-a", "token-a", CURRENT_APNS_ENVIRONMENT, false);
        insert_feed(&db, missing_device_feed, Some(NOW - 1), NOW);
        insert_subscription(&db, "install-b", missing_device_feed, true, None);

        assert!(due_feed_urls(&db, NOW, 10, CURRENT_APNS_ENVIRONMENT).is_empty());
    }

    #[test]
    fn due_feed_rows_excludes_enabled_device_in_wrong_apns_environment() {
        let db = setup_db();
        let feed_url = "https://example.com/wrong-lane.xml";
        insert_feed(&db, feed_url, Some(NOW - 1), NOW);
        insert_subscription(&db, "install-a", feed_url, true, None);
        insert_device(&db, "install-a", "token-a", OTHER_APNS_ENVIRONMENT, true);

        assert!(due_feed_urls(&db, NOW, 10, CURRENT_APNS_ENVIRONMENT).is_empty());
    }

    #[test]
    fn due_feed_rows_returns_active_feed_once_for_multiple_installs_and_devices() {
        let db = setup_db();
        let feed_url = "https://example.com/active.xml";
        insert_feed(&db, feed_url, Some(NOW - 1), NOW);
        activate_feed(&db, feed_url, "install-a");
        insert_device(
            &db,
            "install-a",
            "token-a-2",
            CURRENT_APNS_ENVIRONMENT,
            true,
        );
        activate_feed(&db, feed_url, "install-b");

        assert_eq!(
            due_feed_urls(&db, NOW, 10, CURRENT_APNS_ENVIRONMENT),
            vec![feed_url]
        );
    }

    #[test]
    fn enabled_devices_for_feed_uses_latest_enabled_token_per_install() {
        let db = setup_db();
        let feed_url = "https://example.com/stale-token.xml";
        insert_feed(&db, feed_url, Some(NOW - 1), NOW);
        insert_subscription(&db, "install-a", feed_url, true, None);
        insert_device_seen(
            &db,
            "install-a",
            "older-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
            NOW - 30,
        );
        insert_device_seen(
            &db,
            "install-a",
            "newer-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
            NOW - 10,
        );
        insert_subscription(&db, "install-b", feed_url, true, None);
        insert_device_seen(
            &db,
            "install-b",
            "install-b-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
            NOW - 20,
        );

        assert_eq!(
            enabled_device_hashes(&db, feed_url, CURRENT_APNS_ENVIRONMENT),
            vec!["newer-token", "install-b-token"]
        );
    }

    #[test]
    fn due_feed_rows_preserves_overdue_ordering_and_limit_across_active_feeds() {
        let db = setup_db();
        insert_feed(&db, "https://example.com/null.xml", None, NOW + 30);
        insert_feed(&db, "https://example.com/old.xml", Some(NOW - 20), NOW + 20);
        insert_feed(
            &db,
            "https://example.com/newer.xml",
            Some(NOW - 10),
            NOW + 10,
        );
        insert_feed(&db, "https://example.com/future.xml", Some(NOW + 60), NOW);
        activate_feed(&db, "https://example.com/null.xml", "install-null");
        activate_feed(&db, "https://example.com/old.xml", "install-old");
        activate_feed(&db, "https://example.com/newer.xml", "install-newer");
        activate_feed(&db, "https://example.com/future.xml", "install-future");

        assert_eq!(
            due_feed_urls(&db, NOW, 2, CURRENT_APNS_ENVIRONMENT),
            vec![
                "https://example.com/null.xml",
                "https://example.com/old.xml"
            ]
        );
    }

    #[test]
    fn due_feed_rows_excludes_feed_after_subscription_delete_and_device_disable() {
        let db = setup_db();
        let feed_url = "https://example.com/production-symptom.xml";
        insert_feed(&db, feed_url, Some(NOW - 1), NOW);
        activate_feed(&db, feed_url, "install-a");

        db.execute(
            "UPDATE feed_subscriptions \
             SET notifications_enabled = 0, deleted_at = ?1, updated_at = ?1 \
             WHERE install_id = ?2 AND feed_url = ?3",
            params![NOW + 1, "install-a", feed_url],
        )
        .expect("delete subscription");
        db.execute(
            "UPDATE devices \
             SET notifications_enabled = 0, last_seen_at = ?1 \
             WHERE install_id = ?2",
            params![NOW + 1, "install-a"],
        )
        .expect("disable device");

        assert!(due_feed_urls(&db, NOW + 2, 10, CURRENT_APNS_ENVIRONMENT).is_empty());
    }

    #[test]
    fn same_episode_fingerprint_dedupes_different_episode_ids() {
        let db = setup_db();

        assert_eq!(
            insert_episode_send(
                &db,
                "send-a",
                "episode-id-a",
                Some("fingerprint-a"),
                Some(200)
            ),
            1
        );
        assert_eq!(
            insert_episode_send(
                &db,
                "send-b",
                "episode-id-b",
                Some("fingerprint-a"),
                Some(200)
            ),
            0
        );
    }

    #[test]
    fn null_episode_fingerprints_keep_legacy_episode_id_uniqueness() {
        let db = setup_db();

        assert_eq!(
            insert_episode_send(&db, "send-a", "episode-id-a", None, Some(200)),
            1
        );
        assert_eq!(
            insert_episode_send(&db, "send-b", "episode-id-b", None, Some(200)),
            1
        );
        assert_eq!(
            insert_episode_send(&db, "send-c", "episode-id-a", None, Some(200)),
            0
        );
    }

    #[test]
    fn retryable_episode_send_failure_can_be_claimed_after_release() {
        let db = setup_db();

        assert_eq!(
            insert_episode_send(&db, "send-a", "episode-id-a", Some("fingerprint-a"), None),
            1
        );
        db.execute(
            "UPDATE episode_notification_sends SET apns_status = 500, apns_error = 'InternalServerError' WHERE send_id = 'send-a'",
            [],
        )
        .expect("record retryable failure");
        db.execute(
            "DELETE FROM episode_notification_sends WHERE send_id = 'send-a'",
            [],
        )
        .expect("release retryable claim");

        assert_eq!(
            insert_episode_send(&db, "send-b", "episode-id-a", Some("fingerprint-a"), None),
            1
        );
    }

    #[test]
    fn permanent_episode_send_outcome_remains_consumed() {
        let db = setup_db();

        assert_eq!(
            insert_episode_send(
                &db,
                "send-a",
                "episode-id-a",
                Some("fingerprint-a"),
                Some(200)
            ),
            1
        );
        assert_eq!(
            insert_episode_send(&db, "send-b", "episode-id-a", Some("fingerprint-a"), None),
            0
        );
    }

    #[test]
    fn cleanup_superseded_device_tokens_migration_is_idempotent() {
        let db = setup_db_through_0007();
        insert_device_seen(
            &db,
            "install-a",
            "older-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
            NOW - 30,
        );
        insert_device_seen(
            &db,
            "install-a",
            "newer-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
            NOW - 10,
        );
        insert_device_seen(
            &db,
            "install-a",
            "dev-token",
            OTHER_APNS_ENVIRONMENT,
            true,
            NOW - 40,
        );

        db.execute_batch(include_str!(
            "../migrations/0008_cleanup_superseded_device_tokens.sql"
        ))
        .expect("first cleanup");
        db.execute_batch(include_str!(
            "../migrations/0008_cleanup_superseded_device_tokens.sql"
        ))
        .expect("second cleanup");

        let enabled_production: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM devices WHERE install_id = 'install-a' AND apns_environment = ?1 AND notifications_enabled = 1",
                params![CURRENT_APNS_ENVIRONMENT],
                |row| row.get(0),
            )
            .expect("count enabled production devices");
        let older_token: String = db
            .query_row(
                "SELECT device_token FROM devices WHERE device_token_hash = 'older-token'",
                [],
                |row| row.get(0),
            )
            .expect("read older device token");
        let enabled_development: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM devices WHERE install_id = 'install-a' AND apns_environment = ?1 AND notifications_enabled = 1",
                params![OTHER_APNS_ENVIRONMENT],
                |row| row.get(0),
            )
            .expect("count enabled development devices");

        assert_eq!(enabled_production, 1);
        assert_eq!(enabled_development, 1);
        assert_eq!(older_token, "");
    }

    #[test]
    #[should_panic]
    fn d1_i64_debug_asserts_values_outside_exact_js_integer_range() {
        let _ = d1_i64(9_007_199_254_740_992);
    }
}

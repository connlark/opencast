#![cfg_attr(all(test, not(target_arch = "wasm32")), allow(dead_code))]

use crate::d1_changes::changed_exactly_one_row;
use serde::Deserialize;
use worker::{D1Database, D1Type, Result};

// App Attest challenge/key storage lives in the shared core crate (one copy
// for AdAnalysisWorker, RemoteTranscriptionWorker, and this worker). This
// worker's App Attest schema arrived by its own migration lineage
// (0001_app_attest.sql plus later additions), but the challenge/key tables
// and every query against them are identical to the shared versions.
// wasm-only because the sole consumer (`worker_app`) is wasm-only.
#[cfg(target_arch = "wasm32")]
pub use opencast_app_attest_core::app_attest_storage::{
    app_attest_key_count_since, challenge, challenge_count_since, global_challenge_count_since,
    increment_challenge_source_bucket, insert_challenge, key, mark_challenge_consumed,
    prune_challenge_source_buckets_before, prune_challenges_before, upsert_key,
};

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
    pub publish_cadence_seconds: Option<i64>,
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
    pub poll_interval_seconds: i64,
    pub publish_cadence_seconds: Option<i64>,
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

const INSERT_PENDING_FEED_SQL: &str = "INSERT INTO feeds \
         (feed_url, source_url, poll_interval_seconds, consecutive_failures, created_at, updated_at) \
         VALUES (?1, ?2, ?3, 0, ?4, ?4) \
         ON CONFLICT(feed_url) DO NOTHING";

const ESTABLISH_FEED_BASELINE_SQL: &str =
    "UPDATE feeds SET baseline_established_at = ?1 WHERE feed_url = ?2 AND baseline_established_at IS NULL";

const PRUNE_PUSH_SEND_ATTEMPTS_SQL: &str = "DELETE FROM push_send_attempts WHERE created_at < ?1";

const GC_DELETED_SUBSCRIPTIONS_SQL: &str =
    "DELETE FROM feed_subscriptions WHERE deleted_at IS NOT NULL AND deleted_at < ?1";

// A feed is GC-eligible only while no live (deleted_at IS NULL) subscription
// row references it, regardless of that subscription's notification flag —
// a disabled subscription can re-enable and still needs its feed.
const UNSUBSCRIBED_FEED_GC_CANDIDATES_SQL: &str = "SELECT feed_url FROM feeds \
         WHERE updated_at < ?1 \
           AND NOT EXISTS ( \
             SELECT 1 \
             FROM feed_subscriptions \
             WHERE feed_subscriptions.feed_url = feeds.feed_url \
               AND feed_subscriptions.deleted_at IS NULL \
           ) \
         ORDER BY updated_at \
         LIMIT ?2";

const DELETE_SENDS_FOR_FEED_SQL: &str =
    "DELETE FROM episode_notification_sends WHERE feed_url = ?1";

const DELETE_FEED_ROW_SQL: &str = "DELETE FROM feeds WHERE feed_url = ?1";

// The scheduled drain's optimistic per-feed claim reuses `next_poll_at` as a
// lease, so the claim's WHERE clause must byte-match the due scan's
// dueness predicate — both branches, including the IS NULL never-polled arm.
// Both SQL constants are assembled at compile time from the shared predicate
// so they cannot silently diverge; the identity test below pins it.
const DUE_FEED_PREDICATE_SQL: &str = "(next_poll_at IS NULL OR next_poll_at <= ?1)";

const fn concat_len(parts: &[&str]) -> usize {
    let mut length = 0;
    let mut index = 0;
    while index < parts.len() {
        length += parts[index].len();
        index += 1;
    }
    length
}

const fn concat_bytes<const N: usize>(parts: &[&str]) -> [u8; N] {
    let mut out = [0_u8; N];
    let mut offset = 0;
    let mut index = 0;
    while index < parts.len() {
        let bytes = parts[index].as_bytes();
        let mut byte_index = 0;
        while byte_index < bytes.len() {
            out[offset] = bytes[byte_index];
            offset += 1;
            byte_index += 1;
        }
        index += 1;
    }
    out
}

const fn concat_str(bytes: &[u8]) -> &str {
    match std::str::from_utf8(bytes) {
        Ok(sql) => sql,
        Err(_) => panic!("assembled feed-poll SQL must be UTF-8"),
    }
}

const DUE_FEED_ROWS_SQL_PARTS: &[&str] = &[
    "SELECT feed_url, source_url, etag, last_modified, latest_episode_id, latest_episode_title, latest_episode_published_at, baseline_established_at, consecutive_failures, publish_cadence_seconds \
         FROM feeds \
         WHERE ",
    DUE_FEED_PREDICATE_SQL,
    " AND EXISTS ( \
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
         LIMIT ?3",
];
const DUE_FEED_ROWS_SQL_BYTES: [u8; concat_len(DUE_FEED_ROWS_SQL_PARTS)] =
    concat_bytes(DUE_FEED_ROWS_SQL_PARTS);
const DUE_FEED_ROWS_SQL: &str = concat_str(&DUE_FEED_ROWS_SQL_BYTES);

const CLAIM_DUE_FEED_SQL_PARTS: &[&str] = &[
    "UPDATE feeds SET next_poll_at = ?2 WHERE feed_url = ?3 AND ",
    DUE_FEED_PREDICATE_SQL,
];
const CLAIM_DUE_FEED_SQL_BYTES: [u8; concat_len(CLAIM_DUE_FEED_SQL_PARTS)] =
    concat_bytes(CLAIM_DUE_FEED_SQL_PARTS);
const CLAIM_DUE_FEED_SQL: &str = concat_str(&CLAIM_DUE_FEED_SQL_BYTES);

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

const ENABLED_DEVICE_COUNT_SQL: &str = "SELECT COUNT(*) AS count \
         FROM devices \
         WHERE install_id = ?1 \
           AND apns_environment = ?2 \
           AND bundle_id = ?3 \
           AND notifications_enabled = 1";

const DELETE_SUPERSEDED_DEVICES_SQL: &str = "DELETE FROM devices \
         WHERE install_id = ?1 \
           AND apns_environment = ?2 \
           AND bundle_id = ?3 \
           AND device_token_hash <> ?4";

const DELETE_PUSH_SEND_ATTEMPTS_FOR_INSTALL_SQL: &str =
    "DELETE FROM push_send_attempts WHERE install_id = ?1";
const DELETE_SECURE_ATTEMPTS_FOR_INSTALL_SQL: &str =
    "DELETE FROM secure_hello_attempts WHERE install_id = ?1";

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

pub async fn prune_secure_attempts_before(db: &D1Database, cutoff: i64) -> Result<usize> {
    let args = [d1_i64(cutoff)];
    let result = db
        .prepare("DELETE FROM secure_hello_attempts WHERE created_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(result.meta()?.and_then(|meta| meta.changes).unwrap_or(0))
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
        D1Type::Text(device.install_id),
        D1Type::Text(device.apns_environment),
        D1Type::Text(device.bundle_id),
        D1Type::Text(device.device_token_hash),
    ];
    db.prepare(DELETE_SUPERSEDED_DEVICES_SQL)
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

pub async fn enabled_device_count_for_install(
    db: &D1Database,
    install_id: &str,
    apns_environment: &str,
    bundle_id: &str,
) -> Result<i64> {
    let args = [
        D1Type::Text(install_id),
        D1Type::Text(apns_environment),
        D1Type::Text(bundle_id),
    ];
    let row = db
        .prepare(ENABLED_DEVICE_COUNT_SQL)
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

/// Enqueues a pending-admission feed: a row with no fetched baseline
/// (`baseline_established_at` and `next_poll_at` both NULL), which the
/// scheduled tick admits with its first real fetch — NULL sorts ahead of
/// every scheduled feed in the due scan's COALESCE order. Racing enqueues
/// (or an already-admitted feed) leave the existing row untouched.
pub async fn insert_pending_feed(
    db: &D1Database,
    feed_url: &str,
    source_url: &str,
    poll_interval_seconds: i64,
    now: i64,
) -> Result<()> {
    let args = [
        D1Type::Text(feed_url),
        D1Type::Text(source_url),
        d1_i64(poll_interval_seconds),
        d1_i64(now),
    ];
    db.prepare(INSERT_PENDING_FEED_SQL)
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

/// Arms the back-catalog guard after a pending feed's first successful
/// admission poll; feeds with an established baseline are untouched.
pub async fn establish_feed_baseline(db: &D1Database, feed_url: &str, now: i64) -> Result<()> {
    let args = [d1_i64(now), D1Type::Text(feed_url)];
    db.prepare(ESTABLISH_FEED_BASELINE_SQL)
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
            DELETE_PUSH_SEND_ATTEMPTS_FOR_INSTALL_SQL,
            "DELETE FROM feed_admission_attempts WHERE install_id = ?1",
            "DELETE FROM feed_subscriptions WHERE install_id = ?1",
            "DELETE FROM devices WHERE install_id = ?1",
            DELETE_SECURE_ATTEMPTS_FOR_INSTALL_SQL,
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

pub async fn prune_feed_admission_attempts_before(db: &D1Database, cutoff: i64) -> Result<usize> {
    let args = [d1_i64(cutoff)];
    let result = db
        .prepare("DELETE FROM feed_admission_attempts WHERE created_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(result.meta()?.and_then(|meta| meta.changes).unwrap_or(0))
}

pub async fn prune_push_send_attempts_before(db: &D1Database, cutoff: i64) -> Result<usize> {
    let args = [d1_i64(cutoff)];
    let result = db
        .prepare(PRUNE_PUSH_SEND_ATTEMPTS_SQL)
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(result.meta()?.and_then(|meta| meta.changes).unwrap_or(0))
}

/// Hard-deletes subscription rows soft-deleted before `cutoff`. Resubscribing
/// after the GC is free: the feed row survives (only zero-subscriber feeds
/// age out separately), so sync re-accepts without a new-feed admission.
pub async fn gc_deleted_subscriptions_before(db: &D1Database, cutoff: i64) -> Result<usize> {
    let args = [d1_i64(cutoff)];
    let result = db
        .prepare(GC_DELETED_SUBSCRIPTIONS_SQL)
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(result.meta()?.and_then(|meta| meta.changes).unwrap_or(0))
}

#[derive(Default)]
pub struct UnsubscribedFeedGcCounts {
    pub feeds_deleted: usize,
    pub sends_deleted: usize,
}

/// Deletes stale zero-subscriber feed rows in bounded batches, sweeping each
/// GC'd feed's episode_notification_sends rows in the same atomic batch.
/// The sends sweep is scoped to the feeds GC'd in this pass — never
/// age-based — because send rows are the notification dedupe ledger and must
/// outlive any feed that can still notify.
pub async fn gc_unsubscribed_feeds(
    db: &D1Database,
    cutoff: i64,
    limit: i64,
) -> Result<UnsubscribedFeedGcCounts> {
    #[derive(Deserialize)]
    struct FeedUrlRow {
        feed_url: String,
    }

    let args = [d1_i64(cutoff), d1_i64(limit)];
    let candidates: Vec<FeedUrlRow> = db
        .prepare(UNSUBSCRIBED_FEED_GC_CANDIDATES_SQL)
        .bind_refs(&args)?
        .all()
        .await?
        .results()?;
    let mut counts = UnsubscribedFeedGcCounts::default();
    if candidates.is_empty() {
        return Ok(counts);
    }

    let mut statements = Vec::with_capacity(candidates.len() * 2);
    for row in &candidates {
        let url_arg = [D1Type::Text(&row.feed_url)];
        statements.push(db.prepare(DELETE_SENDS_FOR_FEED_SQL).bind_refs(&url_arg)?);
        statements.push(db.prepare(DELETE_FEED_ROW_SQL).bind_refs(&url_arg)?);
    }
    for (index, result) in db.batch(statements).await?.iter().enumerate() {
        let changes = result.meta()?.and_then(|meta| meta.changes).unwrap_or(0);
        if index % 2 == 0 {
            counts.sends_deleted += changes;
        } else {
            counts.feeds_deleted += changes;
        }
    }

    Ok(counts)
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

/// Optimistically claims a due feed for one scheduled invocation by leasing
/// `next_poll_at` forward. Exactly one overlapping invocation wins
/// (`rows_written == 1`); losers skip the feed. Every completion path
/// overwrites the lease with the real schedule, and a claimed-then-crashed
/// feed self-heals when the lease expires one poll interval later.
pub async fn claim_due_feed(
    db: &D1Database,
    feed_url: &str,
    now: i64,
    lease_until: i64,
) -> Result<bool> {
    let args = [d1_i64(now), d1_i64(lease_until), D1Type::Text(feed_url)];
    let result = db
        .prepare(CLAIM_DUE_FEED_SQL)
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(changed_exactly_one_row(
        result.meta()?.and_then(|meta| meta.changes),
    ))
}

pub async fn subscribed_feed_rows(db: &D1Database, install_id: &str) -> Result<Vec<FeedPollRow>> {
    let args = [D1Type::Text(install_id)];
    db.prepare(
        "SELECT feeds.feed_url, feeds.source_url, feeds.etag, feeds.last_modified, feeds.latest_episode_id, feeds.latest_episode_title, feeds.latest_episode_published_at, feeds.baseline_established_at, feeds.consecutive_failures, feeds.publish_cadence_seconds \
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
        "SELECT feeds.feed_url, feeds.source_url, feeds.etag, feeds.last_modified, feeds.latest_episode_id, feeds.latest_episode_title, feeds.latest_episode_published_at, feeds.baseline_established_at, feeds.consecutive_failures, feeds.publish_cadence_seconds \
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
        "SELECT feed_url, source_url, etag, last_modified, latest_episode_id, latest_episode_title, latest_episode_published_at, baseline_established_at, consecutive_failures, publish_cadence_seconds \
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
    poll_interval_seconds: i64,
    now: i64,
) -> Result<()> {
    let args = [
        d1_i64(now),
        d1_i64(next_poll_at),
        d1_i64(poll_interval_seconds),
        D1Type::Text(feed_url),
    ];
    db.prepare(
        "UPDATE feeds \
         SET last_polled_at = ?1, next_poll_at = ?2, poll_interval_seconds = ?3, consecutive_failures = 0, last_http_status = 304, last_error = NULL, updated_at = ?1 \
         WHERE feed_url = ?4",
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
    let publish_cadence_seconds = success
        .publish_cadence_seconds
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
        d1_i64(success.poll_interval_seconds),
        publish_cadence_seconds,
        D1Type::Text(success.feed_url),
    ];

    db.prepare(
        "UPDATE feeds \
         SET title = ?1, website_url = ?2, etag = ?3, last_modified = ?4, latest_episode_id = ?5, latest_episode_title = ?6, latest_episode_published_at = ?7, last_polled_at = ?8, next_poll_at = ?9, consecutive_failures = 0, last_http_status = ?10, poll_interval_seconds = ?11, publish_cadence_seconds = ?12, last_error = NULL, updated_at = ?8 \
         WHERE feed_url = ?13",
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
    const TEST_BUNDLE_ID: &str = "com.connor.opencast";

    fn setup_db() -> Connection {
        let db = Connection::open_in_memory().expect("open in-memory sqlite");
        apply_migrations_through_0007(&db);
        db.execute_batch(include_str!(
            "../migrations/0008_cleanup_superseded_device_tokens.sql"
        ))
        .expect("cleanup superseded devices");
        db.execute_batch(include_str!(
            "../migrations/0009_delete_dead_device_rows.sql"
        ))
        .expect("delete dead device rows");
        db.execute_batch(include_str!(
            "../migrations/0010_index_feeds_next_poll_at.sql"
        ))
        .expect("index feed poll schedule");
        db.execute_batch(include_str!("../migrations/0011_feed_publish_cadence.sql"))
            .expect("add publish cadence column");
        db.execute_batch(include_str!("../migrations/0012_admin_history_indexes.sql"))
            .expect("create admin history indexes");
        db.execute_batch(include_str!(
            "../migrations/0013_install_delete_indexes.sql"
        ))
        .expect("create install deletion indexes");
        db
    }

    fn query_plan(db: &Connection, sql: &str) -> Vec<String> {
        let mut statement = db
            .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
            .expect("prepare query plan");
        statement
            .query_map(params!["install-a"], |row| row.get::<_, String>(3))
            .expect("query plan")
            .collect::<Result<Vec<_>, _>>()
            .expect("read query plan")
    }

    #[test]
    fn install_delete_uses_indexes_for_global_attempt_tables() {
        let db = setup_db();
        let push_plan = query_plan(&db, DELETE_PUSH_SEND_ATTEMPTS_FOR_INSTALL_SQL);
        assert!(
            push_plan
                .iter()
                .any(|detail| detail.contains("idx_push_send_attempts_install")),
            "expected push-attempt install index: {push_plan:?}"
        );

        let secure_plan = query_plan(&db, DELETE_SECURE_ATTEMPTS_FOR_INSTALL_SQL);
        assert!(
            secure_plan
                .iter()
                .any(|detail| detail.contains("idx_secure_hello_attempts_install")),
            "expected secure-attempt install index: {secure_plan:?}"
        );
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
        insert_device_row(
            db,
            install_id,
            &format!("token-{device_token_hash}"),
            device_token_hash,
            apns_environment,
            TEST_BUNDLE_ID,
            notifications_enabled,
            last_seen_at,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_device_row(
        db: &Connection,
        install_id: &str,
        device_token: &str,
        device_token_hash: &str,
        apns_environment: &str,
        bundle_id: &str,
        notifications_enabled: bool,
        last_seen_at: i64,
    ) {
        db.execute(
            "INSERT INTO devices \
             (install_id, key_id, device_token, device_token_hash, apns_environment, bundle_id, notifications_enabled, created_at, last_seen_at) \
             VALUES (?1, 'key', ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
            params![
                install_id,
                device_token,
                device_token_hash,
                apns_environment,
                bundle_id,
                i32::from(notifications_enabled),
                last_seen_at
            ],
        )
        .expect("insert device");
    }

    fn insert_rotated_away_device(db: &Connection, install_id: &str, device_token_hash: &str) {
        insert_device_row(
            db,
            install_id,
            "",
            device_token_hash,
            CURRENT_APNS_ENVIRONMENT,
            TEST_BUNDLE_ID,
            false,
            NOW - 100,
        );
    }

    fn enabled_device_count(
        db: &Connection,
        install_id: &str,
        apns_environment: &str,
        bundle_id: &str,
    ) -> i64 {
        db.query_row(
            ENABLED_DEVICE_COUNT_SQL,
            params![install_id, apns_environment, bundle_id],
            |row| row.get(0),
        )
        .expect("count enabled devices")
    }

    fn delete_superseded_devices(
        db: &Connection,
        install_id: &str,
        apns_environment: &str,
        bundle_id: &str,
        device_token_hash: &str,
    ) {
        db.execute(
            DELETE_SUPERSEDED_DEVICES_SQL,
            params![install_id, apns_environment, bundle_id, device_token_hash],
        )
        .expect("delete superseded devices");
    }

    fn device_hashes_for_scope(
        db: &Connection,
        install_id: &str,
        apns_environment: &str,
        bundle_id: &str,
    ) -> Vec<String> {
        let mut statement = db
            .prepare(
                "SELECT device_token_hash FROM devices \
                 WHERE install_id = ?1 AND apns_environment = ?2 AND bundle_id = ?3 \
                 ORDER BY device_token_hash",
            )
            .expect("prepare device-hash query");
        statement
            .query_map(params![install_id, apns_environment, bundle_id], |row| {
                row.get::<_, String>(0)
            })
            .expect("query device hashes")
            .collect::<Result<Vec<_>, _>>()
            .expect("read device hashes")
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
    fn claim_predicate_byte_matches_the_due_scan_predicate() {
        // Both constants are assembled from DUE_FEED_PREDICATE_SQL, so this
        // pins the shared bytes (and both dueness arms) against manual edits
        // to either SQL string.
        assert!(DUE_FEED_ROWS_SQL.contains(DUE_FEED_PREDICATE_SQL));
        assert!(CLAIM_DUE_FEED_SQL.contains(DUE_FEED_PREDICATE_SQL));
        assert!(DUE_FEED_PREDICATE_SQL.contains("next_poll_at IS NULL"));
        assert!(DUE_FEED_PREDICATE_SQL.contains("next_poll_at <= ?1"));
    }

    #[test]
    fn due_feed_claim_wins_once_and_releases_when_the_lease_expires() {
        let db = setup_db();
        let feed_url = "https://example.com/claim.xml";
        insert_feed(&db, feed_url, Some(NOW - 1), NOW);
        activate_feed(&db, feed_url, "install-a");

        let claimed = db
            .execute(CLAIM_DUE_FEED_SQL, params![NOW, NOW + 900, feed_url])
            .expect("first claim");
        assert_eq!(claimed, 1);

        let overlapped = db
            .execute(CLAIM_DUE_FEED_SQL, params![NOW, NOW + 900, feed_url])
            .expect("overlapping claim");
        assert_eq!(overlapped, 0);

        // The leased feed also disappears from an overlapping tick's due scan,
        // and self-heals into both the scan and the claim once the lease ends.
        assert!(due_feed_urls(&db, NOW, 50, CURRENT_APNS_ENVIRONMENT).is_empty());
        assert_eq!(
            due_feed_urls(&db, NOW + 900, 50, CURRENT_APNS_ENVIRONMENT),
            vec![feed_url.to_string()]
        );
        let reclaimed = db
            .execute(CLAIM_DUE_FEED_SQL, params![NOW + 900, NOW + 1800, feed_url])
            .expect("post-lease claim");
        assert_eq!(reclaimed, 1);
    }

    #[test]
    fn due_feed_claim_covers_the_never_polled_null_arm() {
        let db = setup_db();
        let feed_url = "https://example.com/never-polled.xml";
        insert_feed(&db, feed_url, None, NOW);
        activate_feed(&db, feed_url, "install-a");

        let claimed = db
            .execute(CLAIM_DUE_FEED_SQL, params![NOW, NOW + 900, feed_url])
            .expect("claim never-polled feed");
        assert_eq!(claimed, 1);
    }

    fn insert_push_send_attempt_row(db: &Connection, attempt_id: &str, created_at: i64) {
        db.execute(
            "INSERT INTO push_send_attempts \
             (attempt_id, install_id, apns_environment, created_at) \
             VALUES (?1, 'install-a', 'production', ?2)",
            params![attempt_id, created_at],
        )
        .expect("insert push send attempt");
    }

    fn insert_send_for_feed(db: &Connection, send_id: &str, feed_url: &str) {
        db.execute(
            "INSERT INTO episode_notification_sends \
             (send_id, install_id, device_token_hash, feed_url, episode_id, apns_environment, created_at, updated_at) \
             VALUES (?1, 'install-a', 'token-a', ?2, 'episode-1', 'production', ?3, ?3)",
            params![send_id, feed_url, NOW],
        )
        .expect("insert episode send for feed");
    }

    fn gc_unsubscribed_feeds_sync(db: &Connection, cutoff: i64, limit: i64) -> (usize, usize) {
        let mut statement = db
            .prepare(UNSUBSCRIBED_FEED_GC_CANDIDATES_SQL)
            .expect("prepare feed GC candidates");
        let candidates = statement
            .query_map(params![cutoff, limit], |row| row.get::<_, String>(0))
            .expect("query feed GC candidates")
            .collect::<Result<Vec<_>, _>>()
            .expect("read feed GC candidates");

        let mut feeds_deleted = 0;
        let mut sends_deleted = 0;
        for feed_url in &candidates {
            sends_deleted += db
                .execute(DELETE_SENDS_FOR_FEED_SQL, params![feed_url])
                .expect("sweep sends for GC'd feed");
            feeds_deleted += db
                .execute(DELETE_FEED_ROW_SQL, params![feed_url])
                .expect("delete GC'd feed");
        }
        (feeds_deleted, sends_deleted)
    }

    fn remaining_feed_urls(db: &Connection) -> Vec<String> {
        let mut statement = db
            .prepare("SELECT feed_url FROM feeds ORDER BY feed_url")
            .expect("prepare remaining feeds");
        statement
            .query_map([], |row| row.get::<_, String>(0))
            .expect("query remaining feeds")
            .collect::<Result<Vec<_>, _>>()
            .expect("read remaining feeds")
    }

    #[test]
    fn pending_feed_sorts_ahead_of_scheduled_feeds_in_the_due_scan() {
        let db = setup_db();
        insert_feed(&db, "https://example.com/scheduled.xml", Some(NOW - 1), NOW);
        activate_feed(&db, "https://example.com/scheduled.xml", "install-a");
        db.execute(
            INSERT_PENDING_FEED_SQL,
            params![
                "https://example.com/pending.xml",
                "https://example.com/pending.xml",
                900,
                NOW
            ],
        )
        .expect("insert pending feed");
        activate_feed(&db, "https://example.com/pending.xml", "install-b");

        assert_eq!(
            due_feed_urls(&db, NOW, 50, CURRENT_APNS_ENVIRONMENT),
            vec![
                "https://example.com/pending.xml",
                "https://example.com/scheduled.xml"
            ]
        );
    }

    #[test]
    fn pending_feed_insert_never_touches_an_existing_feed_row() {
        let db = setup_db();
        let feed_url = "https://example.com/existing.xml";
        insert_feed(&db, feed_url, Some(NOW + 500), NOW - 50);

        let inserted = db
            .execute(
                INSERT_PENDING_FEED_SQL,
                params![feed_url, feed_url, 900, NOW],
            )
            .expect("conflicting pending insert");

        assert_eq!(inserted, 0);
        let (next_poll_at, updated_at): (Option<i64>, i64) = db
            .query_row(
                "SELECT next_poll_at, updated_at FROM feeds WHERE feed_url = ?1",
                params![feed_url],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("read existing feed row");
        assert_eq!(next_poll_at, Some(NOW + 500));
        assert_eq!(updated_at, NOW - 50);
    }

    #[test]
    fn feed_baseline_establishes_once_and_only_when_absent() {
        let db = setup_db();
        let feed_url = "https://example.com/baseline.xml";
        db.execute(
            INSERT_PENDING_FEED_SQL,
            params![feed_url, feed_url, 900, NOW],
        )
        .expect("insert pending feed");

        let armed = db
            .execute(ESTABLISH_FEED_BASELINE_SQL, params![NOW + 10, feed_url])
            .expect("establish baseline");
        assert_eq!(armed, 1);

        let rearmed = db
            .execute(ESTABLISH_FEED_BASELINE_SQL, params![NOW + 99, feed_url])
            .expect("re-establish baseline");
        assert_eq!(rearmed, 0);
        let baseline: i64 = db
            .query_row(
                "SELECT baseline_established_at FROM feeds WHERE feed_url = ?1",
                params![feed_url],
                |row| row.get(0),
            )
            .expect("read baseline");
        assert_eq!(baseline, NOW + 10);
    }

    #[test]
    fn push_send_attempt_prune_honors_the_retention_boundary() {
        let db = setup_db();
        insert_push_send_attempt_row(&db, "attempt-old", NOW - 10);
        insert_push_send_attempt_row(&db, "attempt-boundary", NOW - 5);
        insert_push_send_attempt_row(&db, "attempt-fresh", NOW - 1);

        let pruned = db
            .execute(PRUNE_PUSH_SEND_ATTEMPTS_SQL, params![NOW - 5])
            .expect("prune push send attempts");

        assert_eq!(pruned, 1);
        let remaining: i64 = db
            .query_row("SELECT COUNT(*) FROM push_send_attempts", [], |row| {
                row.get(0)
            })
            .expect("count remaining push send attempts");
        assert_eq!(remaining, 2);
    }

    #[test]
    fn deleted_subscription_gc_honors_boundary_and_spares_live_rows() {
        let db = setup_db();
        let feed_url = "https://example.com/sub-gc.xml";
        insert_feed(&db, feed_url, Some(NOW - 1), NOW);
        insert_subscription(&db, "install-live", feed_url, true, None);
        insert_subscription(&db, "install-old", feed_url, false, Some(NOW - 10));
        insert_subscription(&db, "install-boundary", feed_url, false, Some(NOW - 5));

        let collected = db
            .execute(GC_DELETED_SUBSCRIPTIONS_SQL, params![NOW - 5])
            .expect("gc soft-deleted subscriptions");

        assert_eq!(collected, 1);
        let remaining: Vec<String> = {
            let mut statement = db
                .prepare("SELECT install_id FROM feed_subscriptions ORDER BY install_id")
                .expect("prepare remaining subscriptions");
            statement
                .query_map([], |row| row.get(0))
                .expect("query remaining subscriptions")
                .collect::<Result<Vec<_>, _>>()
                .expect("read remaining subscriptions")
        };
        assert_eq!(remaining, vec!["install-boundary", "install-live"]);
    }

    #[test]
    fn unsubscribed_feed_gc_spares_live_and_recent_feeds_and_sweeps_only_gcd_sends() {
        let db = setup_db();
        // Stale with no subscriptions at all: GC'd, sends swept.
        insert_feed(&db, "https://example.com/stale.xml", None, NOW - 100);
        insert_send_for_feed(&db, "send-stale", "https://example.com/stale.xml");
        // Stale but still referenced by a live (even disabled) subscription.
        insert_feed(&db, "https://example.com/live-sub.xml", None, NOW - 100);
        insert_subscription(
            &db,
            "install-a",
            "https://example.com/live-sub.xml",
            false,
            None,
        );
        insert_send_for_feed(&db, "send-live", "https://example.com/live-sub.xml");
        // Zero subscribers but recently updated.
        insert_feed(&db, "https://example.com/recent.xml", None, NOW - 1);
        // Stale and only referenced by a soft-deleted subscription: GC'd.
        insert_feed(&db, "https://example.com/soft-deleted.xml", None, NOW - 100);
        insert_subscription(
            &db,
            "install-b",
            "https://example.com/soft-deleted.xml",
            false,
            Some(NOW - 1),
        );

        let (feeds_deleted, sends_deleted) = gc_unsubscribed_feeds_sync(&db, NOW - 50, 10);

        assert_eq!(feeds_deleted, 2);
        assert_eq!(sends_deleted, 1);
        assert_eq!(
            remaining_feed_urls(&db),
            vec![
                "https://example.com/live-sub.xml",
                "https://example.com/recent.xml"
            ]
        );
        // The dedupe ledger for the surviving feed is untouched.
        let remaining_sends: Vec<String> = {
            let mut statement = db
                .prepare("SELECT send_id FROM episode_notification_sends")
                .expect("prepare remaining sends");
            statement
                .query_map([], |row| row.get(0))
                .expect("query remaining sends")
                .collect::<Result<Vec<_>, _>>()
                .expect("read remaining sends")
        };
        assert_eq!(remaining_sends, vec!["send-live"]);
    }

    #[test]
    fn unsubscribed_feed_gc_drains_a_backlog_in_bounded_oldest_first_batches() {
        let db = setup_db();
        insert_feed(&db, "https://example.com/oldest.xml", None, NOW - 300);
        insert_feed(&db, "https://example.com/older.xml", None, NOW - 200);
        insert_feed(&db, "https://example.com/old.xml", None, NOW - 100);

        let (first_pass, _) = gc_unsubscribed_feeds_sync(&db, NOW - 50, 2);
        assert_eq!(first_pass, 2);
        assert_eq!(
            remaining_feed_urls(&db),
            vec!["https://example.com/old.xml"]
        );

        let (second_pass, _) = gc_unsubscribed_feeds_sync(&db, NOW - 50, 2);
        assert_eq!(second_pass, 1);
        assert!(remaining_feed_urls(&db).is_empty());
    }

    #[test]
    fn feed_poll_schedule_index_migration_is_idempotent() {
        let db = setup_db();

        db.execute_batch(include_str!(
            "../migrations/0010_index_feeds_next_poll_at.sql"
        ))
        .expect("reapply feed poll schedule index");

        let index_count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_feeds_next_poll_at'",
                [],
                |row| row.get(0),
            )
            .expect("count feed poll schedule index");
        assert_eq!(index_count, 1);
    }

    #[test]
    fn scheduled_feed_poll_uses_indexes_instead_of_scanning_feed_tables() {
        let db = setup_db();
        let mut statement = db
            .prepare(&format!("EXPLAIN QUERY PLAN {DUE_FEED_ROWS_SQL}"))
            .expect("prepare scheduled feed query plan");
        let plan = statement
            .query_map(params![NOW, CURRENT_APNS_ENVIRONMENT, 50_i64], |row| {
                row.get::<_, String>(3)
            })
            .expect("query scheduled feed plan")
            .collect::<Result<Vec<_>, _>>()
            .expect("read scheduled feed plan");

        for expected_index in [
            "idx_feeds_next_poll_at",
            "idx_feed_subscriptions_feed_enabled",
            "idx_devices_install",
        ] {
            assert!(
                plan.iter().any(|detail| detail.contains(expected_index)),
                "expected {expected_index} in scheduled feed plan: {plan:?}"
            );
        }
        assert!(
            plan.iter().all(|detail| !detail.starts_with("SCAN ")),
            "unexpected full scan in scheduled feed plan: {plan:?}"
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
    fn enabled_device_count_ignores_rotated_away_rows() {
        let db = setup_db();
        for index in 0..4 {
            insert_rotated_away_device(&db, "install-a", &format!("dead-{index}"));
        }
        insert_device(
            &db,
            "install-a",
            "live-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
        );

        let total_rows: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM devices WHERE install_id = 'install-a'",
                [],
                |row| row.get(0),
            )
            .expect("count device rows");

        assert_eq!(total_rows, 5);
        assert_eq!(
            enabled_device_count(&db, "install-a", CURRENT_APNS_ENVIRONMENT, TEST_BUNDLE_ID),
            1
        );
    }

    #[test]
    fn enabled_device_count_scopes_install_environment_and_bundle() {
        let db = setup_db();
        insert_device(
            &db,
            "install-a",
            "prod-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
        );
        insert_device(&db, "install-a", "dev-token", OTHER_APNS_ENVIRONMENT, true);
        insert_device(
            &db,
            "install-b",
            "other-install",
            CURRENT_APNS_ENVIRONMENT,
            true,
        );
        insert_device_row(
            &db,
            "install-a",
            "token-other-bundle",
            "other-bundle",
            CURRENT_APNS_ENVIRONMENT,
            "com.other.bundle",
            true,
            NOW - 25,
        );

        assert_eq!(
            enabled_device_count(&db, "install-a", CURRENT_APNS_ENVIRONMENT, TEST_BUNDLE_ID),
            1
        );
    }

    #[test]
    fn delete_superseded_devices_keeps_only_current_token_row() {
        let db = setup_db();
        insert_rotated_away_device(&db, "install-a", "dead-1");
        insert_device_seen(
            &db,
            "install-a",
            "previous-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
            NOW - 60,
        );
        insert_device(&db, "install-a", "dev-token", OTHER_APNS_ENVIRONMENT, true);
        insert_device(
            &db,
            "install-b",
            "other-install",
            CURRENT_APNS_ENVIRONMENT,
            true,
        );

        insert_device_seen(
            &db,
            "install-a",
            "current-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
            NOW,
        );
        delete_superseded_devices(
            &db,
            "install-a",
            CURRENT_APNS_ENVIRONMENT,
            TEST_BUNDLE_ID,
            "current-token",
        );

        assert_eq!(
            device_hashes_for_scope(&db, "install-a", CURRENT_APNS_ENVIRONMENT, TEST_BUNDLE_ID),
            vec!["current-token"]
        );
        assert_eq!(
            enabled_device_count(&db, "install-a", OTHER_APNS_ENVIRONMENT, TEST_BUNDLE_ID),
            1
        );
        assert_eq!(
            enabled_device_count(&db, "install-b", CURRENT_APNS_ENVIRONMENT, TEST_BUNDLE_ID),
            1
        );

        insert_device_seen(
            &db,
            "install-a",
            "next-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
            NOW + 10,
        );
        delete_superseded_devices(
            &db,
            "install-a",
            CURRENT_APNS_ENVIRONMENT,
            TEST_BUNDLE_ID,
            "next-token",
        );

        assert_eq!(
            device_hashes_for_scope(&db, "install-a", CURRENT_APNS_ENVIRONMENT, TEST_BUNDLE_ID),
            vec!["next-token"]
        );
    }

    #[test]
    fn delete_dead_device_rows_migration_unbricks_install_and_is_idempotent() {
        let db = setup_db();
        for index in 0..4 {
            insert_rotated_away_device(&db, "install-a", &format!("dead-{index}"));
        }
        insert_device(
            &db,
            "install-a",
            "live-token",
            CURRENT_APNS_ENVIRONMENT,
            true,
        );
        // Disabled row that still holds a raw token: outside the migration's
        // blank-token predicate, so it must survive.
        insert_device(
            &db,
            "install-b",
            "held-token",
            CURRENT_APNS_ENVIRONMENT,
            false,
        );

        db.execute_batch(include_str!(
            "../migrations/0009_delete_dead_device_rows.sql"
        ))
        .expect("first delete");
        db.execute_batch(include_str!(
            "../migrations/0009_delete_dead_device_rows.sql"
        ))
        .expect("second delete");

        assert_eq!(
            device_hashes_for_scope(&db, "install-a", CURRENT_APNS_ENVIRONMENT, TEST_BUNDLE_ID),
            vec!["live-token"]
        );
        assert_eq!(
            device_hashes_for_scope(&db, "install-b", CURRENT_APNS_ENVIRONMENT, TEST_BUNDLE_ID),
            vec!["held-token"]
        );
    }

    #[test]
    #[should_panic]
    fn d1_i64_debug_asserts_values_outside_exact_js_integer_range() {
        let _ = d1_i64(9_007_199_254_740_992);
    }
}

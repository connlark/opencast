#![cfg_attr(all(test, not(target_arch = "wasm32")), allow(dead_code))]

use crate::d1_changes::changed_exactly_one_row;
use serde::Deserialize;
use std::collections::BTreeMap;
use worker::{D1Database, D1PreparedStatement, D1Type, Result};

// App Attest challenge/key storage lives in the shared core crate (one copy
// for AdAnalysisWorker, RemoteTranscriptionWorker, and this worker). This
// worker's App Attest schema arrived by its own migration lineage
// (0001_app_attest.sql plus later additions), but the challenge/key tables
// and every query against them are identical to the shared versions.
// wasm-only because the sole consumer (`worker_app`) is wasm-only.
#[cfg(target_arch = "wasm32")]
pub use opencast_app_attest_core::app_attest_storage::{
    app_attest_key_count_since, challenge, increment_challenge_source_bucket,
    insert_challenge_within_limits, key, mark_challenge_consumed,
    prune_challenge_source_buckets_before, prune_challenges_before,
};

#[derive(Debug, Deserialize)]
pub struct DeviceRow {
    pub device_token: String,
    pub device_token_hash: String,
}

#[derive(Debug, Deserialize)]
pub struct FeedSummaryRow {
    pub feed_url: String,
    pub title: Option<String>,
    #[serde(default)]
    pub consecutive_failures: i64,
    pub last_http_status: Option<i64>,
    pub last_error: Option<String>,
    pub last_polled_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct FeedSource {
    pub feed_url: String,
    pub source_url: String,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct InstallSubscriptionRow {
    pub feed_url: String,
}

#[derive(Debug, Deserialize)]
struct CountRow {
    count: i64,
}

#[derive(Debug, Deserialize)]
struct HostCountRow {
    host: String,
    count: i64,
}

pub struct DeviceUpsert<'a> {
    pub install_id: &'a str,
    pub key_id: &'a str,
    pub device_token: &'a str,
    pub device_token_hash: &'a str,
    pub apns_environment: &'a str,
    pub bundle_id: &'a str,
    pub notifications_enabled: bool,
    pub job_capable: bool,
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

const INSERT_PENDING_FEED_SQL: &str = "INSERT INTO n_feed_catalog \
         (feed_url, source_url, created_at, updated_at) \
         VALUES (?1, ?2, ?3, ?3) \
         ON CONFLICT(feed_url) DO NOTHING";

// Clients resend their whole subscription set on every sync. Rewriting an unchanged
// row costs a second write through `n_subscription_update`, so a live row is left
// alone until it is a day (86400 s) old. The daily rewrite keeps `updated_at` usable
// as "this installation synced" evidence and lets the trigger re-assert `n_interest`.
const UPSERT_FEED_SUBSCRIPTION_SQL: &str = "INSERT INTO feed_subscriptions \
         (install_id, feed_url, notifications_enabled, created_at, updated_at, deleted_at) \
         SELECT ?1, ?2, ?3, ?4, ?5, NULL WHERE EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=?1 AND key_id=?6) \
         ON CONFLICT(install_id, feed_url) DO UPDATE SET \
         created_at = CASE \
           WHEN feed_subscriptions.notifications_enabled = 1 AND feed_subscriptions.deleted_at IS NULL \
           THEN feed_subscriptions.created_at \
           ELSE excluded.created_at \
         END, \
         notifications_enabled = excluded.notifications_enabled, \
         updated_at = excluded.updated_at, \
         deleted_at = NULL \
         WHERE feed_subscriptions.notifications_enabled <> excluded.notifications_enabled \
            OR feed_subscriptions.deleted_at IS NOT NULL \
            OR feed_subscriptions.updated_at <= excluded.updated_at - 86400";

const MARK_SUBSCRIPTION_DELETED_SQL: &str = "UPDATE feed_subscriptions \
         SET notifications_enabled = 0, updated_at = ?1, deleted_at = ?1 \
         WHERE install_id = ?2 AND feed_url = ?3 AND deleted_at IS NULL AND EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=?2 AND key_id=?4)";

const INSERT_FEED_ADMISSION_ATTEMPT_SQL: &str = "INSERT INTO feed_admission_attempts \
         (attempt_id, install_id, key_id, host, accepted, error_code, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)";

/// D1 rejects statements binding more than 100 parameters, so IN-list
/// readers chunk their keys under that ceiling (leaving room for the fixed
/// bindings a query carries alongside the list).
pub const D1_MAX_BOUND_PARAMETERS: usize = 100;
pub const IN_LIST_CHUNK_KEYS: usize = 90;
// The host-count reader binds one fixed parameter ahead of its list.
const _: () = assert!(IN_LIST_CHUNK_KEYS < D1_MAX_BOUND_PARAMETERS);

fn in_list_placeholders(first_index: usize, count: usize) -> String {
    (first_index..first_index + count)
        .map(|index| format!("?{index}"))
        .collect::<Vec<_>>()
        .join(", ")
}

pub fn feed_summaries_sql(count: usize) -> String {
    format!(
        "SELECT c.feed_url, c.title, \
         CASE WHEN n.feed_id IS NOT NULL THEN n.poll_failures ELSE COALESCE(json_extract(c.admission_health_json,'$.consecutive_failures'),0) END AS consecutive_failures, \
         CASE WHEN n.feed_id IS NULL THEN json_extract(c.admission_health_json,'$.last_http_status') END AS last_http_status, \
         CASE WHEN n.feed_id IS NOT NULL THEN CASE WHEN n.poll_failures>0 THEN 'poll_failed' END ELSE json_extract(c.admission_health_json,'$.last_error') END AS last_error, \
         CASE WHEN n.feed_id IS NOT NULL THEN n.last_success_at ELSE json_extract(c.admission_health_json,'$.last_polled_at') END AS last_polled_at \
         FROM n_feed_catalog c LEFT JOIN n_feed n ON n.canonical_url=c.feed_url WHERE c.feed_url IN ({})",
        in_list_placeholders(1, count)
    )
}

pub fn accepted_admission_counts_for_hosts_since_sql(count: usize) -> String {
    format!(
        "SELECT host, COUNT(*) AS count \
         FROM feed_admission_attempts \
         WHERE accepted = 1 AND created_at >= ?1 AND host IN ({}) \
         GROUP BY host",
        in_list_placeholders(2, count)
    )
}

const PRUNE_PUSH_SEND_ATTEMPTS_SQL: &str = "DELETE FROM push_send_attempts WHERE created_at < ?1";

const GC_DELETED_SUBSCRIPTIONS_SQL: &str =
    "DELETE FROM feed_subscriptions WHERE deleted_at IS NOT NULL AND deleted_at < ?1";

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
        D1Type::Integer(i32::from(device.job_capable)),
    ];

    let upsert=db.prepare(
        "INSERT INTO devices \
         (install_id, key_id, device_token, device_token_hash, apns_environment, bundle_id, notifications_enabled, created_at, last_seen_at, job_capable) \
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10 WHERE EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=?1 AND key_id=?2) \
         ON CONFLICT(install_id, device_token_hash) DO UPDATE SET \
         key_id = excluded.key_id, \
         device_token = excluded.device_token, \
         apns_environment = excluded.apns_environment, \
         bundle_id = excluded.bundle_id, \
         notifications_enabled = excluded.notifications_enabled, \
         job_capable = excluded.job_capable, \
         last_seen_at = excluded.last_seen_at",
    )
    .bind_refs(&args)?;

    let cleanup_args = [
        D1Type::Text(device.install_id),
        D1Type::Text(device.apns_environment),
        D1Type::Text(device.bundle_id),
        D1Type::Text(device.device_token_hash),
        D1Type::Text(device.key_id),
    ];
    let cleanup = db
        .prepare(format!("{DELETE_SUPERSEDED_DEVICES_SQL} AND EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=?1 AND key_id=?5)"))
        .bind_refs(&cleanup_args)?;
    db.batch(vec![upsert, cleanup]).await?;

    Ok(())
}

pub fn disable_device_statement(
    db: &D1Database,
    install_id: &str,
    device_token_hash: &str,
    now: i64,
) -> Result<D1PreparedStatement> {
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
    .bind_refs(&args)
}

pub async fn disable_device(
    db: &D1Database,
    install_id: &str,
    device_token_hash: &str,
    now: i64,
) -> Result<()> {
    disable_device_statement(db, install_id, device_token_hash, now)?
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

pub async fn registration_ready(
    db: &D1Database,
    install_id: &str,
    apns_environment: &str,
    bundle_id: &str,
) -> Result<bool> {
    let row = db
        .prepare("SELECT COUNT(*) AS count FROM n_install i JOIN devices d ON d.install_id=i.install_id AND d.device_token_hash=i.token_hash WHERE i.install_id=?1 AND i.enabled=1 AND d.notifications_enabled=1 AND d.device_token<>'' AND d.apns_environment=?2 AND d.bundle_id=?3")
        .bind_refs(&[D1Type::Text(install_id), D1Type::Text(apns_environment), D1Type::Text(bundle_id)])?
        .first::<CountRow>(None)
        .await?;
    Ok(row.is_some_and(|row| row.count > 0))
}

pub async fn insert_push_send_attempt(
    db: &D1Database,
    attempt: PushSendAttemptInsert<'_>,
) -> Result<()> {
    insert_push_send_attempt_statement(db, attempt)?
        .run()
        .await?;

    Ok(())
}

pub fn insert_push_send_attempt_statement(
    db: &D1Database,
    attempt: PushSendAttemptInsert<'_>,
) -> Result<D1PreparedStatement> {
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
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8 WHERE ?2 IS NULL OR EXISTS(SELECT 1 FROM n_install WHERE install_id=?2)",
    )
    .bind_refs(&args)
}

/// Resolves the known feeds among `feed_urls` in IN-list chunks — one query
/// per `IN_LIST_CHUNK_KEYS` URLs instead of one per feed. Unknown URLs are
/// simply absent from the map.
pub async fn feed_summaries(
    db: &D1Database,
    feed_urls: &[&str],
) -> Result<BTreeMap<String, FeedSummaryRow>> {
    let mut summaries = BTreeMap::new();
    for chunk in feed_urls.chunks(IN_LIST_CHUNK_KEYS) {
        let args = chunk
            .iter()
            .map(|feed_url| D1Type::Text(feed_url))
            .collect::<Vec<_>>();
        let rows = db
            .prepare(feed_summaries_sql(chunk.len()))
            .bind_refs(&args)?
            .all()
            .await?
            .results::<FeedSummaryRow>()?;
        for row in rows {
            summaries.insert(row.feed_url.clone(), row);
        }
    }

    Ok(summaries)
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

/// Accepted-admission counts since `since`, grouped per host, in IN-list
/// chunks. Hosts without an accepted attempt in the window are absent.
pub async fn accepted_admission_counts_for_hosts_since(
    db: &D1Database,
    hosts: &[&str],
    since: i64,
) -> Result<BTreeMap<String, i64>> {
    let mut counts = BTreeMap::new();
    for chunk in hosts.chunks(IN_LIST_CHUNK_KEYS) {
        let mut args = Vec::with_capacity(chunk.len() + 1);
        args.push(d1_i64(since));
        args.extend(chunk.iter().map(|host| D1Type::Text(host)));
        let rows = db
            .prepare(accepted_admission_counts_for_hosts_since_sql(chunk.len()))
            .bind_refs(&args)?
            .all()
            .await?
            .results::<HostCountRow>()?;
        for row in rows {
            counts.insert(row.host, row.count);
        }
    }

    Ok(counts)
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

/// Records admission in the catalog; the feed's current authority schedules
/// its quiet first baseline. Racing inserts preserve the first source URL.
pub fn insert_pending_feed_statement(
    db: &D1Database,
    feed_url: &str,
    source_url: &str,
    now: i64,
) -> Result<D1PreparedStatement> {
    let args = [
        D1Type::Text(feed_url),
        D1Type::Text(source_url),
        d1_i64(now),
    ];
    db.prepare(INSERT_PENDING_FEED_SQL).bind_refs(&args)
}

/// Runs the subscription-sync write set as one D1 transaction. Each statement
/// still counts against D1's invocation query limit; an empty set is a no-op.
pub async fn run_write_batch(db: &D1Database, statements: Vec<D1PreparedStatement>) -> Result<()> {
    if statements.is_empty() {
        return Ok(());
    }
    db.batch(statements).await?;

    Ok(())
}

pub fn upsert_feed_subscription_statement(
    db: &D1Database,
    install_id: &str,
    feed_url: &str,
    notifications_enabled: bool,
    now: i64,
    key_id: &str,
) -> Result<D1PreparedStatement> {
    let args = [
        D1Type::Text(install_id),
        D1Type::Text(feed_url),
        D1Type::Integer(i32::from(notifications_enabled)),
        d1_i64(now),
        d1_i64(now),
        D1Type::Text(key_id),
    ];
    db.prepare(UPSERT_FEED_SUBSCRIPTION_SQL).bind_refs(&args)
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

pub fn mark_subscription_deleted_statement(
    db: &D1Database,
    install_id: &str,
    feed_url: &str,
    now: i64,
    key_id: &str,
) -> Result<D1PreparedStatement> {
    let args = [
        d1_i64(now),
        D1Type::Text(install_id),
        D1Type::Text(feed_url),
        D1Type::Text(key_id),
    ];
    db.prepare(MARK_SUBSCRIPTION_DELETED_SQL).bind_refs(&args)
}

pub async fn delete_install_data(
    db: &D1Database,
    install_id: &str,
    fence: &str,
    now: i64,
) -> Result<()> {
    let args = [D1Type::Text(install_id)];
    let mut writes=vec![db.prepare("INSERT INTO n_deleted_install(fence,expires_at) VALUES(?1,?2) ON CONFLICT(fence) DO NOTHING").bind_refs(&[D1Type::Text(fence),d1_i64(now+604800)])?];
    writes.push(
        db.prepare("UPDATE n_interest SET changed_at=?2 WHERE install_id=?1")
            .bind_refs(&[D1Type::Text(install_id), d1_i64(now)])?,
    );
    writes.extend([
            "DELETE FROM n_delivery_member WHERE install_id=?1",
            "DELETE FROM n_delivery WHERE install_id=?1",
            "DELETE FROM n_group_member WHERE (source,event_id) IN(SELECT source,event_id FROM n_event WHERE interest_id IN(SELECT interest_id FROM n_job_interest WHERE install_id=?1))",
            "DELETE FROM n_event WHERE interest_id IN(SELECT interest_id FROM n_job_interest WHERE install_id=?1)",
            "DELETE FROM n_requester_ticket WHERE EXISTS(SELECT 1 FROM n_job_interest j WHERE j.install_id=?1 AND j.operation_id=n_requester_ticket.operation_id AND j.requester_ref=n_requester_ticket.requester_ref AND j.producer=n_requester_ticket.producer)",
            "DELETE FROM n_job_interest WHERE install_id=?1",
            "DELETE FROM n_interest WHERE install_id=?1",
            "DELETE FROM n_legacy_bridge WHERE install_id=?1",
            "DELETE FROM n_install WHERE install_id=?1",
            "DELETE FROM n_delivery_history WHERE install_id = ?1",
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
        .collect::<Result<Vec<_>>>()?);
    db.batch(writes).await?;

    Ok(())
}

// Deletion removes the old challenge; fresh enrollment under the same install
// remains allowed, but a pre-deletion attestation continuation cannot restore it.
const UPSERT_KEY_FOR_CHALLENGE_SQL: &str = "INSERT INTO app_attest_keys(install_id,key_id,public_key,sign_counter,app_id,environment,created_at,last_used_at) SELECT ?1,?2,?3,0,?4,?5,?6,?6 WHERE EXISTS(SELECT 1 FROM app_attest_challenges WHERE challenge_id=?7 AND install_id=?1 AND purpose='register' AND consumed_at=?6 AND expires_at>=?6) ON CONFLICT(install_id,key_id) DO UPDATE SET public_key=excluded.public_key,app_id=excluded.app_id,environment=excluded.environment,last_used_at=excluded.last_used_at";

#[allow(clippy::too_many_arguments)]
pub async fn upsert_key_for_challenge(
    db: &D1Database,
    install_id: &str,
    key_id: &str,
    public_key: &[u8],
    app_id: &str,
    environment: &str,
    now: i64,
    challenge_id: &str,
) -> Result<bool> {
    let args = [
        D1Type::Text(install_id),
        D1Type::Text(key_id),
        D1Type::Blob(public_key),
        D1Type::Text(app_id),
        D1Type::Text(environment),
        d1_i64(now),
        D1Type::Text(challenge_id),
    ];
    let result = db
        .prepare(UPSERT_KEY_FOR_CHALLENGE_SQL)
        .bind_refs(&args)?
        .run()
        .await?;
    Ok(changed_exactly_one_row(
        result.meta()?.and_then(|m| m.changes),
    ))
}

pub fn insert_feed_admission_attempt_statement(
    db: &D1Database,
    attempt: FeedAdmissionAttemptInsert<'_>,
) -> Result<D1PreparedStatement> {
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
    db.prepare(INSERT_FEED_ADMISSION_ATTEMPT_SQL)
        .bind_refs(&args)
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

/// Resolves the installed client's source URL; queued validators live in n_feed.
pub async fn feed_source(db: &D1Database, feed_url: &str) -> Result<Option<FeedSource>> {
    let args = [D1Type::Text(feed_url)];
    db.prepare(
        "SELECT feed_url, source_url, NULL AS etag, NULL AS last_modified \
         FROM n_feed_catalog \
         WHERE feed_url = ?1 \
         LIMIT 1",
    )
    .bind_refs(&args)?
    .first::<FeedSource>(None)
    .await
}

fn d1_i64(value: i64) -> D1Type<'static> {
    // worker 0.8 binds D1 Integer as i32. Current counters are u32 and
    // timestamps are second-resolution Unix values, both exactly representable
    // below JS Number's 53-bit integer precision ceiling used by D1 Real.
    debug_assert!((-9_007_199_254_740_991..=9_007_199_254_740_991).contains(&value));
    D1Type::Real(value as f64)
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use rusqlite::{params, Connection};

    const NOW: i64 = 1_780_000_000;
    const CURRENT_APNS_ENVIRONMENT: &str = "production";
    const OTHER_APNS_ENVIRONMENT: &str = "development";
    const TEST_BUNDLE_ID: &str = "com.connor.opencast";

    #[test]
    fn fresh_registration_recovers_after_delete_without_reviving_a_deleted_challenge() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(include_str!("../migrations/0001_app_attest.sql"))
            .unwrap();
        db.execute_batch("CREATE TABLE n_deleted_install(fence TEXT,expires_at INTEGER); INSERT INTO n_deleted_install VALUES('retained',999999);").unwrap();
        let enroll = |challenge: &str| {
            db.execute(
                UPSERT_KEY_FOR_CHALLENGE_SQL,
                params![
                    "install",
                    "key",
                    vec![1u8],
                    "app",
                    "development",
                    100,
                    challenge
                ],
            )
            .unwrap()
        };
        assert_eq!(enroll("deleted-challenge"), 0);
        db.execute("INSERT INTO app_attest_challenges VALUES('fresh','digest','register','install',99,200,100)",[]).unwrap();
        assert_eq!(enroll("fresh"), 1);
        db.execute_batch("DELETE FROM app_attest_keys; DELETE FROM app_attest_challenges;")
            .unwrap();
        assert_eq!(enroll("fresh"), 0);
    }

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
        db.execute_batch(include_str!("../migrations/0015_feed_observations.sql"))
            .unwrap();
        db.execute_batch(include_str!("../migrations/0016_queued_polling.sql"))
            .unwrap();
        db.execute_batch(include_str!("../migrations/0017_episode_cutover.sql"))
            .unwrap();
        for migration in [
            include_str!("../migrations/0018_poll_cost_reset.sql"),
            include_str!("../migrations/0019_queued_enrollment.sql"),
            include_str!("../migrations/0020_recovery_retirement.sql"),
            include_str!("../migrations/0021_retire_migration_controls.sql"),
            include_str!("../migrations/0022_preserve_delivery_history.sql"),
            include_str!("../migrations/0023_drop_retired_notification_storage.sql"),
            include_str!("../migrations/0024_drop_recovery_pending.sql"),
            include_str!("../migrations/0025_current_schema_expansion.sql"),
            include_str!("../migrations/0026_current_schema_contraction.sql"),
        ] {
            db.execute_batch(migration).unwrap();
        }

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

    /// Pins this worker's migration schema against the shared atomic
    /// admission statement (cap predicates + insert in one statement); the
    /// full boundary matrix lives in AdAnalysisWorker's
    /// app_attest_migrations tests.
    #[test]
    fn migration_supports_atomic_challenge_admission() {
        use opencast_app_attest_core::app_attest::challenge_hash;
        use opencast_app_attest_core::app_attest_storage::INSERT_CHALLENGE_WITHIN_LIMITS_SQL;

        let db = setup_db();
        let admit = |challenge_id: &str, install_cap: i64| -> usize {
            db.execute(
                INSERT_CHALLENGE_WITHIN_LIMITS_SQL,
                params![
                    challenge_id,
                    challenge_hash(challenge_id),
                    "register",
                    "install-a",
                    NOW,
                    NOW + 600,
                    NOW - 3600,
                    install_cap,
                    1_000_i64
                ],
            )
            .expect("run atomic admission statement")
        };

        assert_eq!(admit("challenge-under-cap", 2), 1);
        assert_eq!(admit("challenge-at-cap", 2), 1);
        assert_eq!(admit("challenge-over-cap", 2), 0);
    }

    #[test]
    fn feed_summaries_select_the_health_columns_keyed_by_url() {
        let db = setup_db();
        insert_feed(&db, "https://example.com/f.xml", Some(NOW), NOW);
        db.execute(
            "UPDATE n_feed_catalog SET title='Show' WHERE feed_url='https://example.com/f.xml'",
            [],
        )
        .unwrap();
        db.execute("UPDATE n_feed SET poll_failures=3,last_success_at=1780000000 WHERE canonical_url='https://example.com/f.xml'", []).unwrap();
        insert_feed(&db, "https://example.com/other.xml", None, NOW);
        db.execute("UPDATE n_feed SET epoch=2,poll_failures=7,last_success_at=1780000010 WHERE canonical_url='https://example.com/other.xml'", []).unwrap();

        // Two known URLs plus an unknown one: the unknown URL is simply absent.
        let mut statement = db
            .prepare(&feed_summaries_sql(3))
            .expect("prepare feed summaries");
        let rows = statement
            .query_map(
                params![
                    "https://example.com/f.xml",
                    "https://example.com/missing.xml",
                    "https://example.com/other.xml"
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<i64>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<i64>>(5)?,
                    ))
                },
            )
            .expect("feed summary rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("read feed summary rows");

        assert_eq!(rows.len(), 2);
        let row = rows
            .iter()
            .find(|row| row.0 == "https://example.com/f.xml")
            .expect("seeded feed present");
        assert_eq!(row.1.as_deref(), Some("Show"));
        assert_eq!(row.2, 3);
        assert_eq!(row.3, None);
        assert_eq!(row.4.as_deref(), Some("poll_failed"));
        assert_eq!(row.5, Some(1_780_000_000));
        assert!(rows
            .iter()
            .any(|row| row.0 == "https://example.com/other.xml"));
        let queued = rows
            .iter()
            .find(|row| row.0 == "https://example.com/other.xml")
            .expect("queued feed present");
        assert_eq!(queued.2, 7);
        assert_eq!(queued.3, None);
        assert_eq!(queued.4.as_deref(), Some("poll_failed"));
        assert_eq!(queued.5, Some(1_780_000_010));
    }

    #[test]
    fn in_list_readers_stay_under_the_d1_parameter_ceiling_and_use_indexes() {
        assert_eq!(in_list_placeholders(1, 3), "?1, ?2, ?3");
        assert_eq!(in_list_placeholders(2, 2), "?2, ?3");

        let db = setup_db();
        let feed_plan = query_plan(&db, &feed_summaries_sql(1));
        assert!(
            feed_plan
                .iter()
                .any(|detail| detail
                    .contains("SEARCH c USING INDEX sqlite_autoindex_n_feed_catalog_1")),
            "expected the catalog primary key: {feed_plan:?}"
        );

        let host_sql = accepted_admission_counts_for_hosts_since_sql(1);
        let mut statement = db
            .prepare(&format!("EXPLAIN QUERY PLAN {host_sql}"))
            .expect("prepare host count plan");
        let host_plan = statement
            .query_map(params![NOW, "example.com"], |row| row.get::<_, String>(3))
            .expect("host count plan")
            .collect::<Result<Vec<_>, _>>()
            .expect("read host count plan");
        assert!(
            host_plan
                .iter()
                .any(|detail| detail.contains("idx_feed_admission_attempts_host_created")),
            "expected the host admission index: {host_plan:?}"
        );
    }

    #[test]
    fn host_admission_counts_group_accepted_attempts_inside_the_window() {
        let db = setup_db();
        let insert = |attempt_id: &str, host: &str, accepted: i64, created_at: i64| {
            db.execute(
                INSERT_FEED_ADMISSION_ATTEMPT_SQL,
                params![
                    attempt_id,
                    "install-a",
                    "key-a",
                    host,
                    accepted,
                    Option::<&str>::None,
                    created_at
                ],
            )
            .expect("insert admission attempt");
        };
        insert("a1", "a.example", 1, NOW - 10);
        insert("a2", "a.example", 1, NOW - 20);
        insert("a3", "a.example", 0, NOW - 30);
        insert("a4", "a.example", 1, NOW - 100_000);
        insert("b1", "b.example", 1, NOW - 5);
        insert("c1", "c.example", 1, NOW - 5);

        let mut statement = db
            .prepare(&accepted_admission_counts_for_hosts_since_sql(2))
            .expect("prepare host counts");
        let counts = statement
            .query_map(params![NOW - 3_600, "a.example", "b.example"], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .expect("host counts")
            .collect::<Result<BTreeMap<_, _>, _>>()
            .expect("read host counts");

        assert_eq!(counts.get("a.example"), Some(&2));
        assert_eq!(counts.get("b.example"), Some(&1));
        assert_eq!(counts.get("c.example"), None);
    }

    #[test]
    fn subscription_upsert_and_delete_statements_round_trip() {
        let db = setup_db();
        let install = "install-a";
        db.execute(
            "INSERT INTO app_attest_keys VALUES(?1,'key',X'00',0,'fixture','development',0,0)",
            params![install],
        )
        .unwrap();
        let feed_url = "https://example.com/f.xml";
        let read = |db: &Connection| -> (i64, i64, i64, Option<i64>) {
            db.query_row(
                "SELECT notifications_enabled, created_at, updated_at, deleted_at \
                 FROM feed_subscriptions WHERE install_id = ?1 AND feed_url = ?2",
                params![install, feed_url],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("read subscription")
        };

        db.execute(
            UPSERT_FEED_SUBSCRIPTION_SQL,
            params![install, feed_url, 1, NOW, NOW, "key"],
        )
        .expect("insert subscription");
        assert_eq!(read(&db), (1, NOW, NOW, None));

        // Resending an unchanged subscription within a day writes nothing.
        const DAY: i64 = 86_400;
        let changed = db
            .execute(
                UPSERT_FEED_SUBSCRIPTION_SQL,
                params![install, feed_url, 1, NOW + DAY - 1, NOW + DAY - 1, "key"],
            )
            .expect("re-upsert subscription within a day");
        assert_eq!(changed, 0);
        assert_eq!(read(&db), (1, NOW, NOW, None));

        // A day later it is confirmed again, keeping its original created_at.
        db.execute(
            UPSERT_FEED_SUBSCRIPTION_SQL,
            params![install, feed_url, 1, NOW + DAY, NOW + DAY, "key"],
        )
        .expect("re-upsert subscription after a day");
        assert_eq!(read(&db), (1, NOW, NOW + DAY, None));

        // A changed preference is written immediately.
        db.execute(
            UPSERT_FEED_SUBSCRIPTION_SQL,
            params![install, feed_url, 0, NOW + DAY + 5, NOW + DAY + 5, "key"],
        )
        .expect("disable subscription");
        assert_eq!(read(&db), (0, NOW, NOW + DAY + 5, None));
        db.execute(
            UPSERT_FEED_SUBSCRIPTION_SQL,
            params![install, feed_url, 1, NOW + DAY + 10, NOW + DAY + 10, "key"],
        )
        .expect("re-enable subscription");
        assert_eq!(read(&db), (1, NOW + DAY + 10, NOW + DAY + 10, None));

        db.execute(
            MARK_SUBSCRIPTION_DELETED_SQL,
            params![NOW + DAY + 20, install, feed_url, "key"],
        )
        .expect("mark deleted");
        assert_eq!(
            read(&db),
            (0, NOW + DAY + 10, NOW + DAY + 20, Some(NOW + DAY + 20))
        );

        // Marking an already-deleted row again is a no-op.
        let changed = db
            .execute(
                MARK_SUBSCRIPTION_DELETED_SQL,
                params![NOW + DAY + 25, install, feed_url, "key"],
            )
            .expect("mark deleted again");
        assert_eq!(changed, 0);

        // Resubscribing resurrects the row at once, with a fresh created_at.
        db.execute(
            UPSERT_FEED_SUBSCRIPTION_SQL,
            params![install, feed_url, 1, NOW + DAY + 30, NOW + DAY + 30, "key"],
        )
        .expect("resubscribe");
        assert_eq!(read(&db), (1, NOW + DAY + 30, NOW + DAY + 30, None));
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
        db.execute_batch(include_str!(
            "../migrations/0014_durable_notification_delivery.sql"
        ))
        .expect("delivery foundation");
    }

    fn insert_feed(db: &Connection, feed_url: &str, due_at: Option<i64>, updated_at: i64) {
        db.execute(
            "INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?1,?1,1,?2)",
            params![feed_url, due_at.unwrap_or(NOW)],
        )
        .unwrap();
        db.execute("INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) VALUES(?1,?1,?2,?3)", params![feed_url,NOW-100,updated_at]).unwrap();
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

    fn insert_push_send_attempt_row(db: &Connection, attempt_id: &str, created_at: i64) {
        db.execute(
            "INSERT INTO push_send_attempts \
             (attempt_id, install_id, apns_environment, created_at) \
             VALUES (?1, 'install-a', 'production', ?2)",
            params![attempt_id, created_at],
        )
        .expect("insert push send attempt");
    }

    #[test]
    fn pending_feed_insert_never_touches_an_existing_feed_row() {
        let db = setup_db();
        let feed_url = "https://example.com/existing.xml";
        insert_feed(&db, feed_url, Some(NOW + 500), NOW - 50);

        let inserted = db
            .execute(INSERT_PENDING_FEED_SQL, params![feed_url, feed_url, NOW])
            .expect("conflicting pending insert");

        assert_eq!(inserted, 0);
        let (next_poll_at, updated_at): (Option<i64>, i64) = db
            .query_row(
                "SELECT f.due_at,c.updated_at FROM n_feed_catalog c JOIN n_feed f ON f.canonical_url=c.feed_url WHERE c.feed_url=?1",
                params![feed_url],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("read existing feed row");
        assert_eq!(next_poll_at, Some(NOW + 500));
        assert_eq!(updated_at, NOW - 50);
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
    fn feed_poll_schedule_index_migration_is_idempotent() {
        let db = setup_db_through_0007();

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

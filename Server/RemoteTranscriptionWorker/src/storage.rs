#![cfg_attr(all(test, not(target_arch = "wasm32")), allow(dead_code))]

use serde::Deserialize;
use worker::{D1Database, D1Type, Result};

// App Attest challenge/key storage lives in the shared core crate
// (one copy for AdAnalysisWorker, NotificationsWorker, and this worker).
pub use opencast_app_attest_core::app_attest_storage::{
    app_attest_key_count_since, challenge, increment_challenge_source_bucket,
    insert_challenge_within_limits, key, mark_challenge_consumed,
    prune_challenge_source_buckets_before, prune_challenges_before, update_key_counter, upsert_key,
    AppAttestKeyRow, ChallengeRow,
};

const MAX_EXACT_F64_INTEGER: i64 = 9_007_199_254_740_991;

#[derive(Debug, Deserialize)]
struct CountRow {
    count: i64,
}

#[derive(Debug, Deserialize)]
struct TextRow {
    value: String,
}

#[derive(Debug, Deserialize)]
pub struct DevCreditAccountRow {
    pub available_seconds: i64,
    pub reserved_seconds: i64,
    pub consumed_seconds: i64,
}

#[derive(Debug, Deserialize)]
pub struct DevCreditReservationRow {
    pub account_id: String,
    pub reserved_seconds: i64,
    pub state: String,
}

#[derive(Debug, Deserialize)]
pub struct JobIndexRow {
    pub job_id: String,
    pub account_id: String,
    pub episode_id: String,
    pub state: String,
}

#[derive(Debug, Deserialize)]
struct StaleJobRow {
    job_id: String,
}

// Both job-state SQL constants are assembled at compile time from
// `job::STATE_*`, so a renamed or retyped state cannot silently diverge
// from the SQL. Migration 0005's partial indexes were built against these
// exact predicates (the migration repeats the strings literally and stays
// untouched); the byte-identity test below pins the assembled SQL to those
// bytes, and the EXPLAIN QUERY PLAN tests prove the indexes still serve it.
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
        Err(_) => panic!("assembled job-state SQL must be UTF-8"),
    }
}

const STALE_JOB_IDS_SQL_PARTS: &[&str] = &[
    "SELECT job_id FROM jobs WHERE ((state IN ('",
    crate::job::STATE_CREATED,
    "', '",
    crate::job::STATE_STAGING_ORIGIN,
    "') AND updated_at <= ?1) OR (state = '",
    crate::job::STATE_WAITING_FOR_DEVICE_SOURCE,
    "' AND updated_at <= ?2) OR (state = '",
    crate::job::STATE_AWAITING_CREDITS,
    "' AND updated_at <= ?3) OR (state = '",
    crate::job::STATE_EXACT_UPLOAD_REQUIRED,
    "' AND updated_at <= ?4) OR (state = '",
    crate::job::STATE_EXACT_UPLOADING,
    "' AND updated_at <= ?5) OR (state = '",
    crate::job::STATE_DETECTING_ADS,
    "' AND updated_at <= ?6) OR (state IN ('",
    crate::job::STATE_RESULT_READY,
    "', '",
    crate::job::STATE_DELIVERED,
    "') AND updated_at <= ?7)) ORDER BY updated_at ASC, job_id ASC LIMIT ?8",
];
const STALE_JOB_IDS_SQL_BYTES: [u8; concat_len(STALE_JOB_IDS_SQL_PARTS)] =
    concat_bytes(STALE_JOB_IDS_SQL_PARTS);
const STALE_JOB_IDS_SQL: &str = concat_str(&STALE_JOB_IDS_SQL_BYTES);

/// The states `ACTIVE_JOB_COUNT_SQL` excludes; every other `job::ALL_STATES`
/// entry counts as active (the classification-completeness test forces an
/// explicit decision for each new state).
const ACTIVE_JOB_COUNT_EXCLUDED_STATES: [&str; 5] = [
    crate::job::STATE_ACKNOWLEDGED,
    crate::job::STATE_CANCELLED,
    crate::job::STATE_FAILED,
    crate::job::STATE_RESULT_READY,
    crate::job::STATE_DELIVERED,
];

// Parked results ('result_ready'/'delivered') are excluded: the cap bounds
// concurrent processing, and a finished result waiting for pickup consumes
// no compute. Counting it let one unacknowledged result (client killed
// before ack) hold the account slot for the full 7-day result TTL — every
// new create 429'd as rate_limited.
const ACTIVE_JOB_COUNT_SQL_PARTS: &[&str] = &[
    "SELECT COUNT(*) AS count FROM jobs WHERE account_id = ?1 AND state NOT IN ('",
    ACTIVE_JOB_COUNT_EXCLUDED_STATES[0],
    "', '",
    ACTIVE_JOB_COUNT_EXCLUDED_STATES[1],
    "', '",
    ACTIVE_JOB_COUNT_EXCLUDED_STATES[2],
    "', '",
    ACTIVE_JOB_COUNT_EXCLUDED_STATES[3],
    "', '",
    ACTIVE_JOB_COUNT_EXCLUDED_STATES[4],
    "')",
];
const ACTIVE_JOB_COUNT_SQL_BYTES: [u8; concat_len(ACTIVE_JOB_COUNT_SQL_PARTS)] =
    concat_bytes(ACTIVE_JOB_COUNT_SQL_PARTS);
const ACTIVE_JOB_COUNT_SQL: &str = concat_str(&ACTIVE_JOB_COUNT_SQL_BYTES);

// --- Accounts (pass 0: keyed by registered App Attest install) ---

pub async fn ensure_account(
    db: &D1Database,
    install_id: &str,
    candidate_account_id: &str,
    now: i64,
) -> Result<String> {
    let args = [
        D1Type::Text(candidate_account_id),
        D1Type::Text(install_id),
        d1_i64(now)?,
        d1_i64(now)?,
    ];
    db.prepare(
        "INSERT INTO accounts (account_id, install_id, created_at, updated_at) \
         VALUES (?1, ?2, ?3, ?4) \
         ON CONFLICT(install_id) DO NOTHING",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    let row = db
        .prepare("SELECT account_id AS value FROM accounts WHERE install_id = ?1 LIMIT 1")
        .bind_refs(&[D1Type::Text(install_id)])?
        .first::<TextRow>(None)
        .await?;
    row.map(|row| row.value)
        .ok_or_else(|| worker::Error::RustError("account row missing after upsert".to_string()))
}

pub async fn account_for_install(db: &D1Database, install_id: &str) -> Result<Option<String>> {
    let row = db
        .prepare("SELECT account_id AS value FROM accounts WHERE install_id = ?1 LIMIT 1")
        .bind_refs(&[D1Type::Text(install_id)])?
        .first::<TextRow>(None)
        .await?;
    Ok(row.map(|row| row.value))
}

// --- Purchase-backend install→account links (pass 1): many installs may
// share one purchase account, and only a verified bootstrap writes here. ---

pub async fn purchase_account_for_install(
    db: &D1Database,
    install_id: &str,
) -> Result<Option<String>> {
    let row = db
        .prepare(
            "SELECT account_id AS value FROM install_account_links \
             WHERE install_id = ?1 LIMIT 1",
        )
        .bind_refs(&[D1Type::Text(install_id)])?
        .first::<TextRow>(None)
        .await?;
    Ok(row.map(|row| row.value))
}

/// Upsert that overwrites: PurchaseWorker is authoritative for identity, so
/// a re-bootstrap that resolves to a different account re-points the link.
pub async fn link_install_account(
    db: &D1Database,
    install_id: &str,
    account_id: &str,
    now: i64,
) -> Result<()> {
    let args = [
        D1Type::Text(install_id),
        D1Type::Text(account_id),
        d1_i64(now)?,
        d1_i64(now)?,
    ];
    db.prepare(
        "INSERT INTO install_account_links (install_id, account_id, created_at, updated_at) \
         VALUES (?1, ?2, ?3, ?4) \
         ON CONFLICT(install_id) DO UPDATE SET \
           account_id = excluded.account_id, \
           updated_at = excluded.updated_at",
    )
    .bind_refs(&args)?
    .run()
    .await?;
    Ok(())
}

// --- Job index ---

pub async fn insert_job_mapping(
    db: &D1Database,
    job_id: &str,
    account_id: &str,
    client_request_id: &str,
    episode_id: &str,
    state: &str,
    now: i64,
) -> Result<String> {
    let args = [
        D1Type::Text(job_id),
        D1Type::Text(account_id),
        D1Type::Text(client_request_id),
        D1Type::Text(episode_id),
        D1Type::Text(state),
        d1_i64(now)?,
        d1_i64(now)?,
    ];
    db.prepare(
        "INSERT INTO jobs \
         (job_id, account_id, client_request_id, episode_id, state, created_at, updated_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
         ON CONFLICT(account_id, client_request_id) DO NOTHING",
    )
    .bind_refs(&args)?
    .run()
    .await?;

    let row = db
        .prepare(
            "SELECT job_id AS value FROM jobs \
             WHERE account_id = ?1 AND client_request_id = ?2 \
             LIMIT 1",
        )
        .bind_refs(&[D1Type::Text(account_id), D1Type::Text(client_request_id)])?
        .first::<TextRow>(None)
        .await?;
    row.map(|row| row.value)
        .ok_or_else(|| worker::Error::RustError("job row missing after upsert".to_string()))
}

pub async fn job_index(db: &D1Database, job_id: &str) -> Result<Option<JobIndexRow>> {
    db.prepare("SELECT job_id, account_id, episode_id, state FROM jobs WHERE job_id = ?1 LIMIT 1")
        .bind_refs(&[D1Type::Text(job_id)])?
        .first::<JobIndexRow>(None)
        .await
}

pub async fn update_job_state(db: &D1Database, job_id: &str, state: &str, now: i64) -> Result<()> {
    let args = [D1Type::Text(state), d1_i64(now)?, D1Type::Text(job_id)];
    db.prepare("UPDATE jobs SET state = ?1, updated_at = ?2 WHERE job_id = ?3")
        .bind_refs(&args)?
        .run()
        .await?;
    Ok(())
}

pub async fn active_job_count(db: &D1Database, account_id: &str) -> Result<i64> {
    let args = [D1Type::Text(account_id)];
    count(db, ACTIVE_JOB_COUNT_SQL, &args).await
}

/// Content-free D1 index scan for jobs whose state-specific deadline has
/// elapsed. The DO remains authoritative and will perform normal
/// cancellation; this query is only the operational alarm backstop.
pub async fn stale_job_ids(
    db: &D1Database,
    config: &crate::config::AppConfig,
    now: i64,
    limit: usize,
) -> Result<(Vec<String>, bool)> {
    let limit = limit.clamp(1, 1_000);
    let query_limit = limit.saturating_add(1);
    let args = [
        d1_i64(now.saturating_sub(config.staging_origin_deadline_seconds))?,
        d1_i64(now.saturating_sub(config.waiting_for_device_source_deadline_seconds))?,
        d1_i64(now.saturating_sub(config.awaiting_credits_deadline_seconds))?,
        d1_i64(now.saturating_sub(config.exact_upload_required_deadline_seconds))?,
        d1_i64(now.saturating_sub(config.exact_uploading_deadline_seconds))?,
        d1_i64(now.saturating_sub(config.ad_analysis_deadline_seconds))?,
        d1_i64(now.saturating_sub(7 * 24 * 60 * 60))?,
        d1_i64(i64::try_from(query_limit).unwrap_or(1_001))?,
    ];
    let rows = db
        .prepare(STALE_JOB_IDS_SQL)
        .bind_refs(&args)?
        .all()
        .await?
        .results::<StaleJobRow>()?;
    let truncated = rows.len() > limit;
    Ok((
        rows.into_iter().take(limit).map(|row| row.job_id).collect(),
        truncated,
    ))
}

// --- DevCreditAuthority ledger (development lane only) ---

pub async fn ensure_dev_credit_account(
    db: &D1Database,
    account_id: &str,
    grant_seconds: i64,
    now: i64,
) -> Result<()> {
    let args = [
        D1Type::Text(account_id),
        d1_i64(grant_seconds)?,
        d1_i64(now)?,
        d1_i64(now)?,
    ];
    db.prepare(
        "INSERT INTO dev_credit_accounts \
         (account_id, available_seconds, reserved_seconds, consumed_seconds, created_at, updated_at) \
         VALUES (?1, ?2, 0, 0, ?3, ?4) \
         ON CONFLICT(account_id) DO NOTHING",
    )
    .bind_refs(&args)?
    .run()
    .await?;
    Ok(())
}

pub async fn dev_credit_account(
    db: &D1Database,
    account_id: &str,
) -> Result<Option<DevCreditAccountRow>> {
    db.prepare(
        "SELECT available_seconds, reserved_seconds, consumed_seconds \
         FROM dev_credit_accounts WHERE account_id = ?1 LIMIT 1",
    )
    .bind_refs(&[D1Type::Text(account_id)])?
    .first::<DevCreditAccountRow>(None)
    .await
}

pub async fn dev_credit_reservation(
    db: &D1Database,
    job_id: &str,
) -> Result<Option<DevCreditReservationRow>> {
    db.prepare(
        "SELECT account_id, reserved_seconds, state \
         FROM dev_credit_reservations WHERE job_id = ?1 LIMIT 1",
    )
    .bind_refs(&[D1Type::Text(job_id)])?
    .first::<DevCreditReservationRow>(None)
    .await
}

/// Debits available balance and records the reservation in one atomic D1
/// batch. The INSERT is guarded on the UPDATE having changed exactly one row
/// (`changes() = 1`), so an insufficient balance changes nothing.
pub async fn dev_credit_reserve(
    db: &D1Database,
    account_id: &str,
    job_id: &str,
    seconds: i64,
    now: i64,
) -> Result<bool> {
    let debit = db
        .prepare(
            "UPDATE dev_credit_accounts \
             SET available_seconds = available_seconds - ?1, \
                 reserved_seconds = reserved_seconds + ?1, \
                 updated_at = ?2 \
             WHERE account_id = ?3 AND available_seconds >= ?1",
        )
        .bind_refs(&[d1_i64(seconds)?, d1_i64(now)?, D1Type::Text(account_id)])?;
    let insert = db
        .prepare(
            "INSERT INTO dev_credit_reservations \
             (job_id, account_id, reserved_seconds, state, created_at, updated_at) \
             SELECT ?1, ?2, ?3, 'reserved', ?4, ?4 \
             WHERE (SELECT changes()) = 1",
        )
        .bind_refs(&[
            D1Type::Text(job_id),
            D1Type::Text(account_id),
            d1_i64(seconds)?,
            d1_i64(now)?,
        ])?;
    db.batch(vec![debit, insert]).await?;

    Ok(dev_credit_reservation(db, job_id).await?.is_some())
}

pub async fn dev_credit_settle(
    db: &D1Database,
    job_id: &str,
    account_id: &str,
    seconds: i64,
    now: i64,
) -> Result<bool> {
    let move_buckets = db
        .prepare(
            "UPDATE dev_credit_accounts \
             SET reserved_seconds = reserved_seconds - ?1, \
                 consumed_seconds = consumed_seconds + ?1, \
                 updated_at = ?2 \
             WHERE account_id = ?3 AND reserved_seconds >= ?1 \
             AND EXISTS (SELECT 1 FROM dev_credit_reservations \
                         WHERE job_id = ?4 AND state = 'reserved')",
        )
        .bind_refs(&[
            d1_i64(seconds)?,
            d1_i64(now)?,
            D1Type::Text(account_id),
            D1Type::Text(job_id),
        ])?;
    let mark = db
        .prepare(
            "UPDATE dev_credit_reservations \
             SET state = 'settled', updated_at = ?1 \
             WHERE job_id = ?2 AND state = 'reserved' AND (SELECT changes()) = 1",
        )
        .bind_refs(&[d1_i64(now)?, D1Type::Text(job_id)])?;
    db.batch(vec![move_buckets, mark]).await?;

    Ok(matches!(
        dev_credit_reservation(db, job_id).await?,
        Some(reservation) if reservation.state == "settled"
    ))
}

pub async fn dev_credit_release(
    db: &D1Database,
    job_id: &str,
    account_id: &str,
    seconds: i64,
    now: i64,
) -> Result<bool> {
    let move_buckets = db
        .prepare(
            "UPDATE dev_credit_accounts \
             SET reserved_seconds = reserved_seconds - ?1, \
                 available_seconds = available_seconds + ?1, \
                 updated_at = ?2 \
             WHERE account_id = ?3 AND reserved_seconds >= ?1 \
             AND EXISTS (SELECT 1 FROM dev_credit_reservations \
                         WHERE job_id = ?4 AND state = 'reserved')",
        )
        .bind_refs(&[
            d1_i64(seconds)?,
            d1_i64(now)?,
            D1Type::Text(account_id),
            D1Type::Text(job_id),
        ])?;
    let mark = db
        .prepare(
            "UPDATE dev_credit_reservations \
             SET state = 'released', updated_at = ?1 \
             WHERE job_id = ?2 AND state = 'reserved' AND (SELECT changes()) = 1",
        )
        .bind_refs(&[d1_i64(now)?, D1Type::Text(job_id)])?;
    db.batch(vec![move_buckets, mark]).await?;

    Ok(matches!(
        dev_credit_reservation(db, job_id).await?,
        Some(reservation) if reservation.state == "released"
    ))
}

// --- Content-free counters ---

pub async fn increment_counter(db: &D1Database, name: &str, delta: i64, now: i64) -> Result<()> {
    let args = [D1Type::Text(name), d1_i64(delta)?, d1_i64(now)?];
    db.prepare(
        "INSERT INTO counters (name, value, updated_at) VALUES (?1, ?2, ?3) \
         ON CONFLICT(name) DO UPDATE SET \
         value = counters.value + excluded.value, \
         updated_at = excluded.updated_at",
    )
    .bind_refs(&args)?
    .run()
    .await?;
    Ok(())
}

async fn count(db: &D1Database, sql: &str, args: &[D1Type<'_>]) -> Result<i64> {
    let row = db
        .prepare(sql)
        .bind_refs(args)?
        .first::<CountRow>(None)
        .await?;
    Ok(row.map(|row| row.count).unwrap_or(0))
}

fn d1_i64(value: i64) -> Result<D1Type<'static>> {
    if !(-MAX_EXACT_F64_INTEGER..=MAX_EXACT_F64_INTEGER).contains(&value) {
        return Err(worker::Error::RustError(format!(
            "D1 i64 value {value} exceeds f64 exact integer range"
        )));
    }

    // worker::D1Type::Integer is narrower than i64 in the current worker
    // crate, so timestamp-sized values are bound as Real after guarding f64
    // precision.
    Ok(D1Type::Real(value as f64))
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::{ACTIVE_JOB_COUNT_EXCLUDED_STATES, ACTIVE_JOB_COUNT_SQL, STALE_JOB_IDS_SQL};
    use crate::job;
    use rusqlite::{params, Connection};

    const NOW: i64 = 1_784_000_000;

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

    /// Migration 0005's partial indexes were built against exactly these
    /// predicates; the assembled constants must never drift from them.
    #[test]
    fn assembled_job_state_sql_is_byte_identical_to_the_migration_0005_literals() {
        assert_eq!(
            STALE_JOB_IDS_SQL,
            "SELECT job_id FROM jobs WHERE \
             ((state IN ('created', 'staging_origin') AND updated_at <= ?1) OR \
             (state = 'waiting_for_device_source' AND updated_at <= ?2) OR \
             (state = 'awaiting_credits' AND updated_at <= ?3) OR \
             (state = 'exact_upload_required' AND updated_at <= ?4) OR \
             (state = 'exact_uploading' AND updated_at <= ?5) OR \
             (state = 'detecting_ads' AND updated_at <= ?6) OR \
             (state IN ('result_ready', 'delivered') AND updated_at <= ?7)) \
             ORDER BY updated_at ASC, job_id ASC LIMIT ?8"
        );
        assert_eq!(
            ACTIVE_JOB_COUNT_SQL,
            "SELECT COUNT(*) AS count FROM jobs WHERE account_id = ?1 AND state \
             NOT IN ('acknowledged', 'cancelled', 'failed', 'result_ready', 'delivered')"
        );
    }

    /// Every declared job state must be explicitly classified for the
    /// active-job cap: either in `ACTIVE_JOB_COUNT_EXCLUDED_STATES` or in
    /// the expected-active list below. A 20th state added to
    /// `job::ALL_STATES` fails here until it is classified, instead of
    /// silently counting as active and rate-limiting the account
    /// (`max_active_jobs_per_account` defaults to 1).
    #[test]
    fn every_job_state_is_classified_for_the_active_job_count() {
        const EXPECTED_ACTIVE_STATES: [&str; 14] = [
            job::STATE_CREATED,
            job::STATE_STAGING_ORIGIN,
            job::STATE_WAITING_FOR_DEVICE_SOURCE,
            job::STATE_SOURCE_MATCHED,
            job::STATE_EXACT_UPLOAD_REQUIRED,
            job::STATE_EXACT_UPLOADING,
            job::STATE_PROBING,
            job::STATE_AWAITING_CREDITS,
            job::STATE_RESERVED,
            job::STATE_CHUNKING,
            job::STATE_TRANSCRIBING,
            job::STATE_STITCHING,
            job::STATE_DETECTING_ADS,
            job::STATE_CANCELLING,
        ];

        for state in ACTIVE_JOB_COUNT_EXCLUDED_STATES {
            assert!(
                job::ALL_STATES.contains(&state),
                "excluded state {state:?} is not a declared job state"
            );
        }

        let derived_active: Vec<&str> = job::ALL_STATES
            .iter()
            .copied()
            .filter(|state| !ACTIVE_JOB_COUNT_EXCLUDED_STATES.contains(state))
            .collect();
        assert_eq!(
            derived_active, EXPECTED_ACTIVE_STATES,
            "every job state must be explicitly active or excluded for \
             ACTIVE_JOB_COUNT_SQL"
        );

        let mut deduplicated: Vec<&str> = job::ALL_STATES.to_vec();
        deduplicated.sort_unstable();
        deduplicated.dedup();
        assert_eq!(deduplicated.len(), job::ALL_STATES.len());
    }

    fn setup_db() -> Connection {
        let db = Connection::open_in_memory().expect("open in-memory sqlite");
        db.execute_batch(include_str!("../migrations/0001_app_attest_auth.sql"))
            .expect("create app attest auth tables");
        db.execute_batch(include_str!("../migrations/0002_accounts_jobs_credit.sql"))
            .expect("create account/job/credit tables");
        db.execute_batch(include_str!("../migrations/0003_counters.sql"))
            .expect("create counters table");
        db.execute_batch(include_str!("../migrations/0004_install_account_links.sql"))
            .expect("create install account links");
        db.execute_batch(include_str!(
            "../migrations/0005_index_stale_job_sweeper.sql"
        ))
        .expect("create stale-job sweeper indexes");
        db
    }

    #[test]
    fn stale_job_sweep_uses_partial_indexes_instead_of_scanning_jobs() {
        let db = setup_db();
        let mut statement = db
            .prepare(&format!("EXPLAIN QUERY PLAN {STALE_JOB_IDS_SQL}"))
            .expect("prepare stale-job query plan");
        let plan = statement
            .query_map(params![NOW, NOW, NOW, NOW, NOW, NOW, NOW, 101_i64], |row| {
                row.get::<_, String>(3)
            })
            .expect("query stale-job plan")
            .collect::<std::result::Result<Vec<_>, _>>()
            .expect("read stale-job plan");

        assert!(
            plan.iter()
                .any(|detail| detail.contains("idx_jobs_sweep_staging")),
            "expected staging sweep index in plan: {plan:?}"
        );
        assert!(
            plan.iter()
                .any(|detail| detail.contains("idx_jobs_sweep_results")),
            "expected result sweep index in plan: {plan:?}"
        );
        assert!(
            plan.iter().all(|detail| detail != "SCAN jobs"),
            "unexpected full jobs scan: {plan:?}"
        );
    }

    fn seed_account(db: &Connection, account_id: &str, available: i64) {
        db.execute(
            "INSERT INTO accounts (account_id, install_id, created_at, updated_at) \
             VALUES (?1, ?2, ?3, ?3)",
            params![account_id, format!("install-{account_id}"), NOW],
        )
        .expect("insert account");
        db.execute(
            "INSERT INTO dev_credit_accounts \
             (account_id, available_seconds, reserved_seconds, consumed_seconds, created_at, updated_at) \
             VALUES (?1, ?2, 0, 0, ?3, ?3)",
            params![account_id, available, NOW],
        )
        .expect("insert credit account");
    }

    fn reserve(db: &Connection, account_id: &str, job_id: &str, seconds: i64) -> bool {
        let debited = db
            .execute(
                "UPDATE dev_credit_accounts \
                 SET available_seconds = available_seconds - ?1, \
                     reserved_seconds = reserved_seconds + ?1, updated_at = ?2 \
                 WHERE account_id = ?3 AND available_seconds >= ?1",
                params![seconds, NOW, account_id],
            )
            .expect("debit");
        if debited == 1 {
            db.execute(
                "INSERT INTO dev_credit_reservations \
                 (job_id, account_id, reserved_seconds, state, created_at, updated_at) \
                 VALUES (?1, ?2, ?3, 'reserved', ?4, ?4)",
                params![job_id, account_id, seconds, NOW],
            )
            .expect("insert reservation");
        }
        debited == 1
    }

    #[test]
    fn active_job_count_ignores_terminal_and_parked_result_states() {
        let db = setup_db();
        seed_account(&db, "acct-1", 36_000);
        let states = [
            ("created", true),
            ("staging_origin", true),
            ("waiting_for_device_source", true),
            ("source_matched", true),
            ("exact_upload_required", true),
            ("exact_uploading", true),
            ("probing", true),
            ("awaiting_credits", true),
            ("reserved", true),
            ("chunking", true),
            ("transcribing", true),
            ("stitching", true),
            ("detecting_ads", true),
            ("cancelling", true),
            ("result_ready", false),
            ("delivered", false),
            ("acknowledged", false),
            ("cancelled", false),
            ("failed", false),
        ];
        for (index, (state, _)) in states.iter().enumerate() {
            db.execute(
                "INSERT INTO jobs (job_id, account_id, client_request_id, episode_id, state, created_at, updated_at) \
                 VALUES (?1, 'acct-1', ?1, ?1, ?2, ?3, ?3)",
                params![format!("job-{index}"), state, NOW],
            )
            .expect("insert job");
        }
        let expected = states.iter().filter(|(_, active)| *active).count() as i64;
        let counted: i64 = db
            .query_row(ACTIVE_JOB_COUNT_SQL, params!["acct-1"], |row| row.get(0))
            .expect("count active jobs");
        assert_eq!(counted, expected);
    }

    #[test]
    fn migration_supports_job_mapping_dedupe() {
        let db = setup_db();
        seed_account(&db, "acct-1", 36_000);
        db.execute(
            "INSERT INTO jobs (job_id, account_id, client_request_id, episode_id, state, created_at, updated_at) \
             VALUES ('job-1', 'acct-1', 'req-1', 'ep-1', 'created', ?1, ?1)",
            params![NOW],
        )
        .expect("insert job");
        let duplicate = db.execute(
            "INSERT INTO jobs (job_id, account_id, client_request_id, episode_id, state, created_at, updated_at) \
             VALUES ('job-2', 'acct-1', 'req-1', 'ep-1', 'created', ?1, ?1) \
             ON CONFLICT(account_id, client_request_id) DO NOTHING",
            params![NOW],
        )
        .expect("duplicate insert");
        assert_eq!(duplicate, 0);

        let canonical: String = db
            .query_row(
                "SELECT job_id FROM jobs WHERE account_id = 'acct-1' AND client_request_id = 'req-1'",
                [],
                |row| row.get(0),
            )
            .expect("read canonical job");
        assert_eq!(canonical, "job-1");
    }

    #[test]
    fn dev_credit_reserve_settle_release_semantics() {
        let db = setup_db();
        seed_account(&db, "acct-1", 3_600);

        assert!(reserve(&db, "acct-1", "job-1", 2_040));
        let (available, reserved): (i64, i64) = db
            .query_row(
                "SELECT available_seconds, reserved_seconds FROM dev_credit_accounts \
                 WHERE account_id = 'acct-1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("read balances");
        assert_eq!((available, reserved), (1_560, 2_040));

        // Insufficient balance changes nothing.
        assert!(!reserve(&db, "acct-1", "job-2", 3_600));

        // Settle moves reserved to consumed exactly once.
        let settled = db
            .execute(
                "UPDATE dev_credit_accounts \
                 SET reserved_seconds = reserved_seconds - ?1, consumed_seconds = consumed_seconds + ?1 \
                 WHERE account_id = 'acct-1' AND reserved_seconds >= ?1 \
                 AND EXISTS (SELECT 1 FROM dev_credit_reservations WHERE job_id = 'job-1' AND state = 'reserved')",
                params![2_040_i64],
            )
            .expect("settle");
        assert_eq!(settled, 1);
        db.execute(
            "UPDATE dev_credit_reservations SET state = 'settled' WHERE job_id = 'job-1' AND state = 'reserved'",
            [],
        )
        .expect("mark settled");

        // A second settle is a no-op because the reservation is not 'reserved'.
        let settled_again = db
            .execute(
                "UPDATE dev_credit_accounts \
                 SET reserved_seconds = reserved_seconds - ?1, consumed_seconds = consumed_seconds + ?1 \
                 WHERE account_id = 'acct-1' AND reserved_seconds >= ?1 \
                 AND EXISTS (SELECT 1 FROM dev_credit_reservations WHERE job_id = 'job-1' AND state = 'reserved')",
                params![2_040_i64],
            )
            .expect("settle again");
        assert_eq!(settled_again, 0);

        let (available, reserved, consumed): (i64, i64, i64) = db
            .query_row(
                "SELECT available_seconds, reserved_seconds, consumed_seconds \
                 FROM dev_credit_accounts WHERE account_id = 'acct-1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("read final balances");
        assert_eq!((available, reserved, consumed), (1_560, 0, 2_040));
    }
}

//! D1 challenge/key storage shared by every App Attest worker. Compiles on
//! any target; the D1 calls only run on wasm. Each worker's migration files
//! stay in that worker — host tests pinning migration schemas against these
//! queries live beside the migrations.

use serde::Deserialize;
use worker::{D1Database, D1Type, Result};

use crate::app_attest::challenge_hash;
use crate::d1_changes::changed_exactly_one_row;

const MAX_EXACT_F64_INTEGER: i64 = 9_007_199_254_740_991;

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
struct CountRow {
    count: i64,
}

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
        d1_i64(created_at)?,
        d1_i64(expires_at)?,
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
    let args = [D1Type::Text(install_id), d1_i64(since)?];
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
    let args = [d1_i64(since)?];
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
        d1_i64(window_start)?,
        d1_i64(now)?,
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
    let args = [d1_i64(cutoff)?];
    db.prepare("DELETE FROM app_attest_challenge_source_buckets WHERE updated_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

pub async fn prune_challenges_before(db: &D1Database, cutoff: i64) -> Result<()> {
    let args = [d1_i64(cutoff)?];
    db.prepare("DELETE FROM app_attest_challenges WHERE created_at < ?1")
        .bind_refs(&args)?
        .run()
        .await?;

    Ok(())
}

/// Deletes an install's App Attest identity rows (challenges and keys) in
/// one atomic batch. Challenge source buckets are keyed by hashed source
/// token, not install, and age out via their prune.
pub async fn delete_install_rows(db: &D1Database, install_id: &str) -> Result<()> {
    let args = [D1Type::Text(install_id)];
    db.batch(
        [
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

pub async fn mark_challenge_consumed(
    db: &D1Database,
    challenge_id: &str,
    consumed_at: i64,
) -> Result<bool> {
    let args = [d1_i64(consumed_at)?, D1Type::Text(challenge_id)];
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
        d1_i64(sign_counter)?,
        D1Type::Text(app_id),
        D1Type::Text(environment),
        d1_i64(now)?,
        d1_i64(now)?,
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
    let args = [D1Type::Text(install_id), d1_i64(since)?];
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
        d1_i64(next_counter)?,
        d1_i64(now)?,
        D1Type::Text(install_id),
        D1Type::Text(key_id),
        d1_i64(previous_counter)?,
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

fn d1_i64(value: i64) -> Result<D1Type<'static>> {
    if !(-MAX_EXACT_F64_INTEGER..=MAX_EXACT_F64_INTEGER).contains(&value) {
        return Err(worker::Error::RustError(format!(
            "D1 i64 value {value} exceeds f64 exact integer range"
        )));
    }

    // worker::D1Type::Integer is narrower than i64 in the current worker crate,
    // so timestamp-sized values are bound as Real after guarding f64 precision.
    Ok(D1Type::Real(value as f64))
}

#[cfg(test)]
mod tests {
    use super::{d1_i64, MAX_EXACT_F64_INTEGER};
    use worker::D1Type;

    #[test]
    fn d1_i64_accepts_only_exact_f64_integer_range() {
        assert!(matches!(
            d1_i64(MAX_EXACT_F64_INTEGER).expect("upper boundary should bind"),
            D1Type::Real(value) if value == MAX_EXACT_F64_INTEGER as f64
        ));
        assert!(matches!(
            d1_i64(-MAX_EXACT_F64_INTEGER).expect("lower boundary should bind"),
            D1Type::Real(value) if value == -MAX_EXACT_F64_INTEGER as f64
        ));
        assert!(d1_i64(MAX_EXACT_F64_INTEGER + 1).is_err());
        assert!(d1_i64(-MAX_EXACT_F64_INTEGER - 1).is_err());
    }
}

//! Content-free operational counters: lifetime monotonic totals in the lane's
//! D1 `counters` table (migration 0003, the RemoteTranscriptionWorker
//! pattern). Values only — never identifiers, hashes, or content.
//!
//! These exist because the worker is otherwise unobservable after the fact:
//! the only structured completion signal is logged from a Durable Object
//! alarm/background turn that Workers Observability never indexes, job
//! records purge after 30 minutes, and usage-limiter objects self-wipe after
//! 48 hours. The admin dashboard diffs these totals locally to produce
//! windowed rates.
//!
//! Every write is best effort: a counter bump can never fail a job, a billing
//! action, or an admission decision. Before the migration is applied the
//! writes fail and are dropped silently (the dashboard reports the source as
//! unavailable until the table exists).

use opencast_app_attest_core::app_attest_storage::d1_i64;
use worker::{D1Database, D1Type, Result};

use crate::types::AnalysisRunStats;

// --- Vocabulary (the admin dashboard allowlists exactly these names) -------

/// Async job runs started (one per Running record persisted). Because the
/// spend batch is written before the terminal-write guard, this is always
/// `>= jobs_completed + jobs_failed_*`.
pub const JOBS_STARTED: &str = "jobs_started";
pub const JOBS_COMPLETED: &str = "jobs_completed";
pub const JOBS_FAILED_UPSTREAM: &str = "jobs_failed_upstream";
pub const JOBS_FAILED_TRANSIENT: &str = "jobs_failed_transient";
/// Legacy inline (`async_supported: false`) analyses; their spend lands in
/// the same token counters as job runs.
pub const SYNC_ANALYSES: &str = "sync_analyses";

/// Full model re-requests (the outer attempt ladder, not transport retries).
pub const ANALYSIS_ATTEMPTS: &str = "analysis_attempts";
pub const PROMPT_TOKENS: &str = "prompt_tokens";
pub const CANDIDATES_TOKENS: &str = "candidates_tokens";
pub const THOUGHTS_TOKENS: &str = "thoughts_tokens";
pub const TOTAL_TOKENS: &str = "total_tokens";

pub const CAP_DENIALS_BEARER: &str = "cap_denials_bearer";
pub const CAP_DENIALS_APP_ATTEST: &str = "cap_denials_app_attest";
pub const CAP_DENIALS_GLOBAL: &str = "cap_denials_global";

pub const BOOTSTRAP_REQUIRED_DENIALS: &str = "bootstrap_required_denials";
pub const RESERVE_DENIED_INSUFFICIENT: &str = "reserve_denied_insufficient";
pub const RESERVE_DENIED_BOOTSTRAP: &str = "reserve_denied_bootstrap";
/// Submits refused with the fail-closed `billing_unavailable` code (backend
/// unreachable, reserve failed for a non-typed reason, or a billed restart
/// blocked behind an unresolved settle/release).
pub const BILLING_UNAVAILABLE: &str = "billing_unavailable";
/// Failed settle/release attempts (terminal path and alarm retries alike).
pub const BILLING_RETRIES: &str = "billing_retries";
pub const SETTLE_ABANDONED: &str = "settle_abandoned";
pub const RELEASE_ABANDONED: &str = "release_abandoned";
pub const SETTLED_JOBS: &str = "settled_jobs";
pub const CHARGED_CREDIT_SECONDS: &str = "charged_credit_seconds";
pub const RELEASED_CREDIT_SECONDS: &str = "released_credit_seconds";

/// One D1 write covering every counter of a run's model spend.
pub fn spend_deltas(stats: &AnalysisRunStats) -> Vec<(&'static str, i64)> {
    let mut deltas = vec![(ANALYSIS_ATTEMPTS, i64::from(stats.attempts))];
    if let Some(usage) = &stats.usage {
        deltas.push((PROMPT_TOKENS, clamp_u64(usage.prompt_token_count)));
        deltas.push((CANDIDATES_TOKENS, clamp_u64(usage.candidates_token_count)));
        deltas.push((THOUGHTS_TOKENS, clamp_u64(usage.thoughts_token_count)));
        deltas.push((TOTAL_TOKENS, clamp_u64(usage.total_token_count)));
    }
    deltas
}

fn clamp_u64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

/// The multi-row upsert for `rows` counters (host-testable against the
/// migration schema in `tests/counters_migration.rs`).
pub fn upsert_sql(rows: usize) -> String {
    let placeholders = (0..rows)
        .map(|index| {
            let base = index * 3;
            format!("(?{}, ?{}, ?{})", base + 1, base + 2, base + 3)
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "INSERT INTO counters (name, value, updated_at) VALUES {placeholders} \
         ON CONFLICT(name) DO UPDATE SET \
         value = counters.value + excluded.value, \
         updated_at = excluded.updated_at"
    )
}

/// Applies every non-zero delta in one statement (one D1 round trip). An
/// all-zero batch is a no-op and touches D1 not at all.
pub async fn increment_counters(db: &D1Database, deltas: &[(&str, i64)], now: i64) -> Result<()> {
    let rows: Vec<(&str, i64)> = deltas
        .iter()
        .copied()
        .filter(|(_, delta)| *delta != 0)
        .collect();
    if rows.is_empty() {
        return Ok(());
    }
    let mut args: Vec<D1Type<'_>> = Vec::with_capacity(rows.len() * 3);
    for (name, delta) in &rows {
        args.push(D1Type::Text(name));
        args.push(d1_i64(*delta)?);
        args.push(d1_i64(now)?);
    }
    db.prepare(upsert_sql(rows.len()))
        .bind_refs(&args)?
        .run()
        .await?;
    Ok(())
}

/// Best-effort bump against the lane's D1 binding. Never returns an error:
/// a missing binding, a missing table, or a failed write is dropped.
///
/// Placement rule inside the job Durable Object: a bump is followed by a
/// storage await (record write, alarm, re-read) or a subrequest before the
/// task can park on the model call, never immediately before it. The local
/// runtime's test harness stubs the model call with a plain JS promise and
/// aborts objects mid-run; a D1 resolution that leads straight into that
/// park is torn down as a kj "Promise callback destroyed itself" fatal.
/// Production model calls are real subrequests, so this is a harness
/// constraint, but every call site keeps the order so the suites stay green.
#[cfg(target_arch = "wasm32")]
pub async fn bump(env: &worker::Env, deltas: &[(&str, i64)]) {
    let Ok(db) = env.d1(crate::worker_app::TRANSCRIPT_ANALYSIS_DB) else {
        return;
    };
    bump_db(&db, deltas).await;
}

/// Best-effort bump against an already-resolved database handle.
#[cfg(target_arch = "wasm32")]
pub async fn bump_db(db: &D1Database, deltas: &[(&str, i64)]) {
    let now = (worker::Date::now().as_millis() / 1_000)
        .try_into()
        .unwrap_or(i64::MAX);
    increment_counters(db, deltas, now).await.ok();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::GeminiUsage;

    #[test]
    fn spend_deltas_cover_attempts_and_every_token_bucket() {
        let stats = AnalysisRunStats {
            attempts: 2,
            usage: Some(GeminiUsage {
                prompt_token_count: 120,
                candidates_token_count: 40,
                thoughts_token_count: 300,
                total_token_count: 460,
            }),
        };
        assert_eq!(
            spend_deltas(&stats),
            vec![
                (ANALYSIS_ATTEMPTS, 2),
                (PROMPT_TOKENS, 120),
                (CANDIDATES_TOKENS, 40),
                (THOUGHTS_TOKENS, 300),
                (TOTAL_TOKENS, 460),
            ]
        );
    }

    #[test]
    fn spend_deltas_without_usage_record_attempts_only() {
        // A run whose every transport attempt failed reports the attempts it
        // made and no token figures (unknown, never zero).
        let stats = AnalysisRunStats {
            attempts: 1,
            usage: None,
        };
        assert_eq!(spend_deltas(&stats), vec![(ANALYSIS_ATTEMPTS, 1)]);
    }

    #[test]
    fn spend_deltas_clamp_absurd_token_counts() {
        let stats = AnalysisRunStats {
            attempts: 1,
            usage: Some(GeminiUsage {
                prompt_token_count: u64::MAX,
                candidates_token_count: 0,
                thoughts_token_count: 0,
                total_token_count: u64::MAX,
            }),
        };
        let deltas = spend_deltas(&stats);
        assert!(deltas.contains(&(PROMPT_TOKENS, i64::MAX)));
        assert!(deltas.contains(&(TOTAL_TOKENS, i64::MAX)));
    }

    #[test]
    fn upsert_sql_numbers_placeholders_per_row() {
        assert_eq!(
            upsert_sql(2),
            "INSERT INTO counters (name, value, updated_at) VALUES (?1, ?2, ?3), (?4, ?5, ?6) \
             ON CONFLICT(name) DO UPDATE SET \
             value = counters.value + excluded.value, \
             updated_at = excluded.updated_at"
        );
    }

    #[test]
    fn vocabulary_is_unique() {
        let names = [
            JOBS_STARTED,
            JOBS_COMPLETED,
            JOBS_FAILED_UPSTREAM,
            JOBS_FAILED_TRANSIENT,
            SYNC_ANALYSES,
            ANALYSIS_ATTEMPTS,
            PROMPT_TOKENS,
            CANDIDATES_TOKENS,
            THOUGHTS_TOKENS,
            TOTAL_TOKENS,
            CAP_DENIALS_BEARER,
            CAP_DENIALS_APP_ATTEST,
            CAP_DENIALS_GLOBAL,
            BOOTSTRAP_REQUIRED_DENIALS,
            RESERVE_DENIED_INSUFFICIENT,
            RESERVE_DENIED_BOOTSTRAP,
            BILLING_UNAVAILABLE,
            BILLING_RETRIES,
            SETTLE_ABANDONED,
            RELEASE_ABANDONED,
            SETTLED_JOBS,
            CHARGED_CREDIT_SECONDS,
            RELEASED_CREDIT_SECONDS,
        ];
        let unique: std::collections::BTreeSet<&str> = names.iter().copied().collect();
        assert_eq!(unique.len(), names.len());
        for name in names {
            assert!(name.chars().all(|c| c.is_ascii_lowercase() || c == '_'));
        }
    }
}

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
/// Submit attempts that exited before the run-start boundary and gave every
/// confirmed limiter admission back (a per-device release after a global
/// refusal counts; partial cleanup does not).
pub const ADMISSION_RELEASES: &str = "admission_releases";
/// Limiter scopes whose release was refused or whose response was lost —
/// one per scope, so a single attempt can add two. Each leaves usage
/// charged until the day's object expires.
pub const ADMISSION_RELEASE_FAILURES: &str = "admission_release_failures";

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

// Ladder shape, per run (folded through `spend_deltas`, so they land in the
// same D1 write as the attempt and token counters).
/// Model calls that hit their deadline and were aborted. Such a call reports
/// no usage, so it is invisible to the token counters even when the
/// upstream billed the generation it abandoned.
pub const GEMINI_CALL_TIMEOUTS: &str = "gemini_call_timeouts";
/// Identical-payload resends inside the transport ladder.
pub const TRANSPORT_RETRIES: &str = "transport_retries";
/// Runs the run budget ended before their attempts were used up.
pub const ANALYSIS_BUDGET_EXHAUSTED: &str = "analysis_budget_exhausted";
/// Attempts whose reply came back and was rejected, then one class per
/// rejected attempt (the classes partition `rejected_attempts`).
pub const REJECTED_ATTEMPTS: &str = "rejected_attempts";
pub const REJECTED_ID_DISCIPLINE: &str = "rejected_id_discipline";
pub const REJECTED_CHAPTERS: &str = "rejected_chapters";
pub const REJECTED_SUMMARY: &str = "rejected_summary";
pub const REJECTED_CLAIMS: &str = "rejected_claims";
pub const REJECTED_PARSE: &str = "rejected_parse";
pub const REJECTED_TRUNCATED: &str = "rejected_truncated";
pub const REJECTED_OTHER: &str = "rejected_other";

// Terminal failure codes, bumped beside `jobs_failed_upstream` (async) or
// `sync_analyses` (inline) so the dashboard sees which code ended a run.
// The codes themselves live only in the purged job record and the poll
// body; this is the only durable per-code record.
pub const FAILED_GEMINI_TIMEOUT: &str = "failed_gemini_timeout";
pub const FAILED_GEMINI_HTTP_ERROR: &str = "failed_gemini_http_error";
pub const FAILED_GEMINI_RETRY_EXHAUSTED: &str = "failed_gemini_retry_exhausted";
pub const FAILED_GEMINI_QUOTA_EXHAUSTED: &str = "failed_gemini_quota_exhausted";
pub const FAILED_WORKER_FETCH_ERROR: &str = "failed_worker_fetch_error";
pub const FAILED_INVALID_MODEL_OUTPUT: &str = "failed_invalid_model_output";
pub const FAILED_MODEL_OUTPUT_TRUNCATED: &str = "failed_model_output_truncated";
pub const FAILED_RESULT_OVERSIZED: &str = "failed_result_oversized";
pub const FAILED_JOB_TASK_FAILED: &str = "failed_job_task_failed";
/// Every other terminal code (`worker_secret_missing`, `gemini_payload_error`,
/// `gemini_response_oversized`, `gemini_response_encoding`,
/// `transcript_too_long`, ...): rare local or configuration failures that
/// need the logs, not their own row.
pub const FAILED_OTHER: &str = "failed_other";

/// The counter a terminal failure code bumps, with `failed_other` as the
/// fallback for every code without a row of its own.
pub fn failure_code_counter(code: &str) -> &'static str {
    match code {
        "gemini_timeout" => FAILED_GEMINI_TIMEOUT,
        "gemini_http_error" => FAILED_GEMINI_HTTP_ERROR,
        "gemini_retry_exhausted" => FAILED_GEMINI_RETRY_EXHAUSTED,
        "gemini_quota_exhausted" => FAILED_GEMINI_QUOTA_EXHAUSTED,
        "worker_fetch_error" => FAILED_WORKER_FETCH_ERROR,
        "invalid_model_output" => FAILED_INVALID_MODEL_OUTPUT,
        "model_output_truncated" => FAILED_MODEL_OUTPUT_TRUNCATED,
        "result_oversized" => FAILED_RESULT_OVERSIZED,
        "job_task_failed" => FAILED_JOB_TASK_FAILED,
        _ => FAILED_OTHER,
    }
}

/// One D1 write covering every counter of a run's model spend and ladder
/// shape. The ladder counters are appended only when non-zero: a clean run
/// writes exactly the rows it always did.
pub fn spend_deltas(stats: &AnalysisRunStats) -> Vec<(&'static str, i64)> {
    let mut deltas = vec![(ANALYSIS_ATTEMPTS, i64::from(stats.attempts))];
    if let Some(usage) = &stats.usage {
        deltas.push((PROMPT_TOKENS, clamp_u64(usage.prompt_token_count)));
        deltas.push((CANDIDATES_TOKENS, clamp_u64(usage.candidates_token_count)));
        deltas.push((THOUGHTS_TOKENS, clamp_u64(usage.thoughts_token_count)));
        deltas.push((TOTAL_TOKENS, clamp_u64(usage.total_token_count)));
    }
    let rejected = &stats.rejected;
    let ladder: [(&'static str, u32); 11] = [
        (GEMINI_CALL_TIMEOUTS, stats.gemini_call_timeouts),
        (TRANSPORT_RETRIES, stats.transport_retries),
        (ANALYSIS_BUDGET_EXHAUSTED, u32::from(stats.budget_exhausted)),
        (REJECTED_ATTEMPTS, rejected.total),
        (REJECTED_ID_DISCIPLINE, rejected.id_discipline),
        (REJECTED_CHAPTERS, rejected.chapters),
        (REJECTED_SUMMARY, rejected.summary),
        (REJECTED_CLAIMS, rejected.claims),
        (REJECTED_PARSE, rejected.parse),
        (REJECTED_TRUNCATED, rejected.truncated),
        (REJECTED_OTHER, rejected.other),
    ];
    for (name, value) in ladder {
        if value > 0 {
            deltas.push((name, i64::from(value)));
        }
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ADMISSION_RELEASES,
            ADMISSION_RELEASE_FAILURES,
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
            GEMINI_CALL_TIMEOUTS,
            TRANSPORT_RETRIES,
            ANALYSIS_BUDGET_EXHAUSTED,
            REJECTED_ATTEMPTS,
            REJECTED_ID_DISCIPLINE,
            REJECTED_CHAPTERS,
            REJECTED_SUMMARY,
            REJECTED_CLAIMS,
            REJECTED_PARSE,
            REJECTED_TRUNCATED,
            REJECTED_OTHER,
            FAILED_GEMINI_TIMEOUT,
            FAILED_GEMINI_HTTP_ERROR,
            FAILED_GEMINI_RETRY_EXHAUSTED,
            FAILED_GEMINI_QUOTA_EXHAUSTED,
            FAILED_WORKER_FETCH_ERROR,
            FAILED_INVALID_MODEL_OUTPUT,
            FAILED_MODEL_OUTPUT_TRUNCATED,
            FAILED_RESULT_OVERSIZED,
            FAILED_JOB_TASK_FAILED,
            FAILED_OTHER,
        ];
        assert_eq!(names.len(), 46);
        let unique: std::collections::BTreeSet<&str> = names.iter().copied().collect();
        assert_eq!(unique.len(), names.len());
        for name in names {
            assert!(name.chars().all(|c| c.is_ascii_lowercase() || c == '_'));
        }
    }

    #[test]
    fn spend_deltas_cover_every_ladder_field_and_omit_zeros() {
        let mut stats = AnalysisRunStats {
            attempts: 3,
            usage: None,
            gemini_call_timeouts: 2,
            transport_retries: 4,
            budget_exhausted: true,
            ..Default::default()
        };
        stats
            .rejected
            .record_validation(&["chapter_order", "id_discipline"]);
        stats.rejected.record_validation(&["summary_length"]);
        stats
            .rejected
            .record_parse(&crate::gemini::GeminiParseError::MaxTokensTruncated);
        stats
            .rejected
            .record_parse(&crate::gemini::GeminiParseError::MalformedModelJson);
        stats.rejected.record_validation(&["claims_count"]);
        stats.rejected.record_validation(&["no_urls"]);
        stats.rejected.record_validation(&["chapter_title"]);
        assert_eq!(
            spend_deltas(&stats),
            vec![
                (ANALYSIS_ATTEMPTS, 3),
                (GEMINI_CALL_TIMEOUTS, 2),
                (TRANSPORT_RETRIES, 4),
                (ANALYSIS_BUDGET_EXHAUSTED, 1),
                (REJECTED_ATTEMPTS, 7),
                (REJECTED_ID_DISCIPLINE, 1),
                (REJECTED_CHAPTERS, 1),
                (REJECTED_SUMMARY, 1),
                (REJECTED_CLAIMS, 1),
                (REJECTED_PARSE, 1),
                (REJECTED_TRUNCATED, 1),
                (REJECTED_OTHER, 1),
            ]
        );
        // The classes partition the rejected attempts, delta by delta.
        let deltas = spend_deltas(&stats);
        let total = deltas
            .iter()
            .find(|(name, _)| *name == REJECTED_ATTEMPTS)
            .map_or(0, |(_, value)| *value);
        let classes: i64 = deltas
            .iter()
            .filter(|(name, _)| name.starts_with("rejected_") && *name != REJECTED_ATTEMPTS)
            .map(|(_, value)| *value)
            .sum();
        assert_eq!(total, classes);

        // A clean run writes exactly the rows it always did.
        let clean = AnalysisRunStats {
            attempts: 1,
            usage: None,
            ..Default::default()
        };
        assert_eq!(spend_deltas(&clean), vec![(ANALYSIS_ATTEMPTS, 1)]);
    }

    #[test]
    fn every_terminal_code_maps_to_a_failure_counter() {
        let named = [
            ("gemini_timeout", FAILED_GEMINI_TIMEOUT),
            ("gemini_http_error", FAILED_GEMINI_HTTP_ERROR),
            ("gemini_retry_exhausted", FAILED_GEMINI_RETRY_EXHAUSTED),
            ("gemini_quota_exhausted", FAILED_GEMINI_QUOTA_EXHAUSTED),
            ("worker_fetch_error", FAILED_WORKER_FETCH_ERROR),
            ("invalid_model_output", FAILED_INVALID_MODEL_OUTPUT),
            ("model_output_truncated", FAILED_MODEL_OUTPUT_TRUNCATED),
            ("result_oversized", FAILED_RESULT_OVERSIZED),
            ("job_task_failed", FAILED_JOB_TASK_FAILED),
        ];
        for (code, counter) in named {
            assert_eq!(failure_code_counter(code), counter, "{code}");
            assert_eq!(counter, format!("failed_{code}"));
        }
        for code in [
            "worker_secret_missing",
            "gemini_payload_error",
            "gemini_response_oversized",
            "gemini_response_encoding",
            "transcript_too_long",
            "",
        ] {
            assert_eq!(failure_code_counter(code), FAILED_OTHER, "{code}");
        }
    }
}

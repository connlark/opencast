//! Dispatcher predicates and the one-minute rollup. Lifted out of the
//! wasm-only `dispatch.rs` so host tests can pin results and plans.
//! The texts are frozen by the 2026-10-08 D1 efficiency plan: change one only with a fresh equivalence validation.

pub(crate) const ELIGIBLE: &str = "f.admission_paused=0 AND f.no_interest_since IS NULL AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1)";

// All lateness readers use this predicate, including origin cooldowns.
pub(crate) const HEALTHY: &str = "f.poll_failures=0 AND f.handling_failures=0 AND f.retry_at<=?1 AND NOT EXISTS(SELECT 1 FROM n_poll_origin h WHERE h.origin_key=f.origin_key AND h.cooldown_until>?1)";

/// Recurring scan admission: due within the tick, publisher backoff over, origin not cooling.
pub(crate) const SCAN_DUE: &str = "f.due_at<=?1+30 AND f.retry_at<=?1 AND NOT EXISTS(SELECT 1 FROM n_poll_origin h WHERE h.origin_key=f.origin_key AND h.cooldown_until>?1)";

/// Shared by dispatch, stats and the independent watchdog. `?1` is now.
pub(crate) fn late_scanned(seconds: i64) -> String {
    format!("{ELIGIBLE} AND {HEALTHY} AND f.snapshot_key IS NOT NULL AND f.due_at<?1-{seconds}")
}

/// The one-minute cost/lag rollup: one materialized pass over `n_feed`, so the
/// eligibility, health and cooldown probes run once per row. `?1` is now.
pub(crate) fn rollup() -> String {
    format!("WITH f AS MATERIALIZED (SELECT f.due_at,f.snapshot_key,f.dispatch_until,f.last_poll_at,f.last_poll_outcome,({ELIGIBLE}) AS eligible,({HEALTHY}) AS healthy,({SCAN_DUE}) AS scan_due FROM n_feed f) SELECT COUNT(*) FILTER (WHERE eligible AND due_at<=?1) AS overdue,COUNT(*) FILTER (WHERE eligible AND due_at<=?1 AND healthy) AS healthy_overdue,COALESCE(MAX(?1-due_at) FILTER (WHERE eligible AND due_at<=?1 AND healthy),0) AS oldest_due_seconds,COUNT(*) FILTER (WHERE eligible AND healthy AND snapshot_key IS NOT NULL AND due_at<?1-600) AS late_600,COUNT(*) FILTER (WHERE eligible AND healthy AND snapshot_key IS NULL AND due_at<?1-600) AS late_baselines,COUNT(*) FILTER (WHERE dispatch_until>?1) AS in_flight,COUNT(*) FILTER (WHERE eligible AND dispatch_until=0 AND scan_due) AS admission_deferred,COUNT(*) FILTER (WHERE last_poll_at>?1-60 AND last_poll_outcome IN('not_modified','unchanged')) AS unchanged_last_minute,COUNT(*) FILTER (WHERE last_poll_at>?1-60 AND last_poll_outcome='published') AS published_last_minute,COUNT(*) FILTER (WHERE last_poll_at>?1-60 AND last_poll_outcome NOT IN('not_modified','unchanged','published')) AS failed_last_minute,COUNT(*) FILTER (WHERE last_poll_at>?1-300 AND last_poll_outcome IN('not_modified','unchanged','published')) AS completed_last_5min FROM f")
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use crate::test_schema::{connection, plan};
    use rusqlite::{params, Connection};

    const T0: i64 = 1_800_000_000;
    /// `?1 = T0 + offset`. T0 puts every boundary row below on its edge; +1
    /// moves each `==now` row into the past; ±600, +30, −60 and −300 slide the
    /// due and last-poll grids across the late, admission and recent windows.
    const OFFSETS: [i64; 7] = [0, 1, -600, 600, 30, -60, -300];
    const FIELDS: [&str; 11] = [
        "overdue",
        "healthy_overdue",
        "oldest_due_seconds",
        "late_600",
        "late_baselines",
        "in_flight",
        "admission_deferred",
        "unchanged_last_minute",
        "published_last_minute",
        "failed_last_minute",
        "completed_last_5min",
    ];

    /// The pre-2026-10-08 eleven-subquery rollup, verbatim from `run_dispatch`,
    /// with the same substitutions: the oracle for `rollup()`.
    fn legacy_rollup() -> String {
        let scan_due = SCAN_DUE;
        let base = format!("{ELIGIBLE} AND f.dispatch_until=0 AND {scan_due}");
        let late = late_scanned(600);
        format!("SELECT (SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND f.due_at<=?1) AS overdue,(SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND f.due_at<=?1 AND {HEALTHY}) AS healthy_overdue,(SELECT COALESCE(MAX(?1-f.due_at),0) FROM n_feed f WHERE {ELIGIBLE} AND f.due_at<=?1 AND {HEALTHY}) AS oldest_due_seconds,(SELECT COUNT(*) FROM n_feed f WHERE {late}) AS late_600,(SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND {HEALTHY} AND f.snapshot_key IS NULL AND f.due_at<?1-600) AS late_baselines,(SELECT COUNT(*) FROM n_feed f WHERE f.dispatch_until>?1) AS in_flight,(SELECT COUNT(*) FROM n_feed f WHERE {base}) AS admission_deferred,(SELECT COUNT(*) FROM n_feed f WHERE f.last_poll_at>?1-60 AND f.last_poll_outcome IN('not_modified','unchanged')) AS unchanged_last_minute,(SELECT COUNT(*) FROM n_feed f WHERE f.last_poll_at>?1-60 AND f.last_poll_outcome='published') AS published_last_minute,(SELECT COUNT(*) FROM n_feed f WHERE f.last_poll_at>?1-60 AND f.last_poll_outcome NOT IN('not_modified','unchanged','published')) AS failed_last_minute,(SELECT COUNT(*) FROM n_feed f WHERE f.last_poll_at>?1-300 AND f.last_poll_outcome IN('not_modified','unchanged','published')) AS completed_last_5min")
    }

    // Feed-shape axes, crossed in full.
    const PAUSED: [i64; 2] = [0, 1];
    /// (install, interest enabled): none, enabled, disabled interest, disabled install.
    const INTEREST: [Option<(&str, i64)>; 4] = [
        None,
        Some(("install-enabled", 1)),
        Some(("install-enabled", 0)),
        Some(("install-disabled", 1)),
    ];
    const NO_INTEREST_SINCE: [Option<i64>; 2] = [None, Some(T0 - 3600)];
    /// (poll_failures, handling_failures).
    const FAILURES: [(i64, i64); 3] = [(0, 0), (1, 0), (0, 1)];
    const RETRY_AT: [i64; 3] = [T0 - 1, T0, T0 + 1];
    /// No origin, an origin cooling until T0+1, an origin whose cooldown ends at T0.
    const ORIGIN: [Option<&str>; 3] = [None, Some("origin-cooling"), Some("origin-expired")];
    const DUE_AT: [i64; 6] = [T0 - 601, T0 - 600, T0 - 599, T0, T0 + 30, T0 + 31];
    const SNAPSHOT: [bool; 2] = [false, true];
    const DISPATCH_UNTIL: [i64; 4] = [0, T0 - 1, T0, T0 + 1];
    // Poll-outcome axes, crossed with each other and zipped onto the shapes:
    // no rollup field combines them with a feed-shape predicate.
    const LAST_POLL_AT: [Option<i64>; 7] = [
        None,
        Some(T0 - 59),
        Some(T0 - 60),
        Some(T0 - 61),
        Some(T0 - 299),
        Some(T0 - 300),
        Some(T0 - 301),
    ];
    const OUTCOME: [Option<&str>; 6] = [
        None,
        Some("not_modified"),
        Some("unchanged"),
        Some("published"),
        Some("publisher_failed"),
        Some("dead_letter"),
    ];

    /// Seeds in trigger-safe order: `n_feed` (its AFTER INSERT trigger sets
    /// `no_interest_since` when no enabled interest exists), then `n_interest`
    /// (an enabled insert clears it), then the designed `no_interest_since`.
    fn seed_matrix(db: &Connection) -> usize {
        let tx = db.unchecked_transaction().expect("begin seed");
        tx.execute_batch(&format!(
            "INSERT INTO n_install(install_id,epoch,enabled) VALUES('install-enabled',1,1),('install-disabled',1,0); INSERT INTO n_poll_origin(origin_key,cooldown_until,updated_at) VALUES('origin-cooling',{},{T0}),('origin-expired',{T0},{T0})",
            T0 + 1
        ))
        .expect("seed installs and origins");
        let shapes = PAUSED.len()
            * INTEREST.len()
            * NO_INTEREST_SINCE.len()
            * FAILURES.len()
            * RETRY_AT.len()
            * ORIGIN.len()
            * DUE_AT.len()
            * SNAPSHOT.len()
            * DISPATCH_UNTIL.len();
        let mut later = Vec::with_capacity(shapes);
        for i in 0..shapes {
            let mut rest = i;
            let mut pick = |n: usize| {
                let digit = rest % n;
                rest /= n;
                digit
            };
            let paused = PAUSED[pick(PAUSED.len())];
            let interest = INTEREST[pick(INTEREST.len())];
            let no_interest_since = NO_INTEREST_SINCE[pick(NO_INTEREST_SINCE.len())];
            let (poll_failures, handling_failures) = FAILURES[pick(FAILURES.len())];
            let retry_at = RETRY_AT[pick(RETRY_AT.len())];
            let origin = ORIGIN[pick(ORIGIN.len())];
            let due_at = DUE_AT[pick(DUE_AT.len())];
            let snapshot = SNAPSHOT[pick(SNAPSHOT.len())];
            let dispatch_until = DISPATCH_UNTIL[pick(DISPATCH_UNTIL.len())];
            let poll = i % (LAST_POLL_AT.len() * OUTCOME.len());
            let last_poll_at = LAST_POLL_AT[poll % LAST_POLL_AT.len()];
            let outcome = OUTCOME[poll / LAST_POLL_AT.len()];
            let feed = format!("feed-{i:05}");
            tx.execute(
                "INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at,admission_paused,snapshot_key,retry_at,poll_failures,handling_failures,origin_key,dispatch_until,last_poll_at,last_poll_outcome) VALUES(?1,'https://example.com/'||?1,1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                params![
                    feed,
                    due_at,
                    paused,
                    snapshot.then(|| format!("snap-{i}")),
                    retry_at,
                    poll_failures,
                    handling_failures,
                    origin,
                    dispatch_until,
                    last_poll_at,
                    outcome
                ],
            )
            .expect("insert feed");
            later.push((feed, interest, no_interest_since));
        }
        for (feed, interest, _) in &later {
            if let Some((install, enabled)) = interest {
                tx.execute(
                    "INSERT INTO n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at) VALUES(?1,?2,1,?3,?4,?3)",
                    params![install, feed, T0 - 7200, enabled],
                )
                .expect("insert interest");
            }
        }
        for (feed, _, no_interest_since) in &later {
            tx.execute(
                "UPDATE n_feed SET no_interest_since=?2 WHERE feed_id=?1",
                params![feed, no_interest_since],
            )
            .expect("set no_interest_since");
        }
        tx.commit().expect("commit seed");
        shapes
    }

    fn rollup_row(db: &Connection, sql: &str, t: i64) -> Vec<(String, i64)> {
        let mut statement = db.prepare(sql).expect("prepare rollup");
        let names: Vec<String> = statement
            .column_names()
            .into_iter()
            .map(String::from)
            .collect();
        statement
            .query_row(params![t], |row| {
                names
                    .iter()
                    .enumerate()
                    .map(|(i, name)| Ok((name.clone(), row.get::<_, i64>(i)?)))
                    .collect()
            })
            .expect("read rollup")
    }

    #[test]
    fn single_pass_rollup_matches_the_eleven_subquery_rollup() {
        let db = connection();
        let shapes = seed_matrix(&db);
        let unset: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM n_feed WHERE no_interest_since IS NULL",
                [],
                |row| row.get(0),
            )
            .expect("count no_interest_since");
        assert_eq!(
            unset as usize,
            shapes / NO_INTEREST_SINCE.len(),
            "seed order lost the designed no_interest_since"
        );
        let legacy = legacy_rollup();
        let single = rollup();
        for offset in OFFSETS {
            let t = T0 + offset;
            assert_eq!(
                rollup_row(&db, &single, t),
                rollup_row(&db, &legacy, t),
                "rollup differs from the legacy text at ?1=T0{offset:+}"
            );
        }
        let at_t0 = rollup_row(&db, &single, T0);
        assert_eq!(
            at_t0
                .iter()
                .map(|(name, _)| name.as_str())
                .collect::<Vec<_>>(),
            FIELDS
        );
        for (name, value) in &at_t0 {
            assert!(
                *value > 0,
                "{name} is 0 at T0: the matrix does not exercise it"
            );
        }
    }

    #[test]
    fn single_pass_rollup_scans_n_feed_once() {
        let db = connection();
        let lines = plan(&db, &rollup(), &[&T0]);
        assert_eq!(
            lines.iter().filter(|line| line.contains("SCAN f")).count(),
            2,
            "expected the materialize scan and the CTE scan: {lines:?}"
        );
        assert!(
            lines
                .iter()
                .all(|line| line.contains("SCAN f") || !line.contains("SCAN ")),
            "unexpected scan: {lines:?}"
        );
    }

    #[test]
    fn admission_predicate_still_plans_on_n_feed_due() {
        let db = connection();
        let sql = format!("SELECT f.feed_id FROM n_feed f WHERE {ELIGIBLE} AND f.dispatch_until=0 AND f.due_at<=?1+30 AND f.retry_at<=?1");
        let lines = plan(&db, &sql, &[&T0]);
        assert!(
            lines.iter().any(|line| line.contains("n_feed_due")),
            "expected n_feed_due: {lines:?}"
        );
    }
}

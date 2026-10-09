//! Retention and no-interest expiry SQL. Lifted out of the wasm-only callers
//! (`gc.rs`, `delivery::recovery`) so host tests can pin results and plans.
//! The texts are frozen by the 2026-10-08 D1 efficiency plan: change one only with a fresh equivalence validation.

/// History expiry: 30 days without an enabled interest and no live lease. `?1` is now.
pub(crate) const NO_INTEREST_EXPIRED: &str = "SELECT feed_id FROM n_feed f WHERE no_interest_since<=?1-2592000 AND NOT EXISTS(SELECT 1 FROM n_interest j WHERE j.feed_id=f.feed_id AND j.enabled=1) AND (f.lease_id IS NULL OR f.lease_until<=?1) ORDER BY no_interest_since,feed_id LIMIT 20";
/// Seven-day observation history. The lease arm is one set per statement;
/// `n_feed`'s lease CHECK keeps `NOT IN` NULL-safe. `?1` is now.
pub(crate) const RETIRE_OBSERVATIONS: &str = "DELETE FROM n_observation WHERE observation_id IN(SELECT o.observation_id FROM n_observation o WHERE o.scan_started_at<=?1-604800 AND (o.state<>'published' OR o.drain_complete=1) AND NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.snapshot_key=o.snapshot_key) AND o.lease_id NOT IN(SELECT f.lease_id FROM n_feed f WHERE f.lease_until>?1) AND NOT EXISTS(SELECT 1 FROM n_episode_release r WHERE r.observation_id=o.observation_id) AND NOT EXISTS(SELECT 1 FROM n_outbox x WHERE x.observation_id=o.observation_id) LIMIT 1000)";
pub(crate) const RETIRE_SNAPSHOT_REFS: &str = "DELETE FROM n_snapshot_ref WHERE manifest_key IN(SELECT object_key FROM n_snapshot s WHERE state='deleted' AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.snapshot_key=s.object_key) LIMIT 1000)";
pub(crate) const RETIRE_SNAPSHOTS: &str = "DELETE FROM n_snapshot WHERE object_key IN(SELECT object_key FROM n_snapshot s WHERE state='deleted' AND NOT EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.manifest_key=s.object_key) AND NOT EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.page_key=s.object_key) AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.snapshot_key=s.object_key) LIMIT 2000)";
/// Empty identities 30 days after their last interest. `?1` is now minus the tombstone window.
pub(crate) const NO_INTEREST_PRUNE: &str = "SELECT feed_id FROM n_feed f WHERE no_interest_since<?1 AND NOT EXISTS(SELECT 1 FROM n_interest WHERE feed_id=f.feed_id AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_event WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE interest_key=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_snapshot WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_observation WHERE feed_id=f.feed_id) ORDER BY no_interest_since LIMIT 100";

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use crate::test_schema::{connection, plan};
    use rusqlite::{params, Connection};
    use std::collections::BTreeSet;

    const NOW: i64 = 1_800_000_000;
    const WEEK: i64 = 604_800;
    const OLD: i64 = NOW - WEEK - 1;

    /// The pre-2026-10-08 `gc.rs` texts, verbatim: the same fixture must give
    /// the same survivors before and after the rewrite.
    const LEGACY_RETIRE_OBSERVATIONS: &str = "DELETE FROM n_observation WHERE observation_id IN(SELECT o.observation_id FROM n_observation o WHERE o.scan_started_at<=?1-604800 AND (o.state<>'published' OR o.drain_complete=1) AND NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.snapshot_key=o.snapshot_key OR (f.lease_id=o.lease_id AND f.lease_until>?1)) AND NOT EXISTS(SELECT 1 FROM n_episode_release r WHERE r.observation_id=o.observation_id) AND NOT EXISTS(SELECT 1 FROM n_outbox x WHERE x.observation_id=o.observation_id) LIMIT 1000)";
    const LEGACY_RETIRE_SNAPSHOTS: &str = "DELETE FROM n_snapshot WHERE object_key IN(SELECT object_key FROM n_snapshot s WHERE state='deleted' AND NOT EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.manifest_key=s.object_key OR r.page_key=s.object_key) AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.snapshot_key=s.object_key) LIMIT 2000)";

    /// (feed, lease_id, lease_until, snapshot_key).
    type Feed = (
        &'static str,
        Option<&'static str>,
        Option<i64>,
        Option<&'static str>,
    );
    /// Observations without their own retaining feed live on `feed-quiet`.
    const FEEDS: [Feed; 7] = [
        ("feed-quiet", None, None, None),
        (
            "feed-own-snapshot",
            None,
            None,
            Some("snap-retained_by_own_feed_snapshot"),
        ),
        (
            "feed-other-snapshot",
            None,
            None,
            Some("snap-retained_by_other_feed_snapshot"),
        ),
        (
            "feed-own-lease",
            Some("lease-retained_by_own_live_lease"),
            Some(NOW + 60),
            None,
        ),
        (
            "feed-other-lease",
            Some("lease-retained_by_other_live_lease"),
            Some(NOW + 60),
            None,
        ),
        (
            "feed-expired-lease",
            Some("lease-deletable_expired_lease"),
            Some(NOW - 1),
            None,
        ),
        (
            "feed-lease-until-now",
            Some("lease-deletable_lease_until_now"),
            Some(NOW),
            None,
        ),
    ];

    struct Case {
        name: &'static str,
        feed: &'static str,
        state: &'static str,
        drain_complete: i64,
        scan_started_at: i64,
        snapshot_state: &'static str,
        retained: bool,
    }

    /// Each observation's lease is `lease-<name>` and its snapshot `snap-<name>`.
    const CASES: [Case; 15] = [
        Case {
            name: "retained_by_own_feed_snapshot",
            feed: "feed-own-snapshot",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "referenced",
            retained: true,
        },
        Case {
            name: "retained_by_other_feed_snapshot",
            feed: "feed-quiet",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "referenced",
            retained: true,
        },
        Case {
            name: "retained_by_own_live_lease",
            feed: "feed-own-lease",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "referenced",
            retained: true,
        },
        Case {
            name: "retained_by_other_live_lease",
            feed: "feed-quiet",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "referenced",
            retained: true,
        },
        Case {
            name: "deletable_expired_lease",
            feed: "feed-expired-lease",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "deleted",
            retained: false,
        },
        Case {
            name: "deletable_lease_until_now",
            feed: "feed-lease-until-now",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "deleted",
            retained: false,
        },
        // Its feed holds a different live lease: the arm matches lease ids, not feeds.
        Case {
            name: "deletable_superseded_lease",
            feed: "feed-own-lease",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "deleted",
            retained: false,
        },
        Case {
            name: "retained_by_episode_release",
            feed: "feed-quiet",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "referenced",
            retained: true,
        },
        Case {
            name: "retained_by_outbox",
            feed: "feed-quiet",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "referenced",
            retained: true,
        },
        Case {
            name: "retained_published_undrained",
            feed: "feed-quiet",
            state: "published",
            drain_complete: 0,
            scan_started_at: OLD,
            snapshot_state: "referenced",
            retained: true,
        },
        // A deleted manifest an observation still holds, with a page ref.
        Case {
            name: "retained_younger_than_seven_days",
            feed: "feed-quiet",
            state: "published",
            drain_complete: 1,
            scan_started_at: NOW - WEEK + 1,
            snapshot_state: "deleted",
            retained: true,
        },
        Case {
            name: "deletable_exactly_seven_days",
            feed: "feed-quiet",
            state: "published",
            drain_complete: 1,
            scan_started_at: NOW - WEEK,
            snapshot_state: "deleted",
            retained: false,
        },
        // A deleted manifest with a page ref, released with its observation.
        Case {
            name: "deletable_published_drained",
            feed: "feed-quiet",
            state: "published",
            drain_complete: 1,
            scan_started_at: OLD,
            snapshot_state: "deleted",
            retained: false,
        },
        // Its snapshot is not in the deleted state, so it outlives the row.
        Case {
            name: "deletable_staging",
            feed: "feed-quiet",
            state: "staging",
            drain_complete: 0,
            scan_started_at: OLD,
            snapshot_state: "uploaded",
            retained: false,
        },
        Case {
            name: "deletable_abandoned",
            feed: "feed-quiet",
            state: "abandoned",
            drain_complete: 0,
            scan_started_at: OLD,
            snapshot_state: "deleted",
            retained: false,
        },
    ];

    /// Snapshots outside the observations: (key, state).
    const EXTRA_SNAPSHOTS: [(&str, &str); 4] = [
        ("page-held", "deleted"),
        ("page-orphan", "deleted"),
        ("manifest-live", "referenced"),
        ("page-shared", "deleted"),
    ];
    const REFS: [(&str, &str); 3] = [
        ("snap-retained_younger_than_seven_days", "page-held"),
        ("snap-deletable_published_drained", "page-orphan"),
        ("manifest-live", "page-shared"),
    ];

    fn seed() -> Connection {
        let db = connection();
        for (feed, lease_id, lease_until, snapshot_key) in FEEDS {
            db.execute(
                "INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at,lease_id,lease_until,snapshot_key) VALUES(?1,'https://example.com/'||?1,1,?2,?3,?4,?5)",
                params![feed, NOW, lease_id, lease_until, snapshot_key],
            )
            .expect("insert feed");
        }
        let snapshot = |key: &str, feed: &str, state: &str| {
            db.execute(
                "INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) VALUES(?1,?2,1,'lease-'||?1,'sha',1,?3,?4,?4)",
                params![key, feed, state, OLD],
            )
            .expect("insert snapshot");
        };
        for case in &CASES {
            snapshot(
                &format!("snap-{}", case.name),
                case.feed,
                case.snapshot_state,
            );
            db.execute(
                "INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,candidate_count,state,drain_complete) VALUES(?1,?2,1,1,'lease-'||?1,0,'snap-'||?1,?3,0,?4,?5)",
                params![case.name, case.feed, case.scan_started_at, case.state, case.drain_complete],
            )
            .expect("insert observation");
        }
        for (key, state) in EXTRA_SNAPSHOTS {
            snapshot(key, "feed-quiet", state);
        }
        for (manifest, page) in REFS {
            db.execute(
                "INSERT INTO n_snapshot_ref(manifest_key,page_key) VALUES(?1,?2)",
                params![manifest, page],
            )
            .expect("insert snapshot ref");
        }
        db.execute(
            "INSERT INTO n_episode_release(feed_id,episode_id,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,metadata_json,state) VALUES('feed-quiet','episode-1','retained_by_episode_release',1,1,'event-1','presentation-1',?1,?1,?2,'new','{}','outboxed')",
            params![OLD, NOW + WEEK],
        )
        .expect("insert episode release");
        db.execute_batch(&format!(
            "INSERT INTO n_outbox(source,event_id,observation_id,payload_digest,occurred_at,expires_at,next_attempt_at,state) VALUES('feed_polling','event-linked','retained_by_outbox','digest',{OLD},{},0,'accepted'),('feed_polling','event-unlinked',NULL,'digest',{OLD},{},0,'accepted')",
            NOW + WEEK,
            NOW + WEEK
        ))
        .expect("insert outbox rows");
        db
    }

    fn keys(db: &Connection, sql: &str) -> BTreeSet<String> {
        let mut statement = db.prepare(sql).expect("prepare key list");
        statement
            .query_map([], |row| row.get::<_, String>(0))
            .expect("list keys")
            .collect::<rusqlite::Result<_>>()
            .expect("read keys")
    }

    fn observations(db: &Connection) -> BTreeSet<String> {
        keys(db, "SELECT observation_id FROM n_observation")
    }

    fn assert_survivors(db: &Connection, statement: &str) {
        db.execute(statement, params![NOW])
            .expect("retire observations");
        let survivors = observations(db);
        for case in &CASES {
            assert_eq!(
                survivors.contains(case.name),
                case.retained,
                "{}: expected {}",
                case.name,
                if case.retained { "retained" } else { "deleted" }
            );
        }
    }

    #[test]
    fn retention_retires_exactly_the_deletable_observations_then_their_snapshots() {
        let legacy = seed();
        assert_survivors(&legacy, LEGACY_RETIRE_OBSERVATIONS);
        legacy
            .execute(RETIRE_SNAPSHOT_REFS, [])
            .expect("legacy retire snapshot refs");
        legacy
            .execute(LEGACY_RETIRE_SNAPSHOTS, [])
            .expect("legacy retire snapshots");

        let db = seed();
        assert_eq!(
            db.pragma_query_value(None, "foreign_keys", |row| row.get::<_, i64>(0))
                .expect("read foreign_keys"),
            1,
            "the FK checks on n_outbox and n_episode_release must be live"
        );
        assert_survivors(&db, RETIRE_OBSERVATIONS);
        assert_eq!(
            observations(&db),
            observations(&legacy),
            "survivors differ from the legacy statement"
        );

        assert_eq!(
            db.execute(RETIRE_SNAPSHOT_REFS, [])
                .expect("retire snapshot refs"),
            1
        );
        let refs = keys(
            &db,
            "SELECT manifest_key||'>'||page_key FROM n_snapshot_ref",
        );
        let expected: BTreeSet<String> = [
            "snap-retained_younger_than_seven_days>page-held",
            "manifest-live>page-shared",
        ]
        .map(String::from)
        .into();
        assert_eq!(refs, expected, "only the released manifest's ref goes");

        let before = keys(&db, "SELECT object_key FROM n_snapshot");
        db.execute(RETIRE_SNAPSHOTS, []).expect("retire snapshots");
        let after = keys(&db, "SELECT object_key FROM n_snapshot");
        let gone: BTreeSet<String> = before.difference(&after).cloned().collect();
        let mut expected: BTreeSet<String> = CASES
            .iter()
            .filter(|case| !case.retained && case.snapshot_state == "deleted")
            .map(|case| format!("snap-{}", case.name))
            .collect();
        expected.insert("page-orphan".into());
        assert_eq!(
            gone, expected,
            "deleted snapshots with no ref and no observation go; the rest stay"
        );
        assert_eq!(
            after,
            keys(&legacy, "SELECT object_key FROM n_snapshot"),
            "snapshot survivors differ from the legacy statement"
        );
    }

    #[test]
    fn retention_and_expiry_plans_use_their_indexes() {
        let db = connection();
        let observations = plan(&db, RETIRE_OBSERVATIONS, &[&NOW]);
        assert_eq!(
            observations
                .iter()
                .filter(|line| line.contains("SCAN f"))
                .count(),
            1,
            "only the lease set scans n_feed: {observations:?}"
        );
        assert!(
            !observations
                .iter()
                .any(|line| line.contains("SCAN x") || line.contains("SCAN n_outbox")),
            "the outbox check and its FK tail must not scan n_outbox: {observations:?}"
        );
        for index in [
            "n_feed_snapshot",
            "n_episode_release_observation",
            "n_outbox_observation",
        ] {
            assert!(
                observations.iter().any(|line| line.contains(index)),
                "expected {index}: {observations:?}"
            );
        }
        let refs = plan(&db, RETIRE_SNAPSHOT_REFS, &[]);
        assert!(
            !refs.iter().any(|line| line.contains("SCAN")),
            "unexpected scan: {refs:?}"
        );
        let snapshots = plan(&db, RETIRE_SNAPSHOTS, &[]);
        assert!(
            !snapshots.iter().any(|line| line.contains("SCAN")),
            "unexpected scan: {snapshots:?}"
        );
        for sql in [NO_INTEREST_EXPIRED, NO_INTEREST_PRUNE] {
            let lines = plan(&db, sql, &[&NOW]);
            assert!(
                lines.iter().any(|line| line.contains("n_feed_no_interest")),
                "expected n_feed_no_interest: {lines:?}"
            );
        }
    }
}

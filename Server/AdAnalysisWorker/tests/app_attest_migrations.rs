//! Pins this worker's App Attest migration schema against the query shapes
//! in `opencast_app_attest_core::app_attest_storage` (moved there from this
//! worker's former `src/storage.rs`).

#![cfg(not(target_arch = "wasm32"))]

use opencast_app_attest_core::app_attest::challenge_hash;
use opencast_app_attest_core::app_attest_storage::INSERT_CHALLENGE_WITHIN_LIMITS_SQL;
use opencast_app_attest_core::challenge_limits::MAX_CHALLENGES_PER_INSTALL_PER_HOUR;
use rusqlite::{params, Connection};

const NOW: i64 = 1_780_000_000;

fn setup_db() -> Connection {
    let db = Connection::open_in_memory().expect("open in-memory sqlite");
    db.execute_batch(include_str!("../migrations/0001_app_attest_auth.sql"))
        .expect("create app attest auth tables");
    db
}

#[test]
fn migration_supports_challenge_lifecycle_and_rate_queries() {
    let db = setup_db();
    db.execute(
        "INSERT INTO app_attest_challenges \
         (challenge_id, challenge_hash, purpose, install_id, created_at, expires_at) \
         VALUES (?1, ?2, 'register', 'install-a', ?3, ?4)",
        params![
            "challenge-a",
            challenge_hash("plain-challenge"),
            NOW,
            NOW + 600
        ],
    )
    .expect("insert challenge");

    let row = db
        .query_row(
            "SELECT challenge_hash, purpose, install_id, expires_at, consumed_at \
             FROM app_attest_challenges WHERE challenge_id = 'challenge-a'",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                ))
            },
        )
        .expect("read challenge");

    assert_eq!(row.0, challenge_hash("plain-challenge"));
    assert_eq!(row.1, "register");
    assert_eq!(row.2, "install-a");
    assert_eq!(row.3, NOW + 600);
    assert_eq!(row.4, None);

    let changed = db
        .execute(
            "UPDATE app_attest_challenges \
             SET consumed_at = ?1 \
             WHERE challenge_id = ?2 AND consumed_at IS NULL",
            params![NOW + 1, "challenge-a"],
        )
        .expect("consume challenge");
    assert_eq!(changed, 1);
    let changed_again = db
        .execute(
            "UPDATE app_attest_challenges \
             SET consumed_at = ?1 \
             WHERE challenge_id = ?2 AND consumed_at IS NULL",
            params![NOW + 2, "challenge-a"],
        )
        .expect("consume challenge again");
    assert_eq!(changed_again, 0);

    let install_count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM app_attest_challenges \
             WHERE install_id = 'install-a' AND created_at >= ?1",
            params![NOW - 3600],
            |row| row.get(0),
        )
        .expect("count install challenges");
    let global_count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM app_attest_challenges WHERE created_at >= ?1",
            params![NOW - 3600],
            |row| row.get(0),
        )
        .expect("count global challenges");
    assert_eq!(install_count, 1);
    assert_eq!(global_count, 1);
}

fn admit(
    db: &Connection,
    challenge_id: &str,
    install_id: &str,
    install_cap: i64,
    global_cap: i64,
) -> usize {
    db.execute(
        INSERT_CHALLENGE_WITHIN_LIMITS_SQL,
        params![
            challenge_id,
            challenge_hash(challenge_id),
            "register",
            install_id,
            NOW,
            NOW + 600,
            NOW - 3600,
            install_cap,
            global_cap
        ],
    )
    .expect("run atomic admission statement")
}

/// The atomicity proof for triage P2 #5: cap checks and the insert are one
/// statement (the exact production SQL), so admissions at the cap boundary
/// admit exactly the cap — there is no read-then-insert window for
/// concurrent requests to slip through.
#[test]
fn atomic_admission_admits_exactly_the_cap_at_both_boundaries() {
    let db = setup_db();

    // Per-install boundary, production cap: exactly cap admissions land.
    for index in 0..MAX_CHALLENGES_PER_INSTALL_PER_HOUR {
        assert_eq!(
            admit(
                &db,
                &format!("install-cap-{index}"),
                "install-a",
                MAX_CHALLENGES_PER_INSTALL_PER_HOUR,
                1_000,
            ),
            1,
            "admission {index} under the cap must insert"
        );
    }
    assert_eq!(
        admit(
            &db,
            "install-cap-over",
            "install-a",
            MAX_CHALLENGES_PER_INSTALL_PER_HOUR,
            1_000,
        ),
        0,
        "admission at the cap must be held back"
    );
    let install_count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM app_attest_challenges WHERE install_id = 'install-a'",
            [],
            |row| row.get(0),
        )
        .expect("count install rows");
    assert_eq!(install_count, MAX_CHALLENGES_PER_INSTALL_PER_HOUR);

    // A different install is unaffected by the full install bucket.
    assert_eq!(admit(&db, "other-install", "install-b", 20, 1_000), 1);

    // Global boundary (small synthetic cap, same statement).
    let db = setup_db();
    for index in 0..3 {
        assert_eq!(
            admit(
                &db,
                &format!("global-{index}"),
                &format!("install-{index}"),
                20,
                3
            ),
            1
        );
    }
    assert_eq!(admit(&db, "global-over", "install-fresh", 20, 3), 0);

    // Rows outside the hourly window stop counting against the caps.
    db.execute(
        "UPDATE app_attest_challenges SET created_at = ?1",
        params![NOW - 7_200],
    )
    .expect("age out existing rows");
    assert_eq!(admit(&db, "post-window", "install-fresh", 20, 3), 1);
}

#[test]
fn migration_supports_source_bucket_upsert() {
    let db = setup_db();
    for _ in 0..2 {
        db.execute(
            "INSERT INTO app_attest_challenge_source_buckets \
             (source_token, window_start, request_count, updated_at) \
             VALUES (?1, ?2, 1, ?3) \
             ON CONFLICT(source_token, window_start) DO UPDATE SET \
             request_count = app_attest_challenge_source_buckets.request_count + 1, \
             updated_at = excluded.updated_at",
            params!["source-hash", NOW - 120, NOW],
        )
        .expect("upsert source bucket");
    }

    let count: i64 = db
        .query_row(
            "SELECT request_count FROM app_attest_challenge_source_buckets \
             WHERE source_token = 'source-hash'",
            [],
            |row| row.get(0),
        )
        .expect("read bucket count");

    assert_eq!(count, 2);
}

#[test]
fn migration_supports_key_upsert_and_counter_cas() {
    let db = setup_db();
    db.execute(
        "INSERT INTO app_attest_keys \
         (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
         VALUES ('install-a', 'key-a', ?1, 0, 'TEAM.bundle', 'development', ?2, ?2)",
        params![vec![1_u8, 2, 3], NOW],
    )
    .expect("insert key");

    let changed = db
        .execute(
            "UPDATE app_attest_keys \
             SET sign_counter = ?1, last_used_at = ?2 \
             WHERE install_id = ?3 AND key_id = ?4 AND sign_counter = ?5",
            params![1_i64, NOW + 1, "install-a", "key-a", 0_i64],
        )
        .expect("cas counter");
    assert_eq!(changed, 1);

    let replay_changed = db
        .execute(
            "UPDATE app_attest_keys \
             SET sign_counter = ?1, last_used_at = ?2 \
             WHERE install_id = ?3 AND key_id = ?4 AND sign_counter = ?5",
            params![2_i64, NOW + 2, "install-a", "key-a", 0_i64],
        )
        .expect("cas replay");
    assert_eq!(replay_changed, 0);

    let key_count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM app_attest_keys \
             WHERE install_id = 'install-a' AND created_at >= ?1",
            params![NOW - 86_400],
            |row| row.get(0),
        )
        .expect("count keys");
    assert_eq!(key_count, 1);
}

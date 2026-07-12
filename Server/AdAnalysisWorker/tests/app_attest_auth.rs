use opencast_app_attest_core::app_attest::verify_attestation;
use rusqlite::{params, Connection};
use serde::Deserialize;

#[test]
fn register_consumes_valid_challenge_before_attestation_verification() {
    let db = setup_db();
    insert_challenge(
        &db,
        "challenge-a",
        "plain-challenge",
        "register",
        "install-a",
        1_780_000_000,
        1_780_000_600,
    );

    let challenge = read_challenge(&db, "challenge-a").expect("challenge should exist");
    assert_eq!(challenge.install_id, "install-a");
    assert_eq!(challenge.purpose, "register");
    assert_eq!(challenge.consumed_at, None);
    assert_eq!(
        challenge.challenge_hash,
        opencast_app_attest_core::app_attest::challenge_hash("plain-challenge")
    );

    assert_eq!(consume_challenge(&db, "challenge-a", 1_780_000_001), 1);
    assert!(verify_attestation(
        "not-valid-attestation",
        "plain-challenge",
        "TEAM.bundle",
        "not-valid-key",
        "development",
        1_780_000_001,
    )
    .is_err());

    let consumed = read_challenge(&db, "challenge-a").expect("challenge should remain recorded");
    assert_eq!(consumed.consumed_at, Some(1_780_000_001));
    assert_eq!(consume_challenge(&db, "challenge-a", 1_780_000_002), 0);
}

fn setup_db() -> Connection {
    let db = Connection::open_in_memory().expect("open in-memory sqlite");
    db.execute_batch(include_str!("../migrations/0001_app_attest_auth.sql"))
        .expect("create app attest auth tables");
    db
}

#[derive(Deserialize)]
struct ChallengeRow {
    challenge_hash: String,
    purpose: String,
    install_id: String,
    consumed_at: Option<i64>,
}

fn insert_challenge(
    db: &Connection,
    challenge_id: &str,
    challenge: &str,
    purpose: &str,
    install_id: &str,
    created_at: i64,
    expires_at: i64,
) {
    db.execute(
        "INSERT INTO app_attest_challenges \
         (challenge_id, challenge_hash, purpose, install_id, created_at, expires_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            challenge_id,
            opencast_app_attest_core::app_attest::challenge_hash(challenge),
            purpose,
            install_id,
            created_at,
            expires_at
        ],
    )
    .expect("insert challenge");
}

fn read_challenge(db: &Connection, challenge_id: &str) -> Option<ChallengeRow> {
    db.query_row(
        "SELECT challenge_hash, purpose, install_id, consumed_at \
         FROM app_attest_challenges \
         WHERE challenge_id = ?1 \
         LIMIT 1",
        params![challenge_id],
        |row| {
            Ok(ChallengeRow {
                challenge_hash: row.get(0)?,
                purpose: row.get(1)?,
                install_id: row.get(2)?,
                consumed_at: row.get(3)?,
            })
        },
    )
    .ok()
}

fn consume_challenge(db: &Connection, challenge_id: &str, consumed_at: i64) -> usize {
    db.execute(
        "UPDATE app_attest_challenges \
         SET consumed_at = ?1 \
         WHERE challenge_id = ?2 AND consumed_at IS NULL",
        params![consumed_at, challenge_id],
    )
    .expect("consume challenge")
}

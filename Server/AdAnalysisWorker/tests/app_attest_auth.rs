use opencast_app_attest_core::app_attest::{
    request_client_data_hash, verify_assertion, verify_attestation,
};
use rusqlite::{params, Connection};
use serde::Deserialize;

#[derive(Deserialize)]
struct AppAttestFixture {
    app_id: String,
    assertion: String,
    attestation_object: String,
    captured_at_seconds: i64,
    challenge: String,
    client_data_hash_sha256_hex: String,
    environment: String,
    install_id: String,
    key_id: String,
    method: String,
    path: String,
    payload: String,
    previous_counter: u32,
    public_key_sec1_hex: String,
}

#[test]
fn real_development_ad_analysis_fixture_verifies_and_rejects_replay_counter_update() {
    let fixture = load_fixture();
    assert_eq!(fixture.method, "POST");
    assert_eq!(fixture.path, "/v1/ad-analysis/transcript");

    let verified_attestation = verify_attestation(
        &fixture.attestation_object,
        &fixture.challenge,
        &fixture.app_id,
        &fixture.key_id,
        &fixture.environment,
        fixture.captured_at_seconds,
    )
    .expect("real App Attest attestation should verify");

    // Pins the SEC1 public key bytes the workerd integration tests seed
    // directly into local D1 (the fixture's leaf cert is only valid for
    // three days, so integration tests cannot re-run attestation live).
    assert_eq!(
        hex::encode(&verified_attestation.public_key),
        fixture.public_key_sec1_hex
    );

    let client_data_hash =
        request_client_data_hash(&fixture.method, &fixture.path, &fixture.payload);
    assert_eq!(
        hex::encode(client_data_hash),
        fixture.client_data_hash_sha256_hex
    );
    let verified_assertion = verify_assertion(
        &fixture.assertion,
        &client_data_hash,
        &fixture.app_id,
        &verified_attestation.public_key,
        fixture.previous_counter,
    )
    .expect("real App Attest assertion should verify");

    let db = setup_db();
    db.execute(
        "INSERT INTO app_attest_keys \
         (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
         VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6, ?6)",
        params![
            fixture.install_id,
            fixture.key_id,
            verified_attestation.public_key,
            fixture.app_id,
            fixture.environment,
            fixture.captured_at_seconds
        ],
    )
    .expect("insert verified key");

    let accepted = db
        .execute(
            "UPDATE app_attest_keys \
             SET sign_counter = ?1, last_used_at = ?2 \
             WHERE install_id = ?3 AND key_id = ?4 AND sign_counter = ?5",
            params![
                i64::from(verified_assertion.sign_counter),
                fixture.captured_at_seconds + 1,
                fixture.install_id,
                fixture.key_id,
                i64::from(fixture.previous_counter)
            ],
        )
        .expect("accept first assertion counter");
    assert_eq!(accepted, 1);

    let replay = db
        .execute(
            "UPDATE app_attest_keys \
             SET sign_counter = ?1, last_used_at = ?2 \
             WHERE install_id = ?3 AND key_id = ?4 AND sign_counter = ?5",
            params![
                i64::from(verified_assertion.sign_counter),
                fixture.captured_at_seconds + 2,
                fixture.install_id,
                fixture.key_id,
                i64::from(fixture.previous_counter)
            ],
        )
        .expect("reject stale assertion counter");
    assert_eq!(replay, 0);
}

#[test]
fn poll_request_binding_matches_swift_fixture() {
    let job_id = "fingerprint-123";
    let path = format!("/v1/ad-analysis/jobs/{job_id}");
    let payload = format!(r#"{{"job_id":"{job_id}"}}"#);

    assert_eq!(
        hex::encode(request_client_data_hash("POST", &path, &payload)),
        "c079e99784a3722a3b90e2523920fcca7c99a429ec3ad37e192acc8a87458d0a"
    );
}

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

#[test]
fn assertion_counter_cas_failure_is_the_replay_boundary() {
    let fixture = load_fixture();
    let verified_attestation = verify_attestation(
        &fixture.attestation_object,
        &fixture.challenge,
        &fixture.app_id,
        &fixture.key_id,
        &fixture.environment,
        fixture.captured_at_seconds,
    )
    .expect("real App Attest attestation should verify");
    let client_data_hash =
        request_client_data_hash(&fixture.method, &fixture.path, &fixture.payload);
    let verified_assertion = verify_assertion(
        &fixture.assertion,
        &client_data_hash,
        &fixture.app_id,
        &verified_attestation.public_key,
        fixture.previous_counter,
    )
    .expect("real App Attest assertion should verify");

    let db = setup_db();
    insert_key(
        &db,
        &fixture.install_id,
        &fixture.key_id,
        &verified_attestation.public_key,
        &fixture.app_id,
        &fixture.environment,
        i64::from(verified_assertion.sign_counter),
        fixture.captured_at_seconds,
    );

    let replay = update_counter(
        &db,
        &fixture.install_id,
        &fixture.key_id,
        i64::from(fixture.previous_counter),
        i64::from(verified_assertion.sign_counter),
        fixture.captured_at_seconds + 1,
    );

    assert_eq!(replay, 0);
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

fn insert_key(
    db: &Connection,
    install_id: &str,
    key_id: &str,
    public_key: &[u8],
    app_id: &str,
    environment: &str,
    sign_counter: i64,
    now: i64,
) {
    db.execute(
        "INSERT INTO app_attest_keys \
         (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
        params![
            install_id,
            key_id,
            public_key,
            sign_counter,
            app_id,
            environment,
            now
        ],
    )
    .expect("insert key");
}

fn update_counter(
    db: &Connection,
    install_id: &str,
    key_id: &str,
    previous_counter: i64,
    next_counter: i64,
    now: i64,
) -> usize {
    db.execute(
        "UPDATE app_attest_keys \
         SET sign_counter = ?1, last_used_at = ?2 \
         WHERE install_id = ?3 AND key_id = ?4 AND sign_counter = ?5",
        params![next_counter, now, install_id, key_id, previous_counter],
    )
    .expect("update counter")
}

fn load_fixture() -> AppAttestFixture {
    serde_json::from_str(include_str!(
        "fixtures/ad_analysis_app_attest_development_fixture.json"
    ))
    .expect("fixture should decode")
}

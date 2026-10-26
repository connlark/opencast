//! App Attest on the trial routes, the AdAnalysisWorker way: the assertion
//! binds method, path and payload; the counter compare-and-advance on this
//! worker's own migration is the replay boundary; a key is found only under
//! the install it was registered with. Synthetic P-256 keys stand in for a
//! device (the real-device capture is private material that never ships).

use base64::{engine::general_purpose::STANDARD, Engine};
use opencast_app_attest_core::app_attest::{
    request_client_data_hash, verify_assertion, AppAttestError,
};
use opencast_trial_proxy_worker::route::{TRIAL_ANALYZE_PATH, TRIAL_STATUS_PATH};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};

const APP_ID: &str = "EXAMPLETEAM.com.example.opencast";
const UPDATE_COUNTER_SQL: &str = "UPDATE app_attest_keys SET sign_counter = ?1, last_used_at = ?2 \
     WHERE install_id = ?3 AND key_id = ?4 AND sign_counter = ?5";

fn cbor_bytes(output: &mut Vec<u8>, major: u8, bytes: &[u8]) {
    match bytes.len() {
        len if len < 24 => output.push((major << 5) | len as u8),
        len if len < 256 => output.extend_from_slice(&[(major << 5) | 24, len as u8]),
        len => {
            output.push((major << 5) | 25);
            output.extend_from_slice(&(len as u16).to_be_bytes());
        }
    }
    output.extend_from_slice(bytes);
}

/// An assertion from `key` over (method, path, payload) at `counter`.
fn assertion(key: &SigningKey, counter: u32, method: &str, path: &str, payload: &str) -> String {
    let mut auth_data = Sha256::digest(APP_ID.as_bytes()).to_vec();
    auth_data.push(0x40);
    auth_data.extend_from_slice(&counter.to_be_bytes());
    let hash = request_client_data_hash(method, path, payload);
    let mut nonce_input = auth_data.clone();
    nonce_input.extend_from_slice(&hash);
    let signature: Signature = key.sign(&Sha256::digest(nonce_input));
    let mut cbor = vec![0xa2];
    cbor_bytes(&mut cbor, 3, b"authenticatorData");
    cbor_bytes(&mut cbor, 2, &auth_data);
    cbor_bytes(&mut cbor, 3, b"signature");
    cbor_bytes(&mut cbor, 2, signature.to_der().as_bytes());
    STANDARD.encode(cbor)
}

fn public_key(key: &SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_encoded_point(false)
        .as_bytes()
        .to_vec()
}

fn migrated() -> Connection {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(include_str!("../migrations/0001_app_attest_auth.sql"))
        .unwrap();
    db.execute_batch(include_str!("../migrations/0002_trial_ledger_mirror.sql"))
        .unwrap();
    db
}

#[test]
fn an_assertion_binds_the_trial_path_and_the_exact_payload() {
    let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
    let payload =
        r#"{"feature":"ad_detection","request":{"contents":[]},"run_id":"r","window_index":0}"#;
    let signed = assertion(&key, 1, "POST", TRIAL_ANALYZE_PATH, payload);
    let hash = request_client_data_hash("POST", TRIAL_ANALYZE_PATH, payload);
    let verified = verify_assertion(&signed, &hash, APP_ID, &public_key(&key), 0).unwrap();
    assert_eq!(verified.sign_counter, 1);
    for (method, path, body) in [
        ("POST", TRIAL_STATUS_PATH, payload),
        ("POST", "/v1/ad-analysis/transcript", payload),
        (
            "POST",
            TRIAL_ANALYZE_PATH,
            r#"{"feature":"chapters_summary"}"#,
        ),
        ("GET", TRIAL_ANALYZE_PATH, payload),
    ] {
        let other = request_client_data_hash(method, path, body);
        assert!(matches!(
            verify_assertion(&signed, &other, APP_ID, &public_key(&key), 0),
            Err(AppAttestError::InvalidSignature)
        ));
    }
    // Another app's assertion is refused before the signature is read.
    assert!(matches!(
        verify_assertion(
            &signed,
            &hash,
            "OTHERTEAM.com.example.app",
            &public_key(&key),
            0
        ),
        Err(AppAttestError::InvalidAppId)
    ));
}

#[test]
fn status_signs_post_and_an_empty_object() {
    let key = SigningKey::from_slice(&[9u8; 32]).unwrap();
    let signed = assertion(&key, 3, "POST", TRIAL_STATUS_PATH, "{}");
    let hash = request_client_data_hash("POST", TRIAL_STATUS_PATH, "{}");
    assert!(verify_assertion(&signed, &hash, APP_ID, &public_key(&key), 2).is_ok());
    // A replay of the same status assertion fails once the counter moved.
    assert!(matches!(
        verify_assertion(&signed, &hash, APP_ID, &public_key(&key), 3),
        Err(AppAttestError::InvalidCounter)
    ));
}

#[test]
fn the_counter_compare_and_advance_is_the_replay_boundary() {
    let key = SigningKey::from_slice(&[11u8; 32]).unwrap();
    let db = migrated();
    db.execute(
        "INSERT INTO app_attest_keys (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
         VALUES ('install-a', 'key-1', ?1, 0, ?2, 'production', 1, 1)",
        params![public_key(&key), APP_ID],
    )
    .unwrap();
    let payload = "{}";
    let hash = request_client_data_hash("POST", TRIAL_STATUS_PATH, payload);
    let first = assertion(&key, 1, "POST", TRIAL_STATUS_PATH, payload);
    let verified = verify_assertion(&first, &hash, APP_ID, &public_key(&key), 0).unwrap();
    let accepted = db
        .execute(
            UPDATE_COUNTER_SQL,
            params![verified.sign_counter, 2, "install-a", "key-1", 0],
        )
        .unwrap();
    assert_eq!(accepted, 1);
    // Two requests verified against the same stored counter: only one can
    // advance it.
    let racing = db
        .execute(
            UPDATE_COUNTER_SQL,
            params![verified.sign_counter, 3, "install-a", "key-1", 0],
        )
        .unwrap();
    assert_eq!(racing, 0);
    // And the replayed assertion no longer verifies against the stored counter.
    let stored: i64 = db
        .query_row(
            "SELECT sign_counter FROM app_attest_keys WHERE key_id = 'key-1'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(matches!(
        verify_assertion(&first, &hash, APP_ID, &public_key(&key), stored as u32),
        Err(AppAttestError::InvalidCounter)
    ));
}

#[test]
fn a_key_is_found_only_under_its_own_install() {
    let key = SigningKey::from_slice(&[13u8; 32]).unwrap();
    let db = migrated();
    db.execute(
        "INSERT INTO app_attest_keys (install_id, key_id, public_key, sign_counter, app_id, environment, created_at, last_used_at) \
         VALUES ('install-a', 'key-1', ?1, 0, ?2, 'production', 1, 1)",
        params![public_key(&key), APP_ID],
    )
    .unwrap();
    let lookup = |install: &str, key_id: &str| -> Option<Vec<u8>> {
        db.query_row(
            "SELECT public_key FROM app_attest_keys WHERE install_id = ?1 AND key_id = ?2 LIMIT 1",
            params![install, key_id],
            |row| row.get(0),
        )
        .ok()
    };
    assert!(lookup("install-a", "key-1").is_some());
    assert!(
        lookup("install-b", "key-1").is_none(),
        "wrong install: unknown_key"
    );
    let advanced = db
        .execute(UPDATE_COUNTER_SQL, params![1, 2, "install-b", "key-1", 0])
        .unwrap();
    assert_eq!(advanced, 0);
}

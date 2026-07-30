use opencast_app_attest_core::challenge_limits::{
    challenge_bucket_start, challenge_source_hash_key_for_environment,
    global_challenge_allows_insert, install_challenge_allows_insert, keyed_source_token,
    source_challenge_allows_after_increment, MAX_CHALLENGES_PER_INSTALL_PER_HOUR,
    MAX_CHALLENGES_PER_SOURCE_PER_HOUR, MAX_GLOBAL_CHALLENGES_PER_HOUR,
};

const DEVELOPMENT_FALLBACK_KEY: &str = "opencast-test-development-challenge-source-key";

#[test]
fn source_limit_allows_max_successful_challenges_per_hour() {
    assert!(source_challenge_allows_after_increment(1));
    assert!(source_challenge_allows_after_increment(
        MAX_CHALLENGES_PER_SOURCE_PER_HOUR
    ));
    assert!(!source_challenge_allows_after_increment(
        MAX_CHALLENGES_PER_SOURCE_PER_HOUR + 1
    ));
}

#[test]
fn install_and_global_limits_allow_max_successful_serial_challenges_per_hour() {
    assert!(install_challenge_allows_insert(
        MAX_CHALLENGES_PER_INSTALL_PER_HOUR - 1
    ));
    assert!(!install_challenge_allows_insert(
        MAX_CHALLENGES_PER_INSTALL_PER_HOUR
    ));

    assert!(global_challenge_allows_insert(
        MAX_GLOBAL_CHALLENGES_PER_HOUR - 1
    ));
    assert!(!global_challenge_allows_insert(
        MAX_GLOBAL_CHALLENGES_PER_HOUR
    ));
}

#[test]
fn install_and_global_limits_are_pre_insert_checks_not_concurrency_invariants() {
    let observed_before_insert = MAX_CHALLENGES_PER_INSTALL_PER_HOUR - 1;
    assert!(install_challenge_allows_insert(observed_before_insert));
    assert!(install_challenge_allows_insert(observed_before_insert));

    let observed_global_before_insert = MAX_GLOBAL_CHALLENGES_PER_HOUR - 1;
    assert!(global_challenge_allows_insert(
        observed_global_before_insert
    ));
    assert!(global_challenge_allows_insert(
        observed_global_before_insert
    ));
}

#[test]
fn challenge_source_hash_key_falls_back_only_for_development() {
    assert_eq!(
        challenge_source_hash_key_for_environment(None, "development", DEVELOPMENT_FALLBACK_KEY),
        Some(DEVELOPMENT_FALLBACK_KEY.to_string())
    );
    assert_eq!(
        challenge_source_hash_key_for_environment(
            Some("secret"),
            "production",
            DEVELOPMENT_FALLBACK_KEY
        ),
        Some("secret".to_string())
    );
    assert_eq!(
        challenge_source_hash_key_for_environment(None, "production", DEVELOPMENT_FALLBACK_KEY),
        None
    );
    assert_eq!(
        challenge_source_hash_key_for_environment(None, "prod-staging", DEVELOPMENT_FALLBACK_KEY),
        None
    );
}

#[test]
fn challenge_source_token_is_keyed_and_does_not_store_raw_source() {
    let first = keyed_source_token("key-a", "203.0.113.7");
    let second = keyed_source_token("key-a", "203.0.113.7");
    let different_key = keyed_source_token("key-b", "203.0.113.7");

    assert_eq!(first, second);
    assert_ne!(first, different_key);
    assert!(!first.contains("203.0.113.7"));
    assert_eq!(first.len(), 64);
}

#[test]
fn challenge_bucket_start_uses_hour_windows() {
    assert_eq!(challenge_bucket_start(0), 0);
    assert_eq!(challenge_bucket_start(3_599), 0);
    assert_eq!(challenge_bucket_start(3_600), 3_600);
    assert_eq!(challenge_bucket_start(3_601), 3_600);
}

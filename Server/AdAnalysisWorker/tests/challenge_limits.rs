use opencast_ad_analysis_worker::challenge_limits::{
    challenge_source_hash_key_for_environment, global_challenge_allows_insert,
    install_challenge_allows_insert, source_challenge_allows_after_increment,
    DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY, MAX_CHALLENGES_PER_INSTALL_PER_HOUR,
    MAX_CHALLENGES_PER_SOURCE_PER_HOUR, MAX_GLOBAL_CHALLENGES_PER_HOUR,
};

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
        challenge_source_hash_key_for_environment(None, "development"),
        Some(DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY.to_string())
    );
    assert_eq!(
        challenge_source_hash_key_for_environment(Some("secret"), "production"),
        Some("secret".to_string())
    );
    assert_eq!(
        challenge_source_hash_key_for_environment(None, "production"),
        None
    );
    assert_eq!(
        challenge_source_hash_key_for_environment(None, "prod-staging"),
        None
    );
}

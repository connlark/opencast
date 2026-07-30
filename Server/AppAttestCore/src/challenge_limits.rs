use sha2::{Digest, Sha256};

pub const CHALLENGE_TTL_SECONDS: i64 = 10 * 60;
pub const CHALLENGE_LIMIT_WINDOW_SECONDS: i64 = 60 * 60;
pub const CHALLENGE_RETENTION_SECONDS: i64 = 24 * 60 * 60;
pub const CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS: i64 = 2 * CHALLENGE_LIMIT_WINDOW_SECONDS;
pub const APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS: i64 = 24 * 60 * 60;
pub const MAX_CHALLENGES_PER_INSTALL_PER_HOUR: i64 = 20;
pub const MAX_CHALLENGES_PER_SOURCE_PER_HOUR: i64 = 300;
pub const MAX_GLOBAL_CHALLENGES_PER_HOUR: i64 = 10_000;
pub const MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY: i64 = 10;

pub fn source_challenge_allows_after_increment(count_after_increment: i64) -> bool {
    count_after_increment <= MAX_CHALLENGES_PER_SOURCE_PER_HOUR
}

pub fn install_challenge_allows_insert(count_before_insert: i64) -> bool {
    count_before_insert < MAX_CHALLENGES_PER_INSTALL_PER_HOUR
}

pub fn global_challenge_allows_insert(count_before_insert: i64) -> bool {
    count_before_insert < MAX_GLOBAL_CHALLENGES_PER_HOUR
}

/// The development fallback is load-bearing: development lanes have no
/// `CHALLENGE_SOURCE_HASH_KEY` secret and must still mint source tokens.
/// Each worker passes its own `development_fallback_key` constant.
pub fn challenge_source_hash_key_for_environment(
    secret: Option<&str>,
    environment: &str,
    development_fallback_key: &str,
) -> Option<String> {
    if let Some(secret) = secret {
        return Some(secret.to_string());
    }

    if environment == "development" {
        return Some(development_fallback_key.to_string());
    }

    None
}

pub fn challenge_bucket_start(now: i64) -> i64 {
    now.saturating_sub(now.rem_euclid(CHALLENGE_LIMIT_WINDOW_SECONDS))
}

pub fn keyed_source_token(key: &str, source_signal: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.as_bytes());
    hasher.update([0]);
    hasher.update(source_signal.as_bytes());
    hex::encode(hasher.finalize())
}

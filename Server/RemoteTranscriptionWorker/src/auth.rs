use sha2::{Digest, Sha256};

pub const AUTHORIZATION_HEADER: &str = "authorization";

pub fn bearer_token(header: Option<&str>) -> Option<&str> {
    let header = header?.trim();
    let (scheme, token) = header.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    let token = token.trim();
    if token.is_empty() || token.contains(char::is_whitespace) {
        return None;
    }
    Some(token)
}

pub fn token_matches(provided: &str, expected: &str) -> bool {
    let provided_hash = Sha256::digest(provided.as_bytes());
    let expected_hash = Sha256::digest(expected.as_bytes());
    constant_time_eq::constant_time_eq(provided_hash.as_slice(), expected_hash.as_slice())
}

pub fn token_hash(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}

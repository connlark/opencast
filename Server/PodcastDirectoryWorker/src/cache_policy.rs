use sha2::{Digest, Sha256};

/// Synthetic cache-key origin. Never a routable host; keys carry a
/// SHA-256 of the query so search text does not appear in cache URLs.
const CACHE_KEY_ORIGIN: &str = "https://cache.opencast-podcast-directory.internal";

pub fn search_cache_key(normalized_query: &str) -> String {
    let digest = hex::encode(Sha256::digest(normalized_query.as_bytes()));
    format!("{CACHE_KEY_ORIGIN}/v1/search/{digest}")
}

pub fn lookup_cache_key(apple_id: u64) -> String {
    format!("{CACHE_KEY_ORIGIN}/v1/podcasts/by-apple-id/{apple_id}")
}

/// The TTL to cache with, only when the upstream response explicitly
/// permits shared caching: no `no-store`, `no-cache`, or `private`
/// directive, and a positive `s-maxage` or `max-age`, bounded by
/// `cap_seconds`.
pub fn cache_ttl_seconds(cache_control: Option<&str>, cap_seconds: u64) -> Option<u64> {
    let header = cache_control?;
    let mut max_age: Option<u64> = None;
    let mut shared_max_age: Option<u64> = None;

    for directive in header.split(',') {
        let directive = directive.trim();
        let (name, value) = match directive.split_once('=') {
            Some((name, value)) => (name.trim(), Some(value.trim().trim_matches('"'))),
            None => (directive, None),
        };
        if name.eq_ignore_ascii_case("no-store")
            || name.eq_ignore_ascii_case("no-cache")
            || name.eq_ignore_ascii_case("private")
        {
            return None;
        }
        if name.eq_ignore_ascii_case("max-age") {
            max_age = value.and_then(|value| value.parse().ok());
        }
        if name.eq_ignore_ascii_case("s-maxage") {
            shared_max_age = value.and_then(|value| value.parse().ok());
        }
    }

    let permitted = shared_max_age.or(max_age)?;
    if permitted == 0 {
        return None;
    }
    Some(permitted.min(cap_seconds))
}

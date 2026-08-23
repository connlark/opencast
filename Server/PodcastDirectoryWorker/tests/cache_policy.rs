use opencast_podcast_directory_worker::cache_policy::{
    cache_ttl_seconds, lookup_cache_key, search_cache_key,
};

#[test]
fn search_keys_hash_the_query() {
    // shasum -a 256 of "testquery".
    assert_eq!(
        search_cache_key("testquery"),
        "https://cache.opencast-podcast-directory.internal/v1/search/e7875aabc110f27eeebdaf6c740cfd1f7e533946a02dda003ee554d77f396cad"
    );
}

#[test]
fn search_keys_never_contain_query_text() {
    let key = search_cache_key("very private search terms");
    assert!(!key.contains("private"));
    assert!(!key.contains(' '));
}

#[test]
fn search_keys_are_deterministic_and_distinct() {
    assert_eq!(search_cache_key("serial"), search_cache_key("serial"));
    assert_ne!(search_cache_key("serial"), search_cache_key("serial 2"));
}

#[test]
fn lookup_keys_use_the_apple_id() {
    assert_eq!(
        lookup_cache_key(917_918_570),
        "https://cache.opencast-podcast-directory.internal/v1/podcasts/by-apple-id/917918570"
    );
}

#[test]
fn absent_or_forbidding_directives_prevent_caching() {
    assert_eq!(cache_ttl_seconds(None, 900), None);
    assert_eq!(cache_ttl_seconds(Some(""), 900), None);
    assert_eq!(cache_ttl_seconds(Some("public"), 900), None);
    assert_eq!(cache_ttl_seconds(Some("no-store"), 900), None);
    assert_eq!(
        cache_ttl_seconds(Some("public, max-age=600, no-cache"), 900),
        None
    );
    assert_eq!(cache_ttl_seconds(Some("private, max-age=600"), 900), None);
    assert_eq!(cache_ttl_seconds(Some("max-age=0"), 900), None);
    assert_eq!(cache_ttl_seconds(Some("max-age=banana"), 900), None);
}

#[test]
fn max_age_is_bounded_by_the_cap() {
    assert_eq!(cache_ttl_seconds(Some("max-age=600"), 900), Some(600));
    assert_eq!(cache_ttl_seconds(Some("max-age=86400"), 900), Some(900));
    assert_eq!(
        cache_ttl_seconds(Some("public, max-age=3600"), 3600),
        Some(3600)
    );
}

#[test]
fn shared_max_age_wins_over_max_age() {
    assert_eq!(
        cache_ttl_seconds(Some("max-age=600, s-maxage=120"), 900),
        Some(120)
    );
    assert_eq!(
        cache_ttl_seconds(Some("s-maxage=0, max-age=600"), 900),
        None
    );
}

#[test]
fn directives_parse_case_insensitively_with_quotes() {
    assert_eq!(cache_ttl_seconds(Some("Max-Age=\"300\""), 900), Some(300));
    assert_eq!(cache_ttl_seconds(Some("No-Store"), 900), None);
}

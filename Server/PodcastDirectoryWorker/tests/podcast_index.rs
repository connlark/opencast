use opencast_podcast_directory_worker::podcast_index::{
    auth_token, lookup_url, parse_lookup_response, parse_search_response, search_url,
    DIRECTORY_USER_AGENT,
};

#[test]
fn auth_token_matches_known_vector() {
    // shasum -a 1 of "ABCDEF1700000000".
    assert_eq!(
        auth_token("ABC", "DEF", 1_700_000_000),
        "743cc6e9ff202a89f21a48577e49b2618fbd5758"
    );
}

#[test]
fn auth_token_is_lowercase_hex() {
    let token = auth_token("key", "secret", 1);
    assert_eq!(token.len(), 40);
    assert!(token
        .chars()
        .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
}

#[test]
fn search_url_encodes_query_and_pins_max() {
    let url = search_url("this american life & more #tags");
    assert!(url.starts_with("https://api.podcastindex.org/api/1.0/search/byterm?"));
    assert!(url.contains("q=this+american+life+%26+more+%23tags"));
    assert!(url.contains("max=25"));
}

#[test]
fn lookup_url_carries_the_apple_id() {
    assert_eq!(
        lookup_url(917_918_570),
        "https://api.podcastindex.org/api/1.0/podcasts/byitunesid?id=917918570"
    );
}

#[test]
fn user_agent_is_pinned() {
    assert_eq!(
        DIRECTORY_USER_AGENT,
        "OpenCast-Directory/1 (+https://opencast.mobile)"
    );
}

#[test]
fn search_response_normalizes_entries() {
    let body = br#"{
        "status": "true",
        "feeds": [
            {
                "id": 745392,
                "podcastGuid": "2d7400e3-bacb-52fd-aabc-0da55e39f98b",
                "title": "Serial",
                "url": "https://example.com/xl36XBC2",
                "author": "Serial Productions",
                "ownerName": "Owner",
                "link": "https://example.com/site",
                "image": "https://example.com/image.jpg",
                "artwork": "https://example.com/artwork.jpg",
                "itunesId": 917918570,
                "episodeCount": 124,
                "newestItemPubdate": 1750230000,
                "lastUpdateTime": 1750000000
            }
        ],
        "count": 1
    }"#;

    let entries = parse_search_response(body).expect("parses");
    assert_eq!(entries.len(), 1);
    let entry = &entries[0];
    assert_eq!(entry.podcast_index_id, 745_392);
    assert_eq!(
        entry.podcast_guid.as_deref(),
        Some("2d7400e3-bacb-52fd-aabc-0da55e39f98b")
    );
    assert_eq!(entry.apple_id, Some(917_918_570));
    assert_eq!(entry.title, "Serial");
    assert_eq!(entry.author.as_deref(), Some("Serial Productions"));
    assert_eq!(entry.feed_url, "https://example.com/xl36XBC2");
    assert_eq!(
        entry.artwork_url.as_deref(),
        Some("https://example.com/artwork.jpg")
    );
    assert_eq!(
        entry.website_url.as_deref(),
        Some("https://example.com/site")
    );
    assert_eq!(entry.reported_episode_count, Some(124));
    assert_eq!(entry.reported_updated_at, Some(1_750_230_000));
}

#[test]
fn search_response_treats_hint_fields_as_optional() {
    let body = br#"{
        "feeds": [
            {
                "id": 7,
                "title": "Hints Absent",
                "url": "https://example.com/feed.xml",
                "itunesId": null,
                "episodeCount": 0,
                "newestItemPubdate": null,
                "lastUpdateTime": 1750000000
            }
        ]
    }"#;

    let entries = parse_search_response(body).expect("parses");
    assert_eq!(entries.len(), 1);
    let entry = &entries[0];
    assert_eq!(entry.apple_id, None);
    assert_eq!(entry.reported_episode_count, None);
    assert_eq!(entry.reported_updated_at, Some(1_750_000_000));
    assert_eq!(entry.author, None);
    assert_eq!(entry.podcast_guid, None);
}

#[test]
fn search_response_falls_back_to_owner_name_and_image() {
    let body = br#"{
        "feeds": [
            {
                "id": 8,
                "title": "Fallbacks",
                "url": "https://example.com/feed.xml",
                "ownerName": "Owner Name",
                "image": "https://example.com/image.jpg"
            }
        ]
    }"#;

    let entries = parse_search_response(body).expect("parses");
    assert_eq!(entries[0].author.as_deref(), Some("Owner Name"));
    assert_eq!(
        entries[0].artwork_url.as_deref(),
        Some("https://example.com/image.jpg")
    );
}

#[test]
fn search_response_drops_unusable_entries() {
    let body = br#"{
        "feeds": [
            {"id": 1, "title": "No feed URL"},
            {"id": 2, "title": "Bad scheme", "url": "ftp://example.com/feed.xml"},
            {"id": 3, "title": "", "url": "https://example.com/blank-title.xml"},
            {"id": 0, "title": "Zero ID", "url": "https://example.com/zero.xml"},
            {"title": "Missing ID", "url": "https://example.com/missing.xml"},
            {"id": 4, "title": "Keeper", "url": "https://example.com/keeper.xml"}
        ]
    }"#;

    let entries = parse_search_response(body).expect("parses");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].podcast_index_id, 4);
}

#[test]
fn search_response_caps_entry_count() {
    let feeds = (1..=40)
        .map(|id| {
            format!(
                r#"{{"id": {id}, "title": "Show {id}", "url": "https://example.com/{id}.xml"}}"#
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let body = format!(r#"{{"feeds": [{feeds}]}}"#);

    let entries = parse_search_response(body.as_bytes()).expect("parses");
    assert_eq!(entries.len(), 25);
}

#[test]
fn search_response_tolerates_missing_feeds() {
    assert_eq!(
        parse_search_response(br#"{"status":"true"}"#).expect("parses"),
        vec![]
    );
    assert_eq!(
        parse_search_response(br#"{"feeds":[]}"#).expect("parses"),
        vec![]
    );
}

#[test]
fn search_response_rejects_non_json() {
    assert!(parse_search_response(b"<html>oops</html>").is_err());
    assert!(parse_search_response(b"").is_err());
}

#[test]
fn lookup_response_parses_a_hit() {
    let body = br#"{
        "status": "true",
        "feed": {
            "id": 745392,
            "title": "Serial",
            "url": "https://example.com/xl36XBC2",
            "itunesId": 917918570
        }
    }"#;

    let entry = parse_lookup_response(body).expect("parses").expect("entry");
    assert_eq!(entry.podcast_index_id, 745_392);
    assert_eq!(entry.apple_id, Some(917_918_570));
}

#[test]
fn lookup_response_treats_non_object_feed_as_miss() {
    // The live API answers a miss with an empty array (or null) feed.
    assert_eq!(
        parse_lookup_response(br#"{"feed": []}"#).expect("parses"),
        None
    );
    assert_eq!(
        parse_lookup_response(br#"{"feed": null}"#).expect("parses"),
        None
    );
    assert_eq!(
        parse_lookup_response(br#"{"status": "false"}"#).expect("parses"),
        None
    );
}

#[test]
fn lookup_response_treats_unusable_feed_as_miss() {
    assert_eq!(
        parse_lookup_response(br#"{"feed": {"id": 1, "title": "No URL"}}"#).expect("parses"),
        None
    );
}

#[test]
fn oversized_upstream_strings_are_dropped() {
    let long_title = "t".repeat(600);
    let body = format!(
        r#"{{"feeds": [{{"id": 1, "title": "{long_title}", "url": "https://example.com/feed.xml"}}]}}"#
    );
    assert_eq!(
        parse_search_response(body.as_bytes()).expect("parses"),
        vec![]
    );

    let long_url = format!("https://example.com/{}", "u".repeat(2_100));
    let body = format!(r#"{{"feeds": [{{"id": 1, "title": "T", "url": "{long_url}"}}]}}"#);
    assert_eq!(
        parse_search_response(body.as_bytes()).expect("parses"),
        vec![]
    );
}

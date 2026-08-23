use opencast_podcast_directory_worker::validation::{
    is_json_content_type, normalized_query, parse_apple_id,
};

#[test]
fn queries_are_trimmed_and_collapsed() {
    assert_eq!(normalized_query("  serial  "), Some("serial".to_string()));
    assert_eq!(
        normalized_query("this\t american \n life"),
        Some("this american life".to_string())
    );
}

#[test]
fn blank_queries_are_rejected() {
    assert_eq!(normalized_query(""), None);
    assert_eq!(normalized_query("   \t\n  "), None);
}

#[test]
fn queries_are_bounded_to_200_characters() {
    let exactly_200 = "a".repeat(200);
    assert_eq!(normalized_query(&exactly_200), Some(exactly_200));
    assert_eq!(normalized_query(&"a".repeat(201)), None);
}

#[test]
fn query_bound_counts_characters_not_bytes() {
    let multibyte = "ü".repeat(200);
    assert_eq!(normalized_query(&multibyte), Some(multibyte.clone()));
    assert_eq!(normalized_query(&format!("{multibyte}ü")), None);
}

#[test]
fn apple_ids_parse_positive_integers() {
    assert_eq!(parse_apple_id("1"), Some(1));
    assert_eq!(parse_apple_id("917918570"), Some(917_918_570));
}

#[test]
fn apple_ids_reject_malformed_segments() {
    for segment in [
        "",
        "0",
        "01",
        "+5",
        "-5",
        "1.5",
        "abc",
        "1a",
        " 1",
        "9999999999999999999999",
    ] {
        assert_eq!(parse_apple_id(segment), None, "segment {segment:?}");
    }
}

#[test]
fn json_content_types_allow_parameters_and_case() {
    assert!(is_json_content_type("application/json"));
    assert!(is_json_content_type("application/json; charset=utf-8"));
    assert!(is_json_content_type("Application/JSON"));
    assert!(!is_json_content_type("text/plain"));
    assert!(!is_json_content_type("application/xml"));
    assert!(!is_json_content_type(""));
}

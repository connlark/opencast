use opencast_podcast_directory_worker::logging::{log_line, RequestLog};

#[test]
fn full_log_line_serializes_every_field() {
    let line = log_line(&RequestLog {
        route: "search",
        status: 200,
        cache: "store",
        provider_latency_ms: Some(123),
        result_count: Some(10),
        error_class: Some("none"),
    });
    assert_eq!(
        line,
        r#"{"route":"search","status":200,"cache":"store","providerLatencyMs":123,"resultCount":10,"errorClass":"none"}"#
    );
}

#[test]
fn optional_fields_are_omitted_when_absent() {
    let line = log_line(&RequestLog {
        route: "health",
        status: 200,
        cache: "none",
        provider_latency_ms: None,
        result_count: None,
        error_class: None,
    });
    assert_eq!(line, r#"{"route":"health","status":200,"cache":"none"}"#);
}

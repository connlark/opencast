use opencast_podcast_directory_worker::route::{
    route_request, RouteAction, StaticResponse, BY_APPLE_ID_PREFIX, HEALTH_PATH, JSON_CONTENT_TYPE,
    SEARCH_PATH,
};

#[test]
fn search_routes_on_post() {
    assert_eq!(route_request("POST", SEARCH_PATH), RouteAction::Search);
}

#[test]
fn search_rejects_other_methods_with_allow_header() {
    for method in ["GET", "PUT", "DELETE", "HEAD", "OPTIONS"] {
        let response = static_response(route_request(method, SEARCH_PATH));
        assert_eq!(response.status, 405);
        assert_header(&response, "allow", "POST");
        assert_eq!(response.body, r#"{"error":"method_not_allowed"}"#);
    }
}

#[test]
fn health_routes_on_get() {
    assert_eq!(route_request("GET", HEALTH_PATH), RouteAction::Health);
}

#[test]
fn health_rejects_post() {
    let response = static_response(route_request("POST", HEALTH_PATH));
    assert_eq!(response.status, 405);
    assert_header(&response, "allow", "GET");
}

#[test]
fn lookup_routes_on_get_with_positive_id() {
    assert_eq!(
        route_request("GET", &format!("{BY_APPLE_ID_PREFIX}917918570")),
        RouteAction::LookupByAppleId(917_918_570)
    );
}

#[test]
fn lookup_rejects_post() {
    let response = static_response(route_request("POST", &format!("{BY_APPLE_ID_PREFIX}1")));
    assert_eq!(response.status, 405);
    assert_header(&response, "allow", "GET");
}

#[test]
fn lookup_rejects_invalid_ids() {
    for segment in [
        "",
        "0",
        "017",
        "-4",
        "abc",
        "12abc",
        "1/extra",
        "99999999999999999999",
    ] {
        let response = static_response(route_request(
            "GET",
            &format!("{BY_APPLE_ID_PREFIX}{segment}"),
        ));
        assert_eq!(response.status, 400, "segment {segment:?}");
        assert_eq!(response.body, r#"{"error":"invalid_apple_id"}"#);
    }
}

#[test]
fn unknown_paths_return_not_found() {
    for path in ["/", "/v1", "/v1/podcasts", "/v2/search", "/v1/search/extra"] {
        let response = static_response(route_request("GET", path));
        assert_eq!(response.status, 404, "path {path:?}");
        assert_eq!(response.body, r#"{"error":"not_found"}"#);
        assert_header(&response, "content-type", JSON_CONTENT_TYPE);
    }
}

fn static_response(action: RouteAction) -> StaticResponse {
    match action {
        RouteAction::Static(response) => response,
        other => panic!("expected a static response, got {other:?}"),
    }
}

fn assert_header(response: &StaticResponse, name: &str, value: &str) {
    let found = response
        .headers
        .iter()
        .find(|header| header.name == name)
        .unwrap_or_else(|| panic!("missing header {name}"));
    assert_eq!(found.value, value);
}

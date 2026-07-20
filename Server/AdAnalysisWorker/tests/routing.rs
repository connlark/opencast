use opencast_ad_analysis_worker::auth::{bearer_token, token_hash, token_matches};
use opencast_ad_analysis_worker::route::{
    route_request, RouteAction, AD_ANALYSIS_JOBS_PREFIX, ANALYZE_TRANSCRIPT_PATH,
    APP_ATTEST_CHALLENGE_PATH, APP_ATTEST_REGISTER_PATH, HEALTH_PATH, JSON_CONTENT_TYPE,
};

#[test]
fn health_returns_ok_without_auth() {
    let response = static_response(route_request("GET", HEALTH_PATH, false));

    assert_eq!(response.status, 200);
    assert_header(&response, "content-type", JSON_CONTENT_TYPE);
    assert_eq!(response.body, r#"{"message":"ok"}"#);
}

#[test]
fn analysis_requires_post_enabled_and_auth() {
    let wrong_method = static_response(route_request("GET", ANALYZE_TRANSCRIPT_PATH, true));
    assert_eq!(wrong_method.status, 405);
    assert_header(&wrong_method, "allow", "POST");
    assert_eq!(wrong_method.body, r#"{"error":"method_not_allowed"}"#);

    let disabled = static_response(route_request("POST", ANALYZE_TRANSCRIPT_PATH, false));
    assert_eq!(disabled.status, 503);
    assert_header(&disabled, "content-type", JSON_CONTENT_TYPE);
    assert_eq!(disabled.body, r#"{"error":"ad_analysis_disabled"}"#);

    assert!(matches!(
        route_request("POST", ANALYZE_TRANSCRIPT_PATH, true),
        RouteAction::AnalyzeTranscript
    ));
}

#[test]
fn app_attest_setup_routes_require_post_and_enabled_feature() {
    let wrong_method = static_response(route_request("GET", APP_ATTEST_CHALLENGE_PATH, true));
    assert_eq!(wrong_method.status, 405);
    assert_header(&wrong_method, "allow", "POST");

    let disabled = static_response(route_request("POST", APP_ATTEST_REGISTER_PATH, false));
    assert_eq!(disabled.status, 503);
    assert_eq!(disabled.body, r#"{"error":"ad_analysis_disabled"}"#);

    assert!(matches!(
        route_request("POST", APP_ATTEST_CHALLENGE_PATH, true),
        RouteAction::AppAttestChallenge
    ));
    assert!(matches!(
        route_request("POST", APP_ATTEST_REGISTER_PATH, true),
        RouteAction::AppAttestRegister
    ));
}

#[test]
fn unknown_routes_and_wrong_health_method_return_json_errors() {
    let not_found = static_response(route_request("GET", "/missing", false));
    assert_eq!(not_found.status, 404);
    assert_header(&not_found, "content-type", JSON_CONTENT_TYPE);
    assert_eq!(not_found.body, r#"{"error":"not_found"}"#);

    let health_post = static_response(route_request("POST", HEALTH_PATH, false));
    assert_eq!(health_post.status, 405);
    assert_header(&health_post, "content-type", JSON_CONTENT_TYPE);
    assert_header(&health_post, "allow", "GET");
    assert_eq!(health_post.body, r#"{"error":"method_not_allowed"}"#);
}

#[test]
fn poll_routes_require_post_enabled_and_a_valid_job_id() {
    let path = format!("{AD_ANALYSIS_JOBS_PREFIX}fingerprint-123");

    let wrong_method = static_response(route_request("GET", &path, true));
    assert_eq!(wrong_method.status, 405);
    assert_header(&wrong_method, "allow", "POST");

    let disabled = static_response(route_request("POST", &path, false));
    assert_eq!(disabled.status, 503);
    assert_eq!(disabled.body, r#"{"error":"ad_analysis_disabled"}"#);

    assert_eq!(
        route_request("POST", &path, true),
        RouteAction::PollJob {
            job_id: "fingerprint-123".to_string()
        }
    );

    for invalid in ["short", "bad/id", "bad%2Fid", "trailing/"] {
        let response = static_response(route_request(
            "POST",
            &format!("{AD_ANALYSIS_JOBS_PREFIX}{invalid}"),
            true,
        ));
        assert_eq!(response.status, 404, "invalid id {invalid}");
    }
}

#[test]
fn bearer_token_parser_accepts_only_single_bearer_token() {
    assert_eq!(bearer_token(Some("Bearer token-123")), Some("token-123"));
    assert_eq!(bearer_token(Some("bearer token-123")), Some("token-123"));
    assert_eq!(bearer_token(Some("Basic token-123")), None);
    assert_eq!(bearer_token(Some("Bearer ")), None);
    assert_eq!(bearer_token(Some("Bearer one two")), None);
}

#[test]
fn token_comparison_uses_hashes_consistently() {
    assert!(token_matches("secret", "secret"));
    assert!(!token_matches("secret", "other"));
    assert_eq!(token_hash("secret").len(), 64);
}

fn static_response(action: RouteAction) -> opencast_ad_analysis_worker::route::StaticResponse {
    match action {
        RouteAction::Static(response) => response,
        RouteAction::AppAttestChallenge => panic!("expected static response"),
        RouteAction::AppAttestRegister => panic!("expected static response"),
        RouteAction::AnalyzeTranscript => panic!("expected static response"),
        RouteAction::PollJob { .. } => panic!("expected static response"),
    }
}

fn assert_header(
    response: &opencast_ad_analysis_worker::route::StaticResponse,
    name: &'static str,
    value: &str,
) {
    assert_eq!(
        response
            .headers
            .iter()
            .find(|header| header.name == name)
            .map(|header| header.value.as_str()),
        Some(value)
    );
}

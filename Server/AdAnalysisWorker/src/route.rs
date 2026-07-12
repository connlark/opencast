use crate::types::ErrorResponse;

pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";
pub const HEALTH_PATH: &str = "/health";
pub const APP_ATTEST_CHALLENGE_PATH: &str = "/v1/app-attest/challenge";
pub const APP_ATTEST_REGISTER_PATH: &str = "/v1/app-attest/register";
pub const ANALYZE_TRANSCRIPT_PATH: &str = "/v1/ad-analysis/transcript";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub name: &'static str,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StaticResponse {
    pub status: u16,
    pub headers: Vec<Header>,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteAction {
    Static(StaticResponse),
    AppAttestChallenge,
    AppAttestRegister,
    AnalyzeTranscript,
}

pub fn route_request(method: &str, path: &str, enabled: bool) -> RouteAction {
    if path == HEALTH_PATH {
        return RouteAction::Static(handle_health(method));
    }

    if path == APP_ATTEST_CHALLENGE_PATH {
        return handle_app_attest_write(method, enabled, RouteAction::AppAttestChallenge);
    }

    if path == APP_ATTEST_REGISTER_PATH {
        return handle_app_attest_write(method, enabled, RouteAction::AppAttestRegister);
    }

    if path == ANALYZE_TRANSCRIPT_PATH {
        return handle_analysis(method, enabled);
    }

    RouteAction::Static(json_response(404, ErrorResponse::new("not_found")))
}

pub fn json_response(status: u16, body: ErrorResponse) -> StaticResponse {
    StaticResponse {
        status,
        headers: vec![Header {
            name: "content-type",
            value: JSON_CONTENT_TYPE.to_string(),
        }],
        body: serde_json::to_string(&body).expect("error response serializes"),
    }
}

pub fn json_success(status: u16, body: impl serde::Serialize) -> StaticResponse {
    StaticResponse {
        status,
        headers: vec![Header {
            name: "content-type",
            value: JSON_CONTENT_TYPE.to_string(),
        }],
        body: serde_json::to_string(&body).expect("success response serializes"),
    }
}

fn handle_health(method: &str) -> StaticResponse {
    if method != "GET" {
        return method_not_allowed("GET");
    }
    json_success(200, serde_json::json!({ "message": "ok" }))
}

fn handle_app_attest_write(method: &str, enabled: bool, action: RouteAction) -> RouteAction {
    if method != "POST" {
        return RouteAction::Static(method_not_allowed("POST"));
    }
    if !enabled {
        return RouteAction::Static(json_response(
            503,
            ErrorResponse::new("ad_analysis_disabled"),
        ));
    }
    action
}

fn handle_analysis(method: &str, enabled: bool) -> RouteAction {
    if method != "POST" {
        return RouteAction::Static(method_not_allowed("POST"));
    }
    if !enabled {
        return RouteAction::Static(json_response(
            503,
            ErrorResponse::new("ad_analysis_disabled"),
        ));
    }
    RouteAction::AnalyzeTranscript
}

fn method_not_allowed(allow: &'static str) -> StaticResponse {
    StaticResponse {
        status: 405,
        headers: vec![
            Header {
                name: "content-type",
                value: JSON_CONTENT_TYPE.to_string(),
            },
            Header {
                name: "allow",
                value: allow.to_string(),
            },
        ],
        body: serde_json::to_string(&ErrorResponse::new("method_not_allowed"))
            .expect("error response serializes"),
    }
}

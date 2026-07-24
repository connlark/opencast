use crate::types::ErrorResponse;

pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";
pub const HEALTH_PATH: &str = "/health";
pub const APP_ATTEST_CHALLENGE_PATH: &str = "/v1/app-attest/challenge";
pub const APP_ATTEST_REGISTER_PATH: &str = "/v1/app-attest/register";
pub const ANALYZE_TRANSCRIPT_PATH: &str = "/v1/ad-analysis/transcript";
pub const AD_ANALYSIS_JOBS_PREFIX: &str = "/v1/ad-analysis/jobs/";

/// Internal surface for the RemoteTranscriptionWorker service binding
/// (PurchaseWorker convention: a `.internal` host reachable only over the
/// binding). The public host 404s `/internal/*`; the internal host resolves
/// nothing else.
pub const INTERNAL_HOST: &str = "opencast-ad-analysis.internal";
pub const INTERNAL_ANALYZE_PATH: &str = "/internal/v1/analyze";
pub const INTERNAL_JOBS_PREFIX: &str = "/internal/v1/jobs/";

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
    PollJob { job_id: String },
    InternalAnalyze,
    InternalPollJob { job_id: String },
}

pub fn route_request(
    method: &str,
    path: &str,
    enabled: bool,
    internal: bool,
    internal_enabled: bool,
) -> RouteAction {
    if internal {
        return route_internal(method, path, internal_enabled);
    }

    if path.starts_with("/internal/") {
        return RouteAction::Static(json_response(404, ErrorResponse::new("not_found")));
    }

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

    if let Some(job_id) = path.strip_prefix(AD_ANALYSIS_JOBS_PREFIX) {
        return handle_poll_job(method, enabled, job_id);
    }

    RouteAction::Static(json_response(404, ErrorResponse::new("not_found")))
}

/// Internal-host routing: only the two binding paths exist, POST only, both
/// behind the `INTERNAL_AD_ANALYSIS_ENABLED` kill switch (independent of the
/// public flag). Everything else 404s.
fn route_internal(method: &str, path: &str, internal_enabled: bool) -> RouteAction {
    let action = if path == INTERNAL_ANALYZE_PATH {
        Some(RouteAction::InternalAnalyze)
    } else {
        path.strip_prefix(INTERNAL_JOBS_PREFIX)
            .and_then(|rest| rest.strip_suffix("/poll"))
            .filter(|job_id| crate::job::valid_job_id(job_id))
            .map(|job_id| RouteAction::InternalPollJob {
                job_id: job_id.to_string(),
            })
    };
    let Some(action) = action else {
        return RouteAction::Static(json_response(404, ErrorResponse::new("not_found")));
    };
    if method != "POST" {
        return RouteAction::Static(method_not_allowed("POST"));
    }
    if !internal_enabled {
        return RouteAction::Static(json_response(
            503,
            ErrorResponse::new("ad_analysis_disabled"),
        ));
    }
    action
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

fn handle_poll_job(method: &str, enabled: bool, job_id: &str) -> RouteAction {
    if method != "POST" {
        return RouteAction::Static(method_not_allowed("POST"));
    }
    if !enabled {
        return RouteAction::Static(json_response(
            503,
            ErrorResponse::new("ad_analysis_disabled"),
        ));
    }
    if !crate::job::valid_job_id(job_id) {
        return RouteAction::Static(json_response(404, ErrorResponse::new("not_found")));
    }
    RouteAction::PollJob {
        job_id: job_id.to_string(),
    }
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

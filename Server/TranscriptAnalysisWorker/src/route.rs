use crate::types::ErrorResponse;

pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";
pub const HEALTH_PATH: &str = "/health";
pub const APP_ATTEST_CHALLENGE_PATH: &str = "/v1/app-attest/challenge";
pub const APP_ATTEST_REGISTER_PATH: &str = "/v1/app-attest/register";
pub const INSTALL_DELETE_PATH: &str = "/v1/install/delete";
pub const ANALYZE_TRANSCRIPT_PATH: &str = "/v1/transcript-analysis/transcript";
pub const TRANSCRIPT_ANALYSIS_JOBS_PREFIX: &str = "/v1/transcript-analysis/jobs/";
pub const ACCOUNT_BOOTSTRAP_PATH: &str = "/v1/transcript-analysis/account/bootstrap";

// No internal service-binding surface in v1: the transcription-chained lane
// stays deferred until standalone service is stable in production. When that
// surface lands, this worker deploys before RemoteTranscriptionWorker.

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
    InstallDelete,
    AnalyzeTranscript,
    AccountBootstrap,
    PollJob { job_id: String },
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

    if path == INSTALL_DELETE_PATH {
        return handle_app_attest_write(method, enabled, RouteAction::InstallDelete);
    }

    if path == ANALYZE_TRANSCRIPT_PATH {
        return handle_analysis(method, enabled);
    }

    if path == ACCOUNT_BOOTSTRAP_PATH {
        // Same POST + kill-switch shape as the other authenticated writes.
        return handle_app_attest_write(method, enabled, RouteAction::AccountBootstrap);
    }

    if let Some(job_id) = path.strip_prefix(TRANSCRIPT_ANALYSIS_JOBS_PREFIX) {
        return handle_poll_job(method, enabled, job_id);
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
            ErrorResponse::new("transcript_analysis_disabled"),
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
            ErrorResponse::new("transcript_analysis_disabled"),
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
            ErrorResponse::new("transcript_analysis_disabled"),
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

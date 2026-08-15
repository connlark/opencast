use crate::types::ErrorResponse;

pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";
pub const HEALTH_PATH: &str = "/health";
pub const APP_ATTEST_CHALLENGE_PATH: &str = "/v1/app-attest/challenge";
pub const APP_ATTEST_REGISTER_PATH: &str = "/v1/app-attest/register";
pub const ACCOUNT_BOOTSTRAP_PATH: &str = "/v1/remote-transcription/account/bootstrap";
pub const JOBS_PATH: &str = "/v1/remote-transcription/jobs";
pub const JOBS_PREFIX: &str = "/v1/remote-transcription/jobs/";
pub const PURCHASE_REDEEM_PATH: &str = "/v1/remote-transcription/purchases/redeem";
/// Apple server-to-server notifications (no App Attest; the raw signed body
/// is forwarded to PurchaseWorker, which verifies before reading any field).
pub const STOREKIT_NOTIFICATIONS_PATH: &str = "/v1/apple/storekit/notifications";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobAction {
    Source,
    Poll,
    Result,
    Ack,
    Cancel,
    UploadStart,
    UploadParts,
    UploadComplete,
}

impl JobAction {
    fn from_segment(segment: &str) -> Option<Self> {
        match segment {
            "source" => Some(Self::Source),
            "poll" => Some(Self::Poll),
            "result" => Some(Self::Result),
            "ack" => Some(Self::Ack),
            "cancel" => Some(Self::Cancel),
            "upload/start" => Some(Self::UploadStart),
            "upload/parts" => Some(Self::UploadParts),
            "upload/complete" => Some(Self::UploadComplete),
            _ => None,
        }
    }
}

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
    AccountBootstrap,
    CreateJob,
    Job { job_id: String, action: JobAction },
    PurchaseRedeem,
    StoreKitNotifications,
}

pub fn valid_job_id(job_id: &str) -> bool {
    !job_id.is_empty()
        && job_id.len() <= 64
        && job_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

pub fn route_request(method: &str, path: &str, enabled: bool) -> RouteAction {
    if path == HEALTH_PATH {
        return RouteAction::Static(handle_health(method));
    }

    if path == APP_ATTEST_CHALLENGE_PATH {
        return post_action(method, enabled, RouteAction::AppAttestChallenge);
    }

    if path == APP_ATTEST_REGISTER_PATH {
        // Keep the verifier reachable while the public feature is off so a
        // junk-attestation smoke proves the production App Attest posture.
        // Challenge minting remains disabled, so no new registration can
        // succeed until the feature flag is deliberately enabled.
        return post_action(method, true, RouteAction::AppAttestRegister);
    }

    if path == ACCOUNT_BOOTSTRAP_PATH {
        return post_action(method, enabled, RouteAction::AccountBootstrap);
    }

    if path == JOBS_PATH {
        return post_action(method, enabled, RouteAction::CreateJob);
    }

    if path == PURCHASE_REDEEM_PATH {
        // The independent purchase kill switch owns this route. This keeps
        // the production flags-off response distinguishable and stable:
        // create => feature_disabled, redeem => purchases_disabled.
        return post_action(method, true, RouteAction::PurchaseRedeem);
    }

    if path == STOREKIT_NOTIFICATIONS_PATH {
        // Deliberately NOT gated on the public-enabled flag: Apple retries
        // server-to-server notifications and money state must stay honest
        // even while the app-facing surfaces are switched off. The handler
        // fails closed when no purchase backend exists in the lane.
        return post_action(method, true, RouteAction::StoreKitNotifications);
    }

    if let Some(rest) = path.strip_prefix(JOBS_PREFIX) {
        let mut segments = rest.splitn(2, '/');
        let job_id = segments.next().unwrap_or_default();
        let action = segments.next().and_then(JobAction::from_segment);
        if !valid_job_id(job_id) || action.is_none() {
            return RouteAction::Static(json_response(404, ErrorResponse::new("not_found")));
        }
        return post_action(
            method,
            enabled,
            RouteAction::Job {
                job_id: job_id.to_string(),
                action: action.expect("checked above"),
            },
        );
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

fn post_action(method: &str, enabled: bool, action: RouteAction) -> RouteAction {
    if method != "POST" {
        return RouteAction::Static(method_not_allowed("POST"));
    }
    if !enabled {
        return RouteAction::Static(json_response(
            503,
            ErrorResponse::new(crate::types::ERROR_FEATURE_DISABLED),
        ));
    }
    action
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_off_keeps_only_fail_closed_verification_and_money_routes() {
        assert!(matches!(
            route_request("POST", JOBS_PATH, false),
            RouteAction::Static(StaticResponse { status: 503, .. })
        ));
        assert_eq!(
            route_request("POST", APP_ATTEST_REGISTER_PATH, false),
            RouteAction::AppAttestRegister
        );
        assert_eq!(
            route_request("POST", PURCHASE_REDEEM_PATH, false),
            RouteAction::PurchaseRedeem
        );
        assert!(matches!(
            route_request("POST", APP_ATTEST_CHALLENGE_PATH, false),
            RouteAction::Static(StaticResponse { status: 503, .. })
        ));
    }
}

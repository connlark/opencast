//! Routing and the proxy's own response codes. Every body the proxy writes
//! itself is `{"error": "<static code>"}`: a string, where Gemini's `error`
//! is an object, so a client can tell the two apart.

use serde::Serialize;

use crate::ledger::RefusalCode;

pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";
pub const HEALTH_PATH: &str = "/health";
pub const APP_ATTEST_CHALLENGE_PATH: &str = "/v1/app-attest/challenge";
pub const APP_ATTEST_REGISTER_PATH: &str = "/v1/app-attest/register";
pub const TRIAL_ANALYZE_PATH: &str = "/v1/trial/analyze";
pub const TRIAL_STATUS_PATH: &str = "/v1/trial/status";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteAction {
    Health,
    Challenge,
    Register,
    Analyze,
    /// `POST`: the App Attest envelope or the bearer lane.
    Status,
    /// `GET`: the bearer lane only (an envelope cannot ride a GET).
    StatusBearer,
    NotFound,
    MethodNotAllowed(&'static str),
}

pub fn route(method: &str, path: &str) -> RouteAction {
    match (path, method) {
        (HEALTH_PATH, "GET") => RouteAction::Health,
        (HEALTH_PATH, _) => RouteAction::MethodNotAllowed("GET"),
        (APP_ATTEST_CHALLENGE_PATH, "POST") => RouteAction::Challenge,
        (APP_ATTEST_REGISTER_PATH, "POST") => RouteAction::Register,
        (TRIAL_ANALYZE_PATH, "POST") => RouteAction::Analyze,
        (APP_ATTEST_CHALLENGE_PATH | APP_ATTEST_REGISTER_PATH | TRIAL_ANALYZE_PATH, _) => {
            RouteAction::MethodNotAllowed("POST")
        }
        (TRIAL_STATUS_PATH, "POST") => RouteAction::Status,
        (TRIAL_STATUS_PATH, "GET") => RouteAction::StatusBearer,
        (TRIAL_STATUS_PATH, _) => RouteAction::MethodNotAllowed("GET, POST"),
        _ => RouteAction::NotFound,
    }
}

/// A code the proxy answers with itself (never a provider reply).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyCode {
    Refusal(RefusalCode),
    PayloadTooLarge,
    Unauthorized,
    TrialDisabled,
    TrialUnavailable,
    ProviderTimeout,
    ProviderUnreachable,
    ProviderBodyTooLarge,
    NotFound,
    MethodNotAllowed,
    /// AppAttestCore's codes, passed through with their own status.
    Auth {
        status: u16,
        code: &'static str,
    },
    /// Challenge and registration codes (AdAnalysisWorker's set).
    Registration {
        status: u16,
        code: &'static str,
    },
}

impl ProxyCode {
    pub fn code(self) -> &'static str {
        match self {
            Self::Refusal(code) => code.as_str(),
            Self::PayloadTooLarge => "payload_too_large",
            Self::Unauthorized => "unauthorized",
            Self::TrialDisabled => "trial_disabled",
            Self::TrialUnavailable => "trial_unavailable",
            Self::ProviderTimeout => "provider_timeout",
            Self::ProviderUnreachable => "provider_unreachable",
            Self::ProviderBodyTooLarge => "provider_body_too_large",
            Self::NotFound => "not_found",
            Self::MethodNotAllowed => "method_not_allowed",
            Self::Auth { code, .. } | Self::Registration { code, .. } => code,
        }
    }

    pub fn status(self) -> u16 {
        match self {
            Self::Refusal(RefusalCode::TrialBusy) => 409,
            Self::Refusal(RefusalCode::TrialExhausted | RefusalCode::TrialRunBound) => 403,
            Self::Refusal(RefusalCode::TrialPaused) => 503,
            Self::Refusal(RefusalCode::BearerLimited) => 429,
            Self::Refusal(RefusalCode::RequestInvalid) => 400,
            Self::PayloadTooLarge => 413,
            Self::Unauthorized => 401,
            Self::TrialDisabled | Self::TrialUnavailable => 503,
            Self::ProviderTimeout => 504,
            Self::ProviderUnreachable | Self::ProviderBodyTooLarge => 502,
            Self::NotFound => 404,
            Self::MethodNotAllowed => 405,
            Self::Auth { status, .. } | Self::Registration { status, .. } => status,
        }
    }
}

/// Why the challenge route has no source token for a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChallengeSourceFailure {
    /// No client address header: the client's request.
    MissingSignal,
    /// No usable `CHALLENGE_SOURCE_HASH_KEY`: this service's configuration.
    KeyUnavailable,
}

impl ChallengeSourceFailure {
    pub fn proxy_code(self) -> ProxyCode {
        match self {
            Self::MissingSignal => ProxyCode::Registration {
                status: 400,
                code: "missing_challenge_source",
            },
            Self::KeyUnavailable => ProxyCode::TrialUnavailable,
        }
    }
}

#[derive(Serialize)]
pub struct ErrorBody {
    pub error: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after_seconds: Option<u64>,
}

pub fn error_body(code: ProxyCode, retry_after_seconds: Option<u64>) -> Vec<u8> {
    serde_json::to_vec(&ErrorBody {
        error: code.code(),
        retry_after_seconds,
    })
    .unwrap_or_else(|_| br#"{"error":"trial_unavailable"}"#.to_vec())
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct StatusBody {
    pub mode: &'static str,
    pub units_remaining: u32,
    pub starts_at: String,
    pub month_paused: bool,
}

/// Refused on every route before anything else, and without a log line: an
/// `x-goog-api-key` header, or any query string. No route takes a query,
/// and Workers Logs attaches the request URL to every event the request
/// logs, so a key (or anything else) in a query must never reach a log.
pub fn refused_unlogged(has_goog_key_header: bool, has_query: bool) -> bool {
    has_goog_key_header || has_query
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_and_methods() {
        assert_eq!(route("GET", "/health"), RouteAction::Health);
        assert_eq!(route("POST", "/v1/trial/analyze"), RouteAction::Analyze);
        assert_eq!(
            route("GET", "/v1/trial/analyze"),
            RouteAction::MethodNotAllowed("POST")
        );
        assert_eq!(route("POST", "/v1/trial/status"), RouteAction::Status);
        assert_eq!(route("GET", "/v1/trial/status"), RouteAction::StatusBearer);
        assert_eq!(
            route("PUT", "/v1/trial/status"),
            RouteAction::MethodNotAllowed("GET, POST")
        );
        assert_eq!(
            route("POST", "/v1/app-attest/challenge"),
            RouteAction::Challenge
        );
        assert_eq!(
            route("POST", "/v1/app-attest/register"),
            RouteAction::Register
        );
        assert_eq!(route("POST", "/v1/trial/analyze/"), RouteAction::NotFound);
        assert_eq!(
            route("POST", "/v1beta/models/gemini-3.8-flash:generateContent"),
            RouteAction::NotFound
        );
    }

    #[test]
    fn refusal_statuses_and_bodies() {
        for (code, status) in [
            (RefusalCode::TrialBusy, 409),
            (RefusalCode::TrialExhausted, 403),
            (RefusalCode::TrialRunBound, 403),
            (RefusalCode::TrialPaused, 503),
            (RefusalCode::BearerLimited, 429),
            (RefusalCode::RequestInvalid, 400),
        ] {
            assert_eq!(ProxyCode::Refusal(code).status(), status);
        }
        assert_eq!(
            error_body(ProxyCode::Refusal(RefusalCode::TrialBusy), Some(42)),
            br#"{"error":"trial_busy","retry_after_seconds":42}"#
        );
        assert_eq!(
            error_body(ProxyCode::TrialUnavailable, None),
            br#"{"error":"trial_unavailable"}"#
        );
    }

    #[test]
    fn any_query_or_a_key_header_is_refused() {
        assert!(refused_unlogged(true, false));
        assert!(refused_unlogged(false, true));
        assert!(refused_unlogged(true, true));
        assert!(!refused_unlogged(false, false));
    }
}

pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";
pub const METHOD_NOT_ALLOWED_JSON: &str = r#"{"error":"method_not_allowed"}"#;
pub const NOT_FOUND_JSON: &str = r#"{"error":"not_found"}"#;

pub const SECURE_HELLO_PATH: &str = "/v1/secure/hello";
pub const DEVICES_REGISTER_PATH: &str = "/v1/devices/register";
pub const DEVICES_UNREGISTER_PATH: &str = "/v1/devices/unregister";
pub const INSTALL_DELETE_PATH: &str = "/v1/install/delete";
pub const DEBUG_SEND_TEST_PUSH_PATH: &str = "/v1/debug/send-test-push";
pub const SUBSCRIPTIONS_SYNC_PATH: &str = "/v1/subscriptions/sync";
pub const DEBUG_POLL_SUBSCRIPTIONS_PATH: &str = "/v1/debug/poll-subscriptions";
pub const ADMIN_TEST_POLL_FEED_PATH: &str = "/v1/admin/test/poll-feed";

const HEALTH_PATH: &str = "/health";
const HEALTH_JSON: &str = r#"{"message":"hello world"}"#;

#[derive(Debug, PartialEq, Eq)]
pub struct Header {
    pub name: &'static str,
    pub value: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub struct RouteResponse {
    pub status: u16,
    pub headers: Vec<Header>,
    pub body: &'static str,
}

pub fn handle_request(method: &str, path: &str) -> RouteResponse {
    if path == HEALTH_PATH {
        return handle_health(method);
    }

    json_response(404, NOT_FOUND_JSON)
}

fn handle_health(method: &str) -> RouteResponse {
    if method != "GET" {
        return RouteResponse {
            status: 405,
            headers: vec![
                Header {
                    name: "content-type",
                    value: JSON_CONTENT_TYPE,
                },
                Header {
                    name: "allow",
                    value: "GET",
                },
            ],
            body: METHOD_NOT_ALLOWED_JSON,
        };
    }

    json_response(200, HEALTH_JSON)
}

fn json_response(status: u16, body: &'static str) -> RouteResponse {
    RouteResponse {
        status,
        headers: vec![Header {
            name: "content-type",
            value: JSON_CONTENT_TYPE,
        }],
        body,
    }
}

pub fn diagnostic_endpoint_path(path: &str) -> bool {
    matches!(
        path,
        SECURE_HELLO_PATH | DEBUG_SEND_TEST_PUSH_PATH | DEBUG_POLL_SUBSCRIPTIONS_PATH
    )
}

pub fn public_write_endpoint(method: &str, path: &str) -> bool {
    method == "POST"
        && matches!(
            path,
            "/v1/app-attest/challenge"
                | "/v1/app-attest/register"
                | DEVICES_REGISTER_PATH
                | SUBSCRIPTIONS_SYNC_PATH
        )
}

pub fn parse_env_flag(value: Option<String>, default_value: bool) -> bool {
    value.map(|value| value == "true").unwrap_or(default_value)
}

pub fn content_length_exceeds(content_length: Option<&str>, max_bytes: usize) -> bool {
    content_length
        .and_then(|value| value.trim().parse::<usize>().ok())
        .map(|length| length > max_bytes)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostic_endpoint_classification_keeps_production_surface_small() {
        assert!(diagnostic_endpoint_path(SECURE_HELLO_PATH));
        assert!(diagnostic_endpoint_path(DEBUG_SEND_TEST_PUSH_PATH));
        assert!(diagnostic_endpoint_path(DEBUG_POLL_SUBSCRIPTIONS_PATH));
        assert!(!diagnostic_endpoint_path(DEVICES_REGISTER_PATH));
        assert!(!diagnostic_endpoint_path(SUBSCRIPTIONS_SYNC_PATH));
    }

    #[test]
    fn public_kill_switch_only_blocks_public_write_setup_paths() {
        assert!(public_write_endpoint("POST", "/v1/app-attest/challenge"));
        assert!(public_write_endpoint("POST", "/v1/app-attest/register"));
        assert!(public_write_endpoint("POST", DEVICES_REGISTER_PATH));
        assert!(public_write_endpoint("POST", SUBSCRIPTIONS_SYNC_PATH));
        assert!(!public_write_endpoint("POST", DEVICES_UNREGISTER_PATH));
        assert!(!public_write_endpoint("POST", INSTALL_DELETE_PATH));
        assert!(!public_write_endpoint("GET", "/v1/app-attest/challenge"));
        assert!(!public_write_endpoint("POST", DEBUG_SEND_TEST_PUSH_PATH));
    }

    #[test]
    fn missing_sensitive_env_flags_fail_closed() {
        assert!(!parse_env_flag(None, false));
        assert!(parse_env_flag(Some("true".to_string()), false));
        assert!(!parse_env_flag(Some("false".to_string()), true));
    }

    #[test]
    fn body_content_length_cap_rejects_only_oversized_lengths() {
        assert!(content_length_exceeds(Some("1025"), 1024));
        assert!(!content_length_exceeds(Some("1024"), 1024));
        assert!(!content_length_exceeds(Some("not-a-number"), 1024));
        assert!(!content_length_exceeds(None, 1024));
    }
}

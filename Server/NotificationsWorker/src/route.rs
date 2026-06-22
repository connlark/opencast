pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";
pub const METHOD_NOT_ALLOWED_JSON: &str = r#"{"error":"method_not_allowed"}"#;
pub const NOT_FOUND_JSON: &str = r#"{"error":"not_found"}"#;

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

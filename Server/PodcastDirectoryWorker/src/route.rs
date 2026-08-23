use crate::types::{
    ErrorResponse, ERROR_INVALID_APPLE_ID, ERROR_METHOD_NOT_ALLOWED, ERROR_NOT_FOUND,
};
use crate::validation::parse_apple_id;

pub const SEARCH_PATH: &str = "/v1/search";
pub const BY_APPLE_ID_PREFIX: &str = "/v1/podcasts/by-apple-id/";
pub const HEALTH_PATH: &str = "/v1/health";
pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteAction {
    Search,
    LookupByAppleId(u64),
    Health,
    Static(StaticResponse),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StaticResponse {
    pub status: u16,
    pub headers: Vec<Header>,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub name: &'static str,
    pub value: String,
}

pub fn route_request(method: &str, path: &str) -> RouteAction {
    match path {
        SEARCH_PATH => match method {
            "POST" => RouteAction::Search,
            _ => RouteAction::Static(method_not_allowed("POST")),
        },
        HEALTH_PATH => match method {
            "GET" => RouteAction::Health,
            _ => RouteAction::Static(method_not_allowed("GET")),
        },
        _ => {
            if let Some(segment) = path.strip_prefix(BY_APPLE_ID_PREFIX) {
                if method != "GET" {
                    return RouteAction::Static(method_not_allowed("GET"));
                }
                return match parse_apple_id(segment) {
                    Some(apple_id) => RouteAction::LookupByAppleId(apple_id),
                    None => RouteAction::Static(json_error(400, ERROR_INVALID_APPLE_ID)),
                };
            }
            RouteAction::Static(json_error(404, ERROR_NOT_FOUND))
        }
    }
}

pub fn json_error(status: u16, error: &str) -> StaticResponse {
    StaticResponse {
        status,
        headers: vec![Header {
            name: "content-type",
            value: JSON_CONTENT_TYPE.to_string(),
        }],
        body: serde_json::to_string(&ErrorResponse::new(error)).expect("error envelope serializes"),
    }
}

fn method_not_allowed(allow: &'static str) -> StaticResponse {
    let mut response = json_error(405, ERROR_METHOD_NOT_ALLOWED);
    response.headers.push(Header {
        name: "allow",
        value: allow.to_string(),
    });
    response
}

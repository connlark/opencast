pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";
pub const HEALTH_JSON: &str = r#"{"message":"ok"}"#;
pub const GATEWAY_DISABLED_JSON: &str = r#"{"error":"gateway_disabled"}"#;
pub const BAD_PATH_JSON: &str = r#"{"error":"bad_path"}"#;
pub const METHOD_NOT_ALLOWED_JSON: &str = r#"{"error":"method_not_allowed"}"#;
pub const NOT_FOUND_JSON: &str = r#"{"error":"not_found"}"#;
pub const OBJECT_NOT_FOUND_JSON: &str = r#"{"error":"object_not_found"}"#;
pub const RANGE_NOT_SATISFIABLE_JSON: &str = r#"{"error":"range_not_satisfiable"}"#;

pub const HEALTH_PATH: &str = "/health";
pub const MANIFEST_PATH: &str = "/v1/models/manifest";
pub const MANIFEST_SIGNATURE_PATH: &str = "/v1/models/manifest.sig";
pub const ASSET_PREFIX: &str = "/v1/models/assets/";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub name: &'static str,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StaticResponse {
    pub status: u16,
    pub headers: Vec<Header>,
    pub body: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssetRoute {
    pub model_id: String,
    pub version: String,
    pub component: String,
    pub relative_path: String,
    pub object_key: String,
    pub content_type: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteAction {
    Static(StaticResponse),
    Manifest { object_key: String, head: bool },
    ManifestSignature { object_key: String, head: bool },
    Asset { route: AssetRoute, head: bool },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ByteRange {
    pub start: u64,
    pub end: u64,
    pub length: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RangeSelection {
    Full,
    Partial(ByteRange),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RangeError {
    Invalid,
    NotSatisfiable,
}

pub fn route_request(
    method: &str,
    path: &str,
    gateway_enabled: bool,
    object_prefix: &str,
) -> RouteAction {
    if path == HEALTH_PATH {
        return RouteAction::Static(handle_health(method));
    }

    if model_gateway_path(path) && !gateway_enabled {
        return RouteAction::Static(json_response(503, GATEWAY_DISABLED_JSON));
    }

    if path == MANIFEST_PATH {
        return handle_manifest(method, object_prefix);
    }

    if path == MANIFEST_SIGNATURE_PATH {
        return handle_manifest_signature(method, object_prefix);
    }

    if let Some(suffix) = path.strip_prefix(ASSET_PREFIX) {
        return handle_asset(method, suffix, object_prefix);
    }

    RouteAction::Static(json_response(404, NOT_FOUND_JSON))
}

/// Evaluates an `If-None-Match` request header against an object's entity
/// tag using strong comparison: `*` matches any existing object, quoted and
/// bare forms are tolerated, and weak (`W/`-prefixed) candidates never match.
pub fn if_none_match_matches(header: Option<&str>, etag: &str) -> bool {
    let Some(header) = header else {
        return false;
    };
    let entity_tag = etag.trim().trim_matches('"');
    header.split(',').map(str::trim).any(|candidate| {
        candidate == "*"
            || (!candidate.starts_with("W/") && candidate.trim_matches('"') == entity_tag)
    })
}

pub fn parse_range_header(
    header: Option<&str>,
    object_size: u64,
) -> Result<RangeSelection, RangeError> {
    let Some(header) = header else {
        return Ok(RangeSelection::Full);
    };
    let Some(spec) = header.trim().strip_prefix("bytes=") else {
        return Err(RangeError::Invalid);
    };
    if spec.contains(',') {
        return Err(RangeError::Invalid);
    }

    let Some((start, end)) = spec.split_once('-') else {
        return Err(RangeError::Invalid);
    };
    if start.is_empty() && end.is_empty() {
        return Err(RangeError::Invalid);
    }
    if object_size == 0 {
        return Err(RangeError::NotSatisfiable);
    }

    let range = if start.is_empty() {
        let suffix = parse_u64(end)?;
        if suffix == 0 {
            return Err(RangeError::NotSatisfiable);
        }
        let length = suffix.min(object_size);
        let start = object_size - length;
        ByteRange {
            start,
            end: object_size - 1,
            length,
        }
    } else {
        let start = parse_u64(start)?;
        if start >= object_size {
            return Err(RangeError::NotSatisfiable);
        }
        let end = if end.is_empty() {
            object_size - 1
        } else {
            parse_u64(end)?
        };
        if end < start {
            return Err(RangeError::Invalid);
        }
        let end = end.min(object_size - 1);
        ByteRange {
            start,
            end,
            length: end - start + 1,
        }
    };

    Ok(RangeSelection::Partial(range))
}

pub fn content_range_header(range: &ByteRange, object_size: u64) -> String {
    format!("bytes {}-{}/{}", range.start, range.end, object_size)
}

pub fn unsatisfied_content_range_header(object_size: u64) -> String {
    format!("bytes */{object_size}")
}

pub fn manifest_object_key(object_prefix: &str) -> String {
    join_object_key(object_prefix, "manifests/current.json")
}

pub fn manifest_signature_object_key(object_prefix: &str) -> String {
    join_object_key(object_prefix, "manifests/current.json.sig")
}

fn handle_health(method: &str) -> StaticResponse {
    if method != "GET" {
        return method_not_allowed("GET");
    }

    json_response(200, HEALTH_JSON)
}

fn handle_manifest(method: &str, object_prefix: &str) -> RouteAction {
    match method {
        "GET" => RouteAction::Manifest {
            object_key: manifest_object_key(object_prefix),
            head: false,
        },
        "HEAD" => RouteAction::Manifest {
            object_key: manifest_object_key(object_prefix),
            head: true,
        },
        _ => RouteAction::Static(method_not_allowed("GET, HEAD")),
    }
}

fn handle_manifest_signature(method: &str, object_prefix: &str) -> RouteAction {
    match method {
        "GET" => RouteAction::ManifestSignature {
            object_key: manifest_signature_object_key(object_prefix),
            head: false,
        },
        "HEAD" => RouteAction::ManifestSignature {
            object_key: manifest_signature_object_key(object_prefix),
            head: true,
        },
        _ => RouteAction::Static(method_not_allowed("GET, HEAD")),
    }
}

fn handle_asset(method: &str, suffix: &str, object_prefix: &str) -> RouteAction {
    let head = match method {
        "GET" => false,
        "HEAD" => true,
        _ => return RouteAction::Static(method_not_allowed("GET, HEAD")),
    };

    match parse_asset_route(suffix, object_prefix) {
        Some(route) => RouteAction::Asset { route, head },
        None => RouteAction::Static(json_response(400, BAD_PATH_JSON)),
    }
}

fn parse_asset_route(suffix: &str, object_prefix: &str) -> Option<AssetRoute> {
    let segments: Vec<&str> = suffix.split('/').collect();
    if segments.len() < 4 || segments.iter().any(|segment| !valid_path_segment(segment)) {
        return None;
    }

    let model_id = segments[0].to_string();
    let version = segments[1].to_string();
    let component = segments[2];
    if !matches!(component, "model" | "tokenizer") {
        return None;
    }

    let relative_path = segments[3..].join("/");
    let release_path = format!("releases/{model_id}/{version}/{component}/{relative_path}");
    Some(AssetRoute {
        model_id,
        version,
        component: component.to_string(),
        relative_path: relative_path.clone(),
        object_key: join_object_key(object_prefix, &release_path),
        content_type: content_type_for_path(&relative_path),
    })
}

fn valid_path_segment(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && !segment.contains('\\')
        && !segment.contains('%')
}

fn model_gateway_path(path: &str) -> bool {
    path == MANIFEST_PATH || path == MANIFEST_SIGNATURE_PATH || path.starts_with(ASSET_PREFIX)
}

fn content_type_for_path(path: &str) -> &'static str {
    if path.to_ascii_lowercase().ends_with(".json") {
        "application/json; charset=utf-8"
    } else {
        "application/octet-stream"
    }
}

fn join_object_key(prefix: &str, suffix: &str) -> String {
    let prefix = prefix.trim_matches('/');
    let suffix = suffix.trim_matches('/');
    if prefix.is_empty() {
        suffix.to_string()
    } else {
        format!("{prefix}/{suffix}")
    }
}

fn parse_u64(value: &str) -> Result<u64, RangeError> {
    value.parse::<u64>().map_err(|_| RangeError::Invalid)
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
        body: METHOD_NOT_ALLOWED_JSON,
    }
}

pub fn json_response(status: u16, body: &'static str) -> StaticResponse {
    StaticResponse {
        status,
        headers: vec![Header {
            name: "content-type",
            value: JSON_CONTENT_TYPE.to_string(),
        }],
        body,
    }
}

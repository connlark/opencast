use opencast_model_gateway_worker::route::{
    content_range_header, manifest_object_key, manifest_signature_object_key, parse_range_header,
    route_request, unsatisfied_content_range_header, ByteRange, Header, RangeError, RangeSelection,
    RouteAction, BAD_PATH_JSON, GATEWAY_DISABLED_JSON, HEALTH_JSON, JSON_CONTENT_TYPE,
    METHOD_NOT_ALLOWED_JSON, NOT_FOUND_JSON,
};

#[test]
fn health_returns_ok() {
    let response = static_response(route_request("GET", "/health", true, "opencast/models"));

    assert_eq!(response.status, 200);
    assert_eq!(response.body, HEALTH_JSON);
    assert_eq!(
        response.headers,
        vec![Header {
            name: "content-type",
            value: JSON_CONTENT_TYPE.to_string(),
        }]
    );
}

#[test]
fn health_rejects_unsupported_methods() {
    let response = static_response(route_request("POST", "/health", true, "opencast/models"));

    assert_eq!(response.status, 405);
    assert_eq!(response.body, METHOD_NOT_ALLOWED_JSON);
    assert_eq!(
        response.headers,
        vec![
            Header {
                name: "content-type",
                value: JSON_CONTENT_TYPE.to_string(),
            },
            Header {
                name: "allow",
                value: "GET".to_string(),
            },
        ]
    );
}

#[test]
fn missing_routes_return_json_not_found() {
    let response = static_response(route_request("GET", "/missing", true, "opencast/models"));

    assert_eq!(response.status, 404);
    assert_eq!(response.body, NOT_FOUND_JSON);
}

#[test]
fn disabled_gateway_rejects_model_routes() {
    let response = static_response(route_request(
        "GET",
        "/v1/models/manifest",
        false,
        "opencast/models",
    ));

    assert_eq!(response.status, 503);
    assert_eq!(response.body, GATEWAY_DISABLED_JSON);
}

#[test]
fn manifest_maps_to_current_object_key() {
    let action = route_request("HEAD", "/v1/models/manifest", true, "/opencast/models/");

    assert_eq!(
        action,
        RouteAction::Manifest {
            object_key: "opencast/models/manifests/current.json".to_string(),
            head: true,
        }
    );
    assert_eq!(
        manifest_object_key("/opencast/models/"),
        "opencast/models/manifests/current.json"
    );
}

#[test]
fn manifest_signature_maps_to_current_signature_object_key() {
    let action = route_request("GET", "/v1/models/manifest.sig", true, "/opencast/models/");

    assert_eq!(
        action,
        RouteAction::ManifestSignature {
            object_key: "opencast/models/manifests/current.json.sig".to_string(),
            head: false,
        }
    );
    assert_eq!(
        manifest_signature_object_key("/opencast/models/"),
        "opencast/models/manifests/current.json.sig"
    );
}

#[test]
fn manifest_signature_rejects_unsupported_methods() {
    let response = static_response(route_request(
        "POST",
        "/v1/models/manifest.sig",
        true,
        "opencast/models",
    ));

    assert_eq!(response.status, 405);
    assert_eq!(response.body, METHOD_NOT_ALLOWED_JSON);
}

#[test]
fn manifest_rejects_unsupported_methods() {
    let response = static_response(route_request(
        "POST",
        "/v1/models/manifest",
        true,
        "opencast/models",
    ));

    assert_eq!(response.status, 405);
    assert_eq!(response.body, METHOD_NOT_ALLOWED_JSON);
}

#[test]
fn asset_route_maps_to_release_object_key() {
    let action = route_request(
        "GET",
        "/v1/models/assets/openai_whisper-large-v3-v20240930_626MB/20240930_626MB-v1/model/AudioEncoder.mlmodelc/weights/weight.bin",
        true,
        "opencast/models",
    );

    let RouteAction::Asset { route, head } = action else {
        panic!("expected asset route");
    };
    assert!(!head);
    assert_eq!(route.model_id, "openai_whisper-large-v3-v20240930_626MB");
    assert_eq!(route.version, "20240930_626MB-v1");
    assert_eq!(route.component, "model");
    assert_eq!(
        route.relative_path,
        "AudioEncoder.mlmodelc/weights/weight.bin"
    );
    assert_eq!(
        route.object_key,
        "opencast/models/releases/openai_whisper-large-v3-v20240930_626MB/20240930_626MB-v1/model/AudioEncoder.mlmodelc/weights/weight.bin"
    );
    assert_eq!(route.content_type, "application/octet-stream");
}

#[test]
fn json_content_type_detection_is_case_insensitive() {
    let action = route_request(
        "GET",
        "/v1/models/assets/model/version/model/CONFIG.JSON",
        true,
        "opencast/models",
    );

    let RouteAction::Asset { route, .. } = action else {
        panic!("expected asset route");
    };
    assert_eq!(route.content_type, JSON_CONTENT_TYPE);
}

#[test]
fn asset_route_rejects_bad_paths() {
    for path in [
        "/v1/models/assets/model/version/model",
        "/v1/models/assets/model/version/unknown/file.bin",
        "/v1/models/assets/model/version/model/../file.bin",
        "/v1/models/assets/model/version/model/%2e%2e/file.bin",
    ] {
        let response = static_response(route_request("GET", path, true, "opencast/models"));
        assert_eq!(response.status, 400);
        assert_eq!(response.body, BAD_PATH_JSON);
    }
}

#[test]
fn range_parser_supports_single_ranges() {
    assert_eq!(
        parse_range_header(Some("bytes=10-19"), 100),
        Ok(RangeSelection::Partial(ByteRange {
            start: 10,
            end: 19,
            length: 10,
        }))
    );
    assert_eq!(
        parse_range_header(Some("bytes=95-"), 100),
        Ok(RangeSelection::Partial(ByteRange {
            start: 95,
            end: 99,
            length: 5,
        }))
    );
    assert_eq!(
        parse_range_header(Some("bytes=-8"), 100),
        Ok(RangeSelection::Partial(ByteRange {
            start: 92,
            end: 99,
            length: 8,
        }))
    );
    assert_eq!(parse_range_header(None, 100), Ok(RangeSelection::Full));
}

#[test]
fn range_parser_rejects_invalid_or_unsatisfied_ranges() {
    assert_eq!(
        parse_range_header(Some("items=0-1"), 100),
        Err(RangeError::Invalid)
    );
    assert_eq!(
        parse_range_header(Some("bytes=0-1,2-3"), 100),
        Err(RangeError::Invalid)
    );
    assert_eq!(
        parse_range_header(Some("bytes=40-30"), 100),
        Err(RangeError::Invalid)
    );
    assert_eq!(
        parse_range_header(Some("bytes=100-101"), 100),
        Err(RangeError::NotSatisfiable)
    );
    assert_eq!(
        parse_range_header(Some("bytes=-0"), 100),
        Err(RangeError::NotSatisfiable)
    );
}

#[test]
fn content_range_headers_are_stable() {
    let range = ByteRange {
        start: 10,
        end: 19,
        length: 10,
    };

    assert_eq!(content_range_header(&range, 100), "bytes 10-19/100");
    assert_eq!(unsatisfied_content_range_header(100), "bytes */100");
}

fn static_response(action: RouteAction) -> opencast_model_gateway_worker::route::StaticResponse {
    match action {
        RouteAction::Static(response) => response,
        _ => panic!("expected static response"),
    }
}

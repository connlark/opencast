use opencast_model_gateway_worker::route::{
    content_range_header, edge_cacheable, if_none_match_matches, manifest_object_key,
    manifest_signature_object_key, parse_range_header, route_request,
    unsatisfied_content_range_header, ByteRange, Header, PolicyDocument, RangeError,
    RangeSelection, RouteAction, BAD_PATH_JSON, DEFAULT_POLICY_OBJECT_PREFIX,
    GATEWAY_DISABLED_JSON, HEALTH_JSON, IMMUTABLE_POLICY_CACHE_CONTROL, JSON_CONTENT_TYPE,
    MAX_EDGE_CACHED_OBJECT_BYTES, METHOD_NOT_ALLOWED_JSON, MUTABLE_POLICY_CACHE_CONTROL,
    NOT_FOUND_JSON,
};

#[test]
fn edge_cache_threshold_keeps_the_shipped_weights_and_drops_over_limit_objects() {
    // The largest shipped asset (large-v3 AudioEncoder weight.bin, manifest
    // byte_count 421,968,768) still tees into the cache; the Cache API's
    // 512 MB ceiling is the bound.
    assert!(edge_cacheable(421_968_768));
    assert!(edge_cacheable(MAX_EDGE_CACHED_OBJECT_BYTES));
    assert!(!edge_cacheable(MAX_EDGE_CACHED_OBJECT_BYTES + 1));
}

#[test]
fn if_none_match_strong_compares_quoted_and_bare_forms() {
    assert!(if_none_match_matches(Some("\"abc123\""), "\"abc123\""));
    assert!(if_none_match_matches(Some("abc123"), "\"abc123\""));
    assert!(if_none_match_matches(Some("\"abc123\""), "abc123"));
    assert!(!if_none_match_matches(Some("\"other\""), "\"abc123\""));
    assert!(!if_none_match_matches(None, "\"abc123\""));
}

#[test]
fn if_none_match_star_matches_any_existing_object() {
    assert!(if_none_match_matches(Some("*"), "\"abc123\""));
}

#[test]
fn if_none_match_scans_candidate_lists_and_rejects_weak_tags() {
    assert!(if_none_match_matches(
        Some("\"first\", \"abc123\" , \"last\""),
        "\"abc123\""
    ));
    assert!(!if_none_match_matches(Some("W/\"abc123\""), "\"abc123\""));
    assert!(!if_none_match_matches(
        Some("\"first\", \"second\""),
        "\"abc123\""
    ));
}

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

const POLICY_PATHS: [(&str, PolicyDocument); 7] = [
    ("/v1/policies/analysis", PolicyDocument::CurrentBundle),
    (
        "/v1/policies/analysis.sig",
        PolicyDocument::CurrentSignature,
    ),
    (
        "/v1/policies/analysis/1.json",
        PolicyDocument::VersionBundle(1),
    ),
    (
        "/v1/policies/analysis/1.json.sig",
        PolicyDocument::VersionSignature(1),
    ),
    (
        "/v1/policies/analysis/42.json",
        PolicyDocument::VersionBundle(42),
    ),
    (
        "/v1/policies/analysis/987654321.json.sig",
        PolicyDocument::VersionSignature(987_654_321),
    ),
    (
        "/v1/policies/analysis/4294967295.json",
        PolicyDocument::VersionBundle(u32::MAX),
    ),
];

#[test]
fn analysis_policy_routes_map_get_and_head() {
    for (path, document) in POLICY_PATHS {
        for (method, head) in [("GET", false), ("HEAD", true)] {
            assert_eq!(
                route_request(method, path, true, "opencast/models"),
                RouteAction::AnalysisPolicy { document, head },
                "{method} {path}"
            );
        }
    }
}

#[test]
fn analysis_policy_routes_reject_other_methods_and_near_paths() {
    for (path, _) in POLICY_PATHS {
        let response = static_response(route_request("PUT", path, true, "opencast/models"));
        assert_eq!(response.status, 405);
        assert_eq!(response.body, METHOD_NOT_ALLOWED_JSON);
        assert!(response
            .headers
            .iter()
            .any(|header| header.name == "allow" && header.value == "GET, HEAD"));
    }
    for path in [
        "/v1/policies/analysis/",
        "/v1/policies/analysis.json",
        "/v1/policies",
        "/v1/policies/analysis/v1.json",
        "/v1/policies/analysis/0.json",
        "/v1/policies/analysis/01.json",
        "/v1/policies/analysis/1.JSON",
        "/v1/policies/analysis/1.json.sig.sig",
        "/v1/policies/analysis/-1.json",
        "/v1/policies/analysis/4294967296.json",
        "/v1/policies/analysis/.json",
        "/v1/policies/analysis/1/2.json",
        "/v1/policies/analysis/current.json",
    ] {
        let response = static_response(route_request("GET", path, true, "opencast/models"));
        assert_eq!(response.status, 404, "{path}");
        assert_eq!(response.body, NOT_FOUND_JSON);
    }
}

#[test]
fn disabled_gateway_rejects_analysis_policy_routes() {
    for (path, _) in POLICY_PATHS {
        let response = static_response(route_request("GET", path, false, "opencast/models"));
        assert_eq!(response.status, 503, "{path}");
        assert_eq!(response.body, GATEWAY_DISABLED_JSON);
    }
}

#[test]
fn analysis_policy_object_keys_follow_the_policy_prefix() {
    assert_eq!(DEFAULT_POLICY_OBJECT_PREFIX, "opencast/policies");
    let keys = [
        (
            PolicyDocument::CurrentBundle,
            "opencast/policies/analysis/current.json",
        ),
        (
            PolicyDocument::CurrentSignature,
            "opencast/policies/analysis/current.json.sig",
        ),
        (
            PolicyDocument::VersionBundle(1),
            "opencast/policies/analysis/v1.json",
        ),
        (
            PolicyDocument::VersionSignature(12),
            "opencast/policies/analysis/v12.json.sig",
        ),
    ];
    for (document, key) in keys {
        assert_eq!(document.object_key("/opencast/policies/"), key);
    }
}

/// A version's copies never change, so the edge and clients may keep them;
/// the current documents name which version is live and must be revalidated
/// so a client never pairs a signature with a body from another generation.
#[test]
fn versioned_policy_documents_are_immutable_and_current_ones_revalidate() {
    for document in [
        PolicyDocument::VersionBundle(3),
        PolicyDocument::VersionSignature(3),
    ] {
        assert!(document.is_immutable());
        assert_eq!(document.cache_control(), IMMUTABLE_POLICY_CACHE_CONTROL);
    }
    for document in [
        PolicyDocument::CurrentBundle,
        PolicyDocument::CurrentSignature,
    ] {
        assert!(!document.is_immutable());
        assert_eq!(document.cache_control(), MUTABLE_POLICY_CACHE_CONTROL);
    }
    assert!(IMMUTABLE_POLICY_CACHE_CONTROL.contains("immutable"));
    assert!(IMMUTABLE_POLICY_CACHE_CONTROL.contains("max-age=31536000"));
    assert_eq!(MUTABLE_POLICY_CACHE_CONTROL, "no-cache");
}

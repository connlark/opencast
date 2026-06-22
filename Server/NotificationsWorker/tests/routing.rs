use opencast_notifications_worker::route::{
    handle_request, Header, JSON_CONTENT_TYPE, METHOD_NOT_ALLOWED_JSON, NOT_FOUND_JSON,
};

#[test]
fn health_returns_hello_world() {
    let response = handle_request("GET", "/health");

    assert_eq!(response.status, 200);
    assert_eq!(response.body, r#"{"message":"hello world"}"#);
    assert_eq!(
        response.headers,
        vec![Header {
            name: "content-type",
            value: JSON_CONTENT_TYPE,
        }]
    );
}

#[test]
fn health_rejects_unsupported_methods() {
    let response = handle_request("POST", "/health");

    assert_eq!(response.status, 405);
    assert_eq!(response.body, METHOD_NOT_ALLOWED_JSON);
    assert_eq!(
        response.headers,
        vec![
            Header {
                name: "content-type",
                value: JSON_CONTENT_TYPE,
            },
            Header {
                name: "allow",
                value: "GET",
            },
        ]
    );
}

#[test]
fn missing_routes_return_json_not_found() {
    let response = handle_request("GET", "/missing");

    assert_eq!(response.status, 404);
    assert_eq!(response.body, NOT_FOUND_JSON);
    assert_eq!(
        response.headers,
        vec![Header {
            name: "content-type",
            value: JSON_CONTENT_TYPE,
        }]
    );
}

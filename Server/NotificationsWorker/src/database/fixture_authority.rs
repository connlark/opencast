//! Local-only runtime dispatch probe: no SQL, bindings or production route.
use serde::Deserialize;
#[derive(Deserialize)]
#[serde(tag = "family", content = "request", rename_all = "snake_case")]
enum Operation {
    D(super::slice_d::Operation),
    E(super::slice_e::Operation),
    F(super::slice_f::Operation),
}
pub(super) async fn handle(
    mut request: worker::Request,
    env: worker::Env,
) -> worker::Result<worker::Response> {
    if request.method() != worker::Method::Post {
        return worker::Response::error("method_not_allowed", 405);
    }
    // The same token-gated fixture build drives the actual production callers.
    // Only the route is adapted; selection and deadlines belong to the handler.
    let path = request.path();
    let route = match path.as_str() {
        "/authority/cleanup" => Some("/cleanup"),
        "/authority/dispatch" => Some("/dispatch"),
        "/authority/delivery" => Some("/queue"),
        "/authority/operation" => None,
        _ => return worker::Response::error("unported_operation", 404),
    };
    if let Some(route) = route {
        let mut init = worker::RequestInit::new();
        init.with_method(worker::Method::Post)
            .with_headers(request.headers().clone())
            .with_body(Some(request.text().await?.into()));
        let routed = worker::Request::new_with_init(
            &format!("https://authority-fixture.invalid{route}"),
            &init,
        )?;
        return if route == "/queue" {
            crate::worker_app::handle_request(routed, env).await
        } else {
            crate::polling::handle(routed, env).await
        };
    }
    let db = super::Authority::new(
        &env,
        Some(request.inner().signal()),
        super::Authority::default_deadline(crate::polling::timing::now_ms()),
    )?;
    let operation: Operation = match serde_json::from_str(&request.text().await?) {
        Ok(operation) => operation,
        Err(_) => return worker::Response::error("invalid_semantic_request", 400),
    };
    let result = match operation {
        Operation::D(operation) => super::slice_d::execute(&db, operation).await,
        Operation::E(operation) => super::slice_e::execute(&db, operation).await,
        Operation::F(operation) => super::slice_f::execute(&db, operation).await,
    };
    worker::Response::from_json(&match result {
        Ok(response) => serde_json::json!({"ok":true,"response":response}),
        Err(error) => serde_json::json!({"ok":false,"error":error.to_string()}),
    })
}

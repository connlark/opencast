#![cfg(feature = "storage-fixture")]
//! Token-gated fixture authority. No arbitrary SQL endpoint or backend fallback.
use super::slice_e::Operation;
use super::*;
use futures_util::{future::pending, FutureExt};
use serde::Deserialize;
use worker::{js_sys, wasm_bindgen, wasm_bindgen_futures};

// Log synchronously when the invocation owner disposes an aborted future.
// A response-side log alone can be lost when the edge stops polling it.
struct CancellationLog(worker::web_sys::AbortSignal);
impl Drop for CancellationLog {
    fn drop(&mut self) {
        if self.0.aborted() {
            worker::console_warn!(
                "{}",
                serde_json::json!({"event":"storage_fixture_cancelled","kind":"cancelled","phase":"invocation","outcome":"unknown"})
            );
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    request: Operation,
    #[serde(default)]
    lose_result: bool,
    /// Fixture-only enclosing deadline, relative to arrival. Absent means the
    /// full storage window; PostgreSQL segments must not outlive it.
    #[serde(default)]
    deadline_in_ms: Option<u64>,
}
pub(crate) async fn handle(
    mut request: worker::Request,
    env: worker::Env,
) -> worker::Result<worker::Response> {
    // Authenticate before routing or parsing, including every auxiliary route.
    // Reuse the shipped hash-then-constant-time comparison; no new dependency.
    let supplied = request.headers().get("Authorization")?.unwrap_or_default();
    let expected = env
        .secret("SLICE_TOKEN")
        .ok()
        .map(|token| token.to_string());
    let authorized = expected.as_deref().is_some_and(|expected| {
        !expected.is_empty()
            && opencast_app_attest_core::auth::bearer_token(Some(&supplied)).is_some_and(
                |provided| opencast_app_attest_core::auth::token_matches(provided, expected),
            )
    });
    if !authorized {
        return worker::Response::error("Not found", 404);
    }
    let _cancellation_log = CancellationLog(request.inner().signal());
    if request.url()?.path() == "/slice-e/collect" && request.method() == worker::Method::Post {
        // The fixture seeds cleanup enabled. Production's control check stays
        // in collect_bounded; both authorities share its actual object loop.
        let count = crate::observation::gc::collect_enabled(
            &env.bucket("SLICE_BUCKET")?,
            50,
            None,
            // The fixture's own orchestration is never witnessed.
            &crate::storage_witness::Timer::default(),
            |operation| collect_operation(&env, operation),
        )
        .await?;
        return worker::Response::from_json(&serde_json::json!({"selected":count}));
    }

    let arrived = opencast_worker_database_core::database::now();
    if request.url()?.path() != "/slice-e/operation" || request.method() != worker::Method::Post {
        return worker::Response::error("unported_operation", 404);
    }
    // Parse the bytes directly so integer-boundary fixtures reach the semantic
    // validator without a JavaScript-to-Rust number conversion rejecting first.
    let input: Request = match serde_json::from_str(&request.text().await?) {
        Ok(input) => input,
        Err(_) => return worker::Response::error("invalid_semantic_request", 400),
    };
    let backend = env.var("STORAGE_AUTHORITY")?.to_string();
    let result = match backend.as_str() {
        "postgres" => {
            let window = input
                .deadline_in_ms
                .unwrap_or(opencast_worker_database_core::lifecycle::HANDLER_MS);
            if window > opencast_worker_database_core::lifecycle::HANDLER_MS {
                return worker::Response::error("invalid_fixture_deadline", 400);
            }
            let deadline = arrived + window;
            // The enclosing run_with_abort_signal owns and synchronously drops
            // this entire future. Database's CloseGuard closes its JS transport
            // even when the abandoned request promise is never polled again.
            postgres::slice_e::execute(
                &env,
                &input.request,
                super::fixture::cancel::token(),
                deadline,
                None,
            )
            .await
        }
        _ => return worker::Response::error("unavailable_storage_authority", 503),
    };
    let body = match result {
        Ok(response) if input.lose_result => {
            // Same after-result semantic boundary on both backends. The real
            // adapter's transport/COMMIT uncertainty is tested separately.
            let mut failure = Failure::new(Kind::Injected, Phase::Commit);
            if input.request.is_read() {
                failure.outcome = Outcome::NotApplicable;
            }
            serde_json::json!({"ok":false,"error":failure,"metrics":response.metrics})
        }
        Ok(response) => serde_json::json!({"ok":true,"response":response}),
        Err(failure) => {
            let handler_ms = opencast_worker_database_core::database::now().saturating_sub(arrived);
            serde_json::json!({"ok":false,"retryable":failure.retryable(),"error":failure,"metrics":{"handler_ms":handler_ms}})
        }
    };
    worker::Response::from_json(&body)
}

// Closed fixture hook: record boundaries and inject a readback failure before
// dispatch. It is absent from production and cannot execute arbitrary SQL.
async fn collect_event(env: &worker::Env, event: serde_json::Value) -> worker::Result<()> {
    let mut init = worker::RequestInit::new();
    init.with_method(worker::Method::Post)
        .with_body(Some(wasm_bindgen::JsValue::from_str(&event.to_string())));
    let request = worker::Request::new_with_init("https://fixture.invalid/gc-event", &init)?;
    let mut response = env.service("GC_DIAG")?.fetch_request(request).await?;
    if response.status_code() != 200 {
        return Err(worker::Error::RustError(response.text().await?));
    }
    Ok(())
}

async fn collect_operation(env: &worker::Env, operation: Operation) -> worker::Result<Response> {
    if matches!(operation, Operation::ReadGcClaim { .. }) {
        collect_event(env, serde_json::json!({"event":"fence_begin"})).await?;
    }
    let response = match env.var("STORAGE_AUTHORITY")?.to_string().as_str() {
        "postgres" => super::slice_e::execute_postgres(
            env,
            &operation,
            pending().boxed_local().shared(),
            opencast_worker_database_core::database::now()
                + opencast_worker_database_core::lifecycle::HANDLER_MS,
            None,
        )
        .await
        .map_err(|failure| {
            worker::Error::RustError(serde_json::to_string(&failure).unwrap_or_default())
        })?,
        _ => {
            return Err(worker::Error::RustError(
                "unavailable_storage_authority".into(),
            ))
        }
    };
    let event = match operation {
        Operation::ClaimGc { .. } => "claim_done",
        Operation::ReadGcClaim { .. } => "fence_done",
        Operation::MarkDeleted { .. } => "mark_deleted",
        _ => "operation_done",
    };
    collect_event(
        env,
        serde_json::json!({"event":event,"operation":operation.id(),"replies":response.replies}),
    )
    .await?;
    Ok(response)
}

// A separate named export keeps the shared fixture dispatcher untouched.
#[worker::wasm_bindgen::prelude::wasm_bindgen]
pub async fn slice_e_fetch(
    request: worker::web_sys::Request,
    env: worker::Env,
) -> std::result::Result<worker::web_sys::Response, worker::wasm_bindgen::JsValue> {
    let signal = request.signal();
    let response =
        crate::invocation_owner::run_with_abort_signal(signal, handle(request.into(), env))
            .await
            .unwrap_or_else(|| worker::Response::error("cancelled", 499));
    response.map(Into::into).map_err(Into::into)
}

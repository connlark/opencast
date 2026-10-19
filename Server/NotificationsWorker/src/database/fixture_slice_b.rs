//! Token-gated fixture authority. No arbitrary SQL endpoint or backend fallback.
use super::slice_b::Operation;
use super::*;
use futures_util::{future::pending, FutureExt};
use serde::Deserialize;

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
    let arrived = opencast_worker_database_core::database::now();
    if request.url()?.path() != "/slice-b/operation" || request.method() != worker::Method::Post {
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
            postgres::slice_b::execute(
                &env,
                &input.request,
                pending().boxed_local().shared(),
                deadline,
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

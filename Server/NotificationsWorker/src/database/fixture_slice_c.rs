#![cfg(feature = "storage-fixture")]
//! Token-gated local semantic fixture. The shipped entrypoint never routes here.
use super::slice_c::{AttestAuthority, Operation};
use super::*;
use futures_util::{future::pending, FutureExt};
use opencast_app_attest_core::app_attest_envelope::slice_c::AttestStorage;
use serde::Deserialize;
use worker::wasm_bindgen::{self, JsValue};

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

/// A distinct export lets the local harness use the C entrypoint without editing
/// the shared fixture dispatcher. Its JavaScript wrapper supplies its own Env.
#[wasm_bindgen::prelude::wasm_bindgen]
pub fn identity_fixture(
    request: worker::web_sys::Request,
    env: worker::Env,
) -> worker::js_sys::Promise {
    worker::wasm_bindgen_futures::future_to_promise(async move {
        let request: worker::Request = request.into();
        let signal = request.inner().signal();
        let response = crate::invocation_owner::run_with_abort_signal(signal, handle(request, env))
            .await
            .unwrap_or_else(|| worker::Response::error("cancelled", 499))
            .map_err(|error| JsValue::from_str(&error.to_string()))?;
        let response: worker::web_sys::Response = response.into();
        Ok(JsValue::from(response))
    })
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    request: Operation,
    #[serde(default)]
    lose_result: bool,
    deadline_in_ms: Option<u64>,
}
async fn handle(
    mut request: worker::Request,
    env: worker::Env,
) -> worker::Result<worker::Response> {
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
    let path = request.url()?.path().to_string();
    // Existing closed adapter/plan/polling fixtures remain unchanged.
    if matches!(path.as_str(), "/adapter" | "/plan" | "/operation") {
        return super::fixture::handle(request, env).await;
    }
    if request.method() != worker::Method::Post {
        return worker::Response::error("unported_operation", 404);
    }
    if path == "/slice-c/auth" {
        return authenticate(request, env).await;
    }
    if path != "/slice-c/operation" && path != "/slice-c/reconcile" {
        return worker::Response::error("unported_operation", 404);
    }
    let arrived = worker::Date::now().as_millis();
    let input: Input = match serde_json::from_str(&request.text().await?) {
        Ok(value) => value,
        Err(_) => return worker::Response::error("invalid_semantic_request", 400),
    };
    if let Err(error) = super::slice_c::validate(&input.request) {
        return worker::Response::from_json(&serde_json::json!({"ok":false,"error":error}));
    }
    let window = input
        .deadline_in_ms
        .unwrap_or(opencast_worker_database_core::lifecycle::HANDLER_MS);
    if window > opencast_worker_database_core::lifecycle::HANDLER_MS {
        return worker::Response::error("invalid_fixture_deadline", 400);
    }
    let backend = env.var("STORAGE_AUTHORITY")?.to_string();
    if path == "/slice-c/reconcile" {
        let result = match backend.as_str() {
            "postgres" => {
                postgres::slice_c::reconcile(
                    &env,
                    &input.request,
                    pending().boxed_local().shared(),
                    arrived + window,
                )
                .await
            }
            _ => return worker::Response::error("unavailable_storage_authority", 503),
        };
        return worker::Response::from_json(&match result {
            Ok(evidence) => serde_json::json!({"ok":true,"evidence":evidence}),
            Err(error) => serde_json::json!({"ok":false,"error":error}),
        });
    }
    let result = match backend.as_str() {
        "postgres" => {
            postgres::slice_c::execute(
                &env,
                &input.request,
                pending().boxed_local().shared(),
                arrived + window,
            )
            .await
        }
        _ => return worker::Response::error("unavailable_storage_authority", 503),
    };
    let body = match result {
        Ok(response) if input.lose_result => {
            let mut failure = Failure::new(Kind::Injected, Phase::Commit);
            if input.request.is_read() {
                failure.outcome = Outcome::NotApplicable;
            }
            serde_json::json!({"ok":false,"error":failure,"metrics":response.metrics})
        }
        Ok(response) => serde_json::json!({"ok":true,"response":response}),
        Err(failure) => {
            serde_json::json!({"ok":false,"retryable":failure.retryable(),"error":failure,"metrics":{"handler_ms":worker::Date::now().as_millis().saturating_sub(arrived)}})
        }
    };
    worker::Response::from_json(&body)
}
// Keep key lookup on its normal budget; only the real counter segment gets the
// requested fault deadline. The production authority still classifies its result.
struct AuthenticationFixture<'a> {
    authority: AttestAuthority<'a>,
    counter_deadline_ms: Option<u64>,
}
impl AttestStorage for AuthenticationFixture<'_> {
    async fn read_key<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
    ) -> worker::Result<Option<opencast_app_attest_core::app_attest_storage::AppAttestKeyRow>> {
        self.authority.read_key(install, key).await
    }
    async fn compare_and_advance_counter<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
        previous: i64,
        next: i64,
        now: i64,
    ) -> worker::Result<bool> {
        if let (Some(window), AttestAuthority::Postgres { env, cancel, .. }) =
            (self.counter_deadline_ms, &self.authority)
        {
            return AttestAuthority::Postgres {
                env,
                cancel: cancel.clone(),
                deadline: worker::Date::now().as_millis() + window,
            }
            .compare_and_advance_counter(install, key, previous, next, now)
            .await;
        }
        self.authority
            .compare_and_advance_counter(install, key, previous, next, now)
            .await
    }
}
async fn authenticate(
    mut request: worker::Request,
    env: worker::Env,
) -> worker::Result<worker::Response> {
    let now = request
        .headers()
        .get("X-Fixture-Now")?
        .and_then(|n| n.parse::<i64>().ok())
        .ok_or_else(|| worker::Error::RustError("fixture time required".into()))?;
    let app_id = env.var("SLICE_APP_ID")?.to_string();
    let environment = env.var("SLICE_APP_ENVIRONMENT")?.to_string();
    let backend = env.var("STORAGE_AUTHORITY")?.to_string();
    let counter_deadline_ms = request
        .headers()
        .get("X-Fixture-CAS-Deadline-Ms")?
        .map(|value| value.parse::<u64>())
        .transpose()
        .map_err(|_| worker::Error::RustError("invalid fixture counter deadline".into()))?;
    if counter_deadline_ms.is_some_and(|window| {
        backend != "postgres" || window > opencast_worker_database_core::lifecycle::HANDLER_MS
    }) {
        return worker::Response::error("invalid_fixture_counter_deadline", 400);
    }
    let authority = match backend.as_str() {
        "postgres" => AttestAuthority::Postgres {
            env: &env,
            cancel: pending().boxed_local().shared(),
            deadline: worker::Date::now().as_millis()
                + opencast_worker_database_core::lifecycle::HANDLER_MS,
        },
        _ => return worker::Response::error("unavailable_storage_authority", 503),
    };
    let authority = AuthenticationFixture {
        authority,
        counter_deadline_ms,
    };
    let result =
        opencast_app_attest_core::app_attest_envelope::slice_c::authenticate_envelope_with_storage(
            &mut request,
            &authority,
            &app_id,
            &environment,
            now,
            "POST",
            "/slice-c/auth",
            131072,
            65536,
        )
        .await;
    match result {
        Ok(Ok(payload))=>worker::Response::from_json(&serde_json::json!({"ok":true,"install_id":payload.install_id,"key_id":payload.key_id,"payload":payload.payload})),
        Ok(Err(error))=>Ok(worker::Response::from_json(&serde_json::json!({"ok":false,"code":error.code,"install_id":error.install_id,"key_id":error.key_id}))?.with_status(error.status)),
        Err(error) => Ok(worker::Response::from_json(
            &serde_json::json!({"ok":false,"error":error.to_string()}),
        )?.with_status(500)),
    }
}

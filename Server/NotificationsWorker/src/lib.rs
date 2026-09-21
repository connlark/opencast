// The polling binary reuses the engine without the public notification handlers;
// LTO removes those unused paths. The default notification build still checks them.
#![cfg_attr(
    not(feature = "notification-entrypoint"),
    allow(dead_code, unused_imports)
)]
pub mod apns;
pub mod delivery;
#[cfg(target_arch = "wasm32")]
mod feed_control;
pub use opencast_app_attest_core::app_attest;
pub use opencast_app_attest_core::challenge_limits;
#[cfg(any(target_arch = "wasm32", test))]
pub(crate) use opencast_app_attest_core::d1_changes;
#[cfg(target_arch = "wasm32")]
pub use opencast_app_attest_core::random;
#[cfg(any(target_arch = "wasm32", test))]
mod deadline;
pub mod feed_admission;
#[cfg(any(target_arch = "wasm32", test))]
mod feed_fetch;
pub mod feed_identity;
pub mod feed_resource;
pub mod observation;
#[cfg(any(target_arch = "wasm32", test))]
mod poll_scheduling;
pub mod polling;
pub mod route;
pub mod rss;
#[cfg(target_arch = "wasm32")]
mod runtime_diagnostics;

#[cfg(any(target_arch = "wasm32", test))]
mod feed_scan_admission;
#[cfg(target_arch = "wasm32")]
mod feed_stream;
#[cfg(target_arch = "wasm32")]
mod feed_transport;
#[cfg(any(target_arch = "wasm32", test))]
mod invocation_owner;
#[cfg(any(target_arch = "wasm32", test))]
mod storage;
#[cfg(any(target_arch = "wasm32", test))]
mod subscription_admission;
#[cfg(any(target_arch = "wasm32", test))]
mod subscription_payloads;
#[cfg(target_arch = "wasm32")]
mod worker_app;
#[cfg(target_arch = "wasm32")]
mod worker_glue;

#[cfg(target_arch = "wasm32")]
use worker::*;

#[cfg(all(target_arch = "wasm32", feature = "notification-entrypoint"))]
#[event(fetch)]
pub async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    let signal = req.inner().signal();
    match invocation_owner::run_with_abort_signal(signal, worker_app::handle_request(req, env))
        .await
    {
        Some(result) => result,
        None => Err(Error::RustError("request_cancelled".into())),
    }
}

#[cfg(all(target_arch = "wasm32", feature = "notification-entrypoint"))]
#[event(scheduled)]
pub async fn scheduled(_event: ScheduledEvent, env: Env, _ctx: ScheduleContext) {
    if let Err(error) = worker_app::handle_scheduled(env).await {
        console_error!("scheduled notification maintenance failed: {:?}", error);
    }
}

pub mod apns;
pub use opencast_app_attest_core::app_attest;
pub use opencast_app_attest_core::challenge_limits;
#[cfg(target_arch = "wasm32")]
pub use opencast_app_attest_core::random;
#[cfg(any(target_arch = "wasm32", test))]
pub(crate) use opencast_app_attest_core::d1_changes;
pub mod feed_admission;
#[cfg(any(target_arch = "wasm32", test))]
mod feed_fetch;
pub mod feed_identity;
#[cfg(any(target_arch = "wasm32", test))]
mod notification_retry;
#[cfg(any(target_arch = "wasm32", test))]
mod poll_decisions;
#[cfg(any(target_arch = "wasm32", test))]
mod poll_scheduling;
pub mod route;
pub mod rss;

#[cfg(any(target_arch = "wasm32", test))]
mod storage;
#[cfg(any(target_arch = "wasm32", test))]
mod subscription_admission;
#[cfg(target_arch = "wasm32")]
mod worker_app;

#[cfg(target_arch = "wasm32")]
use worker::*;

#[cfg(target_arch = "wasm32")]
#[event(fetch)]
pub async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    worker_app::handle_request(req, env).await
}

#[cfg(target_arch = "wasm32")]
#[event(scheduled)]
pub async fn scheduled(_event: ScheduledEvent, env: Env, _ctx: ScheduleContext) {
    if let Err(error) = worker_app::handle_scheduled(env).await {
        console_error!("scheduled notification poll failed: {:?}", error);
    }
}

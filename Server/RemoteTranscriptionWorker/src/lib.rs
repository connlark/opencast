pub mod ad_analysis;
pub mod ai;
pub use opencast_app_attest_core::auth;
pub use opencast_app_attest_core::challenge_limits;
pub mod config;
#[cfg(target_arch = "wasm32")]
pub mod credit;
pub mod crypto;
pub mod eta;
pub mod job;
pub mod limiter;
pub mod media;
pub mod origin;
pub mod result_validation;
pub mod route;
pub mod sigv4;
pub mod stitch;
#[cfg(any(target_arch = "wasm32", test))]
pub mod storage;
pub mod sweeper;
pub mod types;

#[cfg(target_arch = "wasm32")]
mod job_do;

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
    match sweeper::run(&env).await {
        Ok(report) => console_log!(
            "orphan-sweeper objects={} stale_jobs={} truncated={}",
            report.orphan_object_count,
            report.stale_job_ids.len(),
            report.scan_truncated
        ),
        Err(error) => console_error!("orphan-sweeper-error {error}"),
    }
}

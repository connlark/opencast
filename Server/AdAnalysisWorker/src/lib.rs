#[cfg(target_arch = "wasm32")]
mod analysis;
pub mod auth;
pub mod challenge_limits;
#[cfg(any(target_arch = "wasm32", test))]
mod d1_changes;
pub mod gemini;
pub mod job;
pub mod prompt;
pub mod retry;
pub mod route;
#[cfg(any(target_arch = "wasm32", test))]
pub mod storage;
pub mod types;
pub mod usage;
pub mod validation;
pub mod windowing;

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

pub mod cache_policy;
pub mod logging;
pub mod podcast_index;
pub mod route;
pub mod types;
pub mod validation;

#[cfg(target_arch = "wasm32")]
mod worker_app;

#[cfg(target_arch = "wasm32")]
use worker::*;

#[cfg(target_arch = "wasm32")]
#[event(fetch)]
pub async fn fetch(req: Request, env: Env, ctx: Context) -> Result<Response> {
    worker_app::handle_request(req, env, ctx).await
}

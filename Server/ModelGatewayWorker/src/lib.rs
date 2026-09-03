pub mod manifest;
#[cfg(not(target_arch = "wasm32"))]
pub mod manifest_signature;
pub mod route;

#[cfg(target_arch = "wasm32")]
mod worker_app;

#[cfg(target_arch = "wasm32")]
use worker::*;

#[cfg(target_arch = "wasm32")]
#[event(fetch)]
pub async fn fetch(req: Request, env: Env, ctx: Context) -> Result<Response> {
    worker_app::handle_request(req, env, ctx).await
}

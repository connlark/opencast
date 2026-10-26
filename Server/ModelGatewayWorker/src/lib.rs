#[cfg(not(target_arch = "wasm32"))]
pub mod analysis_policy;
pub mod manifest;
#[cfg(not(target_arch = "wasm32"))]
pub mod manifest_signature;
#[cfg(not(target_arch = "wasm32"))]
pub mod policy_schema;
#[cfg(not(target_arch = "wasm32"))]
pub mod policy_swift;
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

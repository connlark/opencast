//! Standalone polling binary. The shared engine has no notification entrypoints
//! in this build; the deployment receives no APNs or public enrollment capability.
#[cfg(target_arch = "wasm32")]
use worker::*;

#[cfg(target_arch = "wasm32")]
#[event(fetch)]
pub async fn fetch(request: Request, env: Env, _ctx: Context) -> Result<Response> {
    opencast_notifications_worker::polling::handle(request, env).await
}

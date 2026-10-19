//! Standalone polling binary. The shared engine has no notification entrypoints
//! in this build; the deployment receives no APNs or public enrollment capability.
#[cfg(target_arch = "wasm32")]
use worker::*;

#[cfg(all(target_arch = "wasm32", not(feature = "storage-fixture")))]
#[event(fetch)]
pub async fn fetch(request: Request, env: Env, _ctx: Context) -> Result<Response> {
    if request.path() == "/identity" {
        return identity(request, env).await;
    }
    opencast_notifications_worker::polling::handle(request, env).await
}

/// The operator's nonmutating storage identity readback, behind the same
/// private capability as the other polling operations: one identity read (or
/// the isolate's cached verdict), no gate lock, no write.
#[cfg(target_arch = "wasm32")]
async fn identity(request: Request, env: Env) -> Result<Response> {
    use opencast_notifications_worker::database::{identity, Authority};
    let deadline = Authority::default_deadline(Date::now().as_millis());
    let db = Authority::new(&env, Some(request.inner().signal()), deadline)?;
    if env
        .var("POLLING_CAPABILITY")
        .map(|v| v.to_string() != "private")
        .unwrap_or(true)
    {
        return Response::error("not_found", 404);
    }
    if request.method() != Method::Post {
        return Response::error("method_not_allowed", 405);
    }
    Response::from_json(&identity::readback(&db).await?)
}

/// The storage-fixture build's entrypoint, last so a production build keeps
/// its line numbers: the fixture routes, then exactly the shipped fetch above.
#[cfg(all(target_arch = "wasm32", feature = "storage-fixture"))]
#[event(fetch)]
pub async fn fetch(request: Request, env: Env, _ctx: Context) -> Result<Response> {
    if let Some(response) =
        opencast_notifications_worker::polling::fixture::route(&request, &env).await?
    {
        return Ok(response);
    }
    if request.path() == "/identity" {
        return identity(request, env).await;
    }
    opencast_notifications_worker::polling::handle(request, env).await
}

pub mod admission;
pub mod alerts;
pub mod bundle;
pub mod clock;
pub mod config;
pub mod identifiers;
pub mod ledger;
pub mod ledger_sql;
pub mod provider;
pub mod request;
pub mod route;
pub mod telemetry;

#[cfg(target_arch = "wasm32")]
mod ledger_do;
#[cfg(target_arch = "wasm32")]
mod worker_app;

#[cfg(target_arch = "wasm32")]
pub use ledger_do::TrialLedger;

#[cfg(target_arch = "wasm32")]
#[worker::event(fetch)]
pub async fn fetch(
    req: worker::Request,
    env: worker::Env,
    _ctx: worker::Context,
) -> worker::Result<worker::Response> {
    Ok(worker_app::handle_request(req, env).await)
}

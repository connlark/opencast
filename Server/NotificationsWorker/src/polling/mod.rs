//! Durable scheduling shared by the standalone polling binary and its tests.
#[cfg(target_arch = "wasm32")]
mod cleanup;
#[cfg(target_arch = "wasm32")]
mod dispatch;
#[cfg(target_arch = "wasm32")]
mod execute;
#[cfg(target_arch = "wasm32")]
pub(crate) mod origin;
pub mod policy;
#[cfg(target_arch = "wasm32")]
mod runtime;
#[cfg(target_arch = "wasm32")]
pub(crate) use execute::fetch_failed;
#[cfg(target_arch = "wasm32")]
pub(crate) use execute::Fence;
pub use policy::Settle;
#[cfg(target_arch = "wasm32")]
pub use runtime::{handle, scheduled};

/// The 24-hour aggregate that replaces per-attempt receipts. Only a failure,
/// redelivery, rejected commit or clamp writes here; a healthy poll never does.
#[cfg(target_arch = "wasm32")]
pub(crate) async fn stat(db: &worker::D1Database, counter: &'static str) -> worker::Result<()> {
    use crate::delivery::db::{now, run};
    // `counter` is one of this module's fixed column names, never request text.
    run(db,&format!("INSERT INTO n_poll_stat(bucket,{counter}) VALUES(?1,1) ON CONFLICT(bucket) DO UPDATE SET {counter}={counter}+1"),&[serde_json::json!(now().div_euclid(3600))]).await?;
    Ok(())
}

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
pub(crate) mod timing;
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
pub(crate) async fn stat(
    db: &crate::database::Authority,
    counter: crate::database::polling::Counter,
) -> worker::Result<()> {
    crate::database::execute(
        db,
        crate::database::polling::Operation::RecordPollStat {
            counter,
            now: crate::delivery::db::now(),
        },
    )
    .await?;
    Ok(())
}

#[cfg(target_arch = "wasm32")]
pub(crate) mod watchdog;
// Fixture builds only, last so a production build keeps its line numbers.
#[cfg(all(target_arch = "wasm32", feature = "fixture-hooks"))]
pub mod fixture;

//! Durable notification authority. Queues are wakeups, never the source of truth.
#[cfg(target_arch = "wasm32")]
pub(crate) mod db;
#[cfg(target_arch = "wasm32")]
mod fanout;
#[cfg(target_arch = "wasm32")]
mod ingress;
#[cfg(target_arch = "wasm32")]
pub(crate) mod recovery;
#[cfg(target_arch = "wasm32")]
pub(crate) mod send;
pub mod wire;
#[cfg(target_arch = "wasm32")]
pub use db::{control, ensure_feed};
#[cfg(target_arch = "wasm32")]
pub use ingress::handle;
#[cfg(target_arch = "wasm32")]
pub use recovery::reconcile;

#[cfg(target_arch = "wasm32")]
mod grouping;

//! Complete feed observations. Parsing and policy are independent of delivery.
pub mod policy;
pub mod snapshot;

#[cfg(target_arch = "wasm32")]
pub(crate) mod drain;
#[cfg(target_arch = "wasm32")]
pub(crate) mod gc;
#[cfg(target_arch = "wasm32")]
pub(crate) mod prepare;
#[cfg(target_arch = "wasm32")]
pub(crate) mod runtime;
#[cfg(target_arch = "wasm32")]
pub(crate) mod scan;
#[cfg(target_arch = "wasm32")]
pub(crate) mod scratch;
#[cfg(target_arch = "wasm32")]
pub(crate) mod store;

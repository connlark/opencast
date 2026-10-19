//! Invocation-owned database transport for the production PostgreSQL port.
#![deny(clippy::disallowed_methods)]

#[cfg(all(target_arch = "wasm32", feature = "postgres"))]
pub mod database;
pub mod lifecycle;
#[cfg(all(target_arch = "wasm32", feature = "postgres"))]
mod socket;

#[cfg(any(all(target_arch = "wasm32", feature = "postgres"), test))]
mod ordered;
pub mod statement;
#[cfg(feature = "postgres")]
pub use tokio_postgres::{
    types::{FromSql as PostgresFromSql, Type as PostgresType},
    Row as PostgresRow,
};

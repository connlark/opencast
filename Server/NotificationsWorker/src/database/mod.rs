//! One immutable storage authority for each invocation.
mod authority;
mod cancellation;
pub mod identity;
pub use authority::Authority;
mod controls;
pub use controls::{control, permitted};
#[cfg(feature = "storage-fixture")]
pub(crate) mod fixture;
#[cfg(feature = "storage-fixture")]
mod fixture_adapter;
#[cfg(feature = "storage-fixture")]
mod fixture_authority;
#[cfg(feature = "storage-fixture")]
mod fixture_slice_b;
mod fixture_slice_c;
mod fixture_slice_d;
#[cfg(feature = "storage-fixture")]
mod fixture_witness;
pub mod observations;
pub mod polling;
mod postgres;
mod rows;
pub mod slice_b;
pub mod slice_c;
pub mod slice_d;
pub(crate) mod witness;

use opencast_worker_database_core::{
    lifecycle::{Failure, Kind, Outcome, Phase},
    statement::{CountRule, Parameter, Statement},
};
use polling::Operation;
use serde::Serialize;
use serde_json::Value;

pub type Result<T> = std::result::Result<T, Failure>;

#[derive(Serialize)]
pub struct Reply {
    pub rows: Vec<Value>,
    pub count: u64,
}
#[derive(Default, Serialize)]
pub struct Metrics {
    pub handler_ms: u64,
    pub transaction_ms: u64,
    pub gate_wait_us: Option<i64>,
    pub gate_reply_ms: Option<u64>,
}
#[derive(Serialize)]
pub struct Response {
    pub replies: Vec<Reply>,
    pub metrics: Metrics,
}

impl Response {
    pub fn rows(mut self) -> Vec<Value> {
        self.replies.remove(0).rows
    }
    pub fn first(mut self) -> Option<Value> {
        self.replies.remove(0).rows.into_iter().next()
    }
    pub fn count(&self) -> u64 {
        self.replies[0].count
    }
}

struct Descriptor {
    statements: Vec<Statement>,
}
fn text(value: impl Into<String>) -> Parameter {
    Parameter::Text(Some(value.into()))
}
fn integer(value: i64) -> Parameter {
    Parameter::Integer(Some(value))
}
fn statement(sql: impl Into<String>, parameters: Vec<Parameter>, count: CountRule) -> Descriptor {
    Descriptor {
        statements: vec![Statement {
            sql: sql.into(),
            parameters,
            count,
        }],
    }
}
fn decode_failure(read: bool) -> Failure {
    let mut error = Failure::new(Kind::Decode, Phase::Commit);
    if read {
        error.outcome = Outcome::NotApplicable;
    }
    error
}

fn validate(operation: &Operation) -> Result<()> {
    // Includes fence integers and every nullable/bulk field. Never stringify
    // this value into an error or log.
    fn numbers(value: &Value) -> bool {
        match value {
            Value::Number(n) => n
                .as_i64()
                .is_some_and(|n| Parameter::Integer(Some(n)).validate().is_ok()),
            Value::Array(values) => values.iter().all(numbers),
            Value::Object(values) => values.values().all(numbers),
            _ => true,
        }
    }
    let valid = serde_json::to_value(operation).is_ok_and(|value| numbers(&value));
    if valid {
        Ok(())
    } else {
        let mut error = Failure::new(Kind::Assertion, Phase::Transaction);
        if operation.is_read() {
            error.outcome = Outcome::NotApplicable;
        }
        Err(error)
    }
}

/// Synthetic validation failures retain their fixed storage classification.
/// Dispatch through the enclosing invocation's authority.
pub async fn execute(
    authority: &self::Authority,
    operation: Operation,
) -> worker::Result<Response> {
    let (backend, guard) = authority
        .bound_op(
            operation.id(),
            operation.is_read(),
            witness::Role::Operation,
        )
        .await?;
    match backend {
        self::authority::Backend::Postgres(env) => {
            let (cancel, deadline) = authority.context();
            let result = execute_postgres(
                env,
                &operation,
                cancel.clone(),
                deadline,
                guard.races().as_ref(),
            )
            .await;
            // Recorded before any readback and before the public string.
            guard.settle(&result);
            result.map_err(|failure| {
                worker::Error::RustError(format!(
                    "storage_{}_{:?}_{:?}",
                    operation.id(),
                    failure.kind,
                    failure.outcome
                ))
            })
        }
    }
}

/// Used by the isolated local authority; no connection or client is cached.
/// `deadline` is the enclosing operation's absolute epoch-millisecond deadline;
/// the storage segment is capped by it and never silently replaces it.
pub(super) async fn execute_postgres(
    env: &worker::Env,
    operation: &Operation,
    cancel: opencast_worker_database_core::database::Cancellation,
    deadline: u64,
    races: Option<&witness::Races>,
) -> Result<Response> {
    postgres::execute(env, operation, cancel, deadline, races).await
}
mod fixture_slice_e;
mod fixture_slice_f;
pub mod slice_e;
pub mod slice_f;

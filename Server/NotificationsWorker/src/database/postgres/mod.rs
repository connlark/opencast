//! PostgreSQL authority. Every mutation enters the gate before reading predicates.
mod dispatch;
pub(super) mod identity;
mod observations;
mod polling;
pub(super) mod slice_b;
pub(super) mod slice_c;
pub(super) mod slice_d;
use super::*;
use futures_util::{
    future::{select, Either},
    pin_mut,
};
use opencast_worker_database_core::{
    database::{delay, now, Cancellation, Database},
    PostgresRow, PostgresType,
};

// Division by COUNT is a fail-closed singleton probe. A zero-row lock cannot be
// checked after pipelining the writes: they would already have been submitted.
// clock_timestamp is evaluated after the locking subquery; report its wait
// separately from client gate-reply and complete transaction timings.
pub(super) const GATE: &str = "SELECT 1/COUNT(*) AS guard,(EXTRACT(EPOCH FROM clock_timestamp()-statement_timestamp())*1000000)::bigint AS gate_wait_us FROM (SELECT id FROM n_poll_dispatch WHERE id=1 FOR UPDATE) AS gate";

#[cfg(feature = "storage-fixture")]
pub(super) fn plan_statement(operation: &Operation) -> Result<Statement> {
    validate(operation)?;
    if !operation.is_read() {
        return Err(Failure::new(Kind::Assertion, Phase::Read));
    }
    let mut descriptor = polling::describe(operation);
    let mut statement = descriptor.statements.remove(0);
    statement.sql = format!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {}", statement.sql);
    // EXPLAIN's command tag has no affected-row number, even with one JSON row.
    statement.count = CountRule::Exactly(0);
    Ok(statement)
}

fn decode(row: PostgresRow, read: bool) -> Result<Value> {
    let mut values = serde_json::Map::new();
    for (index, column) in row.columns().iter().enumerate() {
        let failure = |_| decode_failure(read);
        let value = match *column.type_() {
            PostgresType::TEXT | PostgresType::VARCHAR => {
                serde_json::json!(row.try_get::<_, Option<String>>(index).map_err(failure)?)
            }
            PostgresType::INT8 => {
                let value = row.try_get::<_, Option<i64>>(index).map_err(failure)?;
                Parameter::Integer(value)
                    .validate()
                    .map_err(|_| decode_failure(read))?;
                serde_json::json!(value)
            }
            PostgresType::INT4 => {
                serde_json::json!(row.try_get::<_, Option<i32>>(index).map_err(failure)?)
            }
            PostgresType::INT2 => {
                serde_json::json!(row.try_get::<_, Option<i16>>(index).map_err(failure)?)
            }
            // SQLite's predicate aliases are integer flags, including in rows.
            PostgresType::BOOL => serde_json::json!(row
                .try_get::<_, Option<bool>>(index)
                .map_err(failure)?
                .map(i32::from)),
            _ => return Err(decode_failure(read)),
        };
        if values.insert(column.name().into(), value).is_some() {
            return Err(decode_failure(read));
        }
    }
    Ok(Value::Object(values))
}

/// `deadline` is the enclosing operation's absolute epoch-millisecond deadline
/// (the scan or step budget). The storage segment never outlives it: connect,
/// statement and transaction budgets are all capped, and an already-expired
/// deadline submits nothing.
pub(super) async fn execute(
    env: &worker::Env,
    operation: &Operation,
    cancel: Cancellation,
    deadline: u64,
) -> Result<Response> {
    validate(operation)?;
    let started = now();
    let descriptor = polling::describe(operation);
    // Validate before opening a socket or submitting any statement.
    for statement in &descriptor.statements {
        statement.validate()?;
    }
    let read = operation.is_read();
    let classify = |mut error: Failure| {
        if read {
            error.outcome = Outcome::NotApplicable;
        }
        error
    };
    if deadline <= started {
        return Err(classify(Failure::new(Kind::Deadline, Phase::Connect)));
    }
    // Dropping an unfinished connect closes its socket through the owned guard.
    let connect = Database::connect(env, cancel, started);
    let expiry = delay(deadline - started);
    pin_mut!(connect, expiry);
    let mut db = match select(connect, expiry).await {
        Either::Left((connected, _)) => connected.map_err(classify)?,
        Either::Right(((), _)) => {
            return Err(classify(Failure::new(Kind::Deadline, Phase::Connect)));
        }
    };
    db.cap_deadline(deadline);
    let mut metrics = Metrics::default();
    let result = if read {
        db.read_statement(&descriptor.statements[0])
            .await
            .map(|reply| vec![reply])
    } else {
        let gate = Statement {
            sql: GATE.into(),
            parameters: vec![],
            count: CountRule::Exactly(1),
        };
        db.write_transaction(&gate, &descriptor.statements)
            .await
            .and_then(|reply| {
                metrics.gate_wait_us = Some(
                    reply
                        .gate
                        .rows
                        .first()
                        .ok_or_else(|| decode_failure(false))?
                        .try_get("gate_wait_us")
                        .map_err(|_| decode_failure(false))?,
                );
                Ok(reply.statements)
            })
    };
    // Close before decoding/exposing results or allowing a caller's external I/O.
    // Cleanup cannot undo an acknowledged commit or make Unknown definite.
    let (spans, _cleanup) = db.finish().await;
    metrics.handler_ms = now().saturating_sub(started);
    metrics.transaction_ms = spans
        .iter()
        .find(|s| s.boundary == "transaction")
        .map_or(0, |s| s.elapsed_ms);
    metrics.gate_reply_ms = spans
        .iter()
        .find(|s| s.boundary == "gate")
        .map(|s| s.elapsed_ms);
    let results = result?;
    if results.len() != descriptor.statements.len() {
        return Err(decode_failure(read));
    }
    let mut replies = Vec::with_capacity(results.len());
    for (reply, statement) in results.into_iter().zip(descriptor.statements) {
        if !statement.count.accepts(reply.affected) {
            return Err(decode_failure(read));
        }
        let rows = reply
            .rows
            .into_iter()
            .map(|row| decode(row, read))
            .collect::<Result<_>>()?;
        replies.push(Reply {
            rows,
            count: reply.affected,
        });
    }
    super::rows::validate(operation, &replies)?;
    Ok(Response { replies, metrics })
}
pub(super) mod slice_e;
pub(super) mod slice_f;

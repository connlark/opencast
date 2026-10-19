//! The bind-time identity read: database name, optional system identifier and
//! the catalog digest of the 32 application tables, on its own storage
//! segment. One unnamed typed read; no gate lock, no `SET`, no write.
use super::*;
use crate::database_identity::postgres_identity_sql;

/// `deadline` is the invocation's absolute deadline; the segment is capped by
/// it and an expired deadline submits nothing. Every failure is a read failure.
pub(in crate::database) async fn read(
    env: &worker::Env,
    cancel: Cancellation,
    deadline: u64,
    system: bool,
) -> Result<Value> {
    let statement = Statement {
        sql: postgres_identity_sql(system),
        parameters: vec![],
        count: CountRule::Exactly(1),
    };
    let read_failure = |mut error: Failure| {
        error.outcome = Outcome::NotApplicable;
        error
    };
    statement.validate().map_err(read_failure)?;
    let started = now();
    if deadline <= started {
        return Err(read_failure(Failure::new(Kind::Deadline, Phase::Connect)));
    }
    let connect = Database::connect(env, cancel, started);
    let expiry = delay(deadline - started);
    pin_mut!(connect, expiry);
    let mut db = match select(connect, expiry).await {
        Either::Left((connected, _)) => connected.map_err(read_failure)?,
        Either::Right(((), _)) => {
            return Err(read_failure(Failure::new(Kind::Deadline, Phase::Connect)));
        }
    };
    db.cap_deadline(deadline);
    let result = db.read_statement(&statement).await;
    let (_spans, _cleanup) = db.finish().await;
    let row = result?
        .rows
        .into_iter()
        .next()
        .ok_or_else(|| decode_failure(true))?;
    decode(row, true)
}

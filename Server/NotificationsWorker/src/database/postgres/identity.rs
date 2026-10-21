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
    races: Option<&witness::Races>,
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
    let mut db = open(env, cancel, started, deadline, races)
        .await
        .map_err(read_failure)?;
    let result = db.read_statement(&statement).await;
    let (_spans, _cleanup) = db.finish().await;
    let row = result?
        .rows
        .into_iter()
        .next()
        .ok_or_else(|| decode_failure(true))?;
    decode(row, true)
}

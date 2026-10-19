//! Closed local adapter contracts. Absent from both shipped Worker builds.
use super::*;
use futures_util::{future::pending, FutureExt};
use opencast_worker_database_core::{
    database::{now, Database},
    statement::MAX_SAFE_INTEGER,
};
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Case {
    RoleDefaults,
    TypedValues,
    OrderedLarge,
    WireSmall,
    RollbackLater,
    CountZero,
    CountOne,
    CountMultiple,
    ExactlyOneNoop,
    NoopDependency,
    UnsafeInteger,
    ReadCountMismatch,
    ReadUnsafeInteger,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    case: Case,
}
fn sql(sql: &str, parameters: Vec<Parameter>, count: CountRule) -> Statement {
    Statement {
        sql: sql.into(),
        parameters,
        count,
    }
}
fn increment(bucket: i64) -> Statement {
    sql("INSERT INTO n_poll_stat(bucket,scan_busy) VALUES($1,1) ON CONFLICT(bucket) DO UPDATE SET scan_busy=n_poll_stat.scan_busy+1",vec![integer(bucket)],CountRule::Exactly(1))
}
async fn run(db: &mut Database, case: Case) -> Result<Value> {
    if matches!(case, Case::RoleDefaults) {
        let query = sql(
            "SELECT current_setting('statement_timeout')::text AS statement_timeout,current_setting('lock_timeout')::text AS lock_timeout,current_setting('idle_in_transaction_session_timeout')::text AS idle_timeout,current_setting('search_path')::text AS search_path",
            vec![],
            CountRule::Exactly(1),
        );
        let reply = db.read_statement(&query).await?;
        let row = reply.rows.first().ok_or_else(|| decode_failure(true))?;
        let mut defaults = serde_json::Map::new();
        for field in [
            "statement_timeout",
            "lock_timeout",
            "idle_timeout",
            "search_path",
        ] {
            let value: String = row.try_get(field).map_err(|_| decode_failure(true))?;
            defaults.insert(field.into(), json!(value));
        }
        return Ok(Value::Object(defaults));
    }
    if matches!(case, Case::ReadUnsafeInteger) {
        let query = sql(
            "SELECT $1",
            vec![integer(MAX_SAFE_INTEGER + 1)],
            CountRule::Exactly(1),
        );
        return db
            .read_statement(&query)
            .await
            .map(|reply| json!({"count":reply.affected}));
    }
    if matches!(case, Case::TypedValues) {
        let texts = vec![
            Some("first'\\value".into()),
            None,
            Some("first'\\value".into()),
            Some("last✓".into()),
        ];
        let integers = vec![
            Some(-MAX_SAFE_INTEGER),
            None,
            Some(MAX_SAFE_INTEGER),
            Some(0),
        ];
        let query=sql("SELECT $1 AS text_value,$2 AS integer_null,$3 AS bytes,$4 AS texts,$5 AS integers,$6 AS array_null,$7 AS bytes_null,$8 AS empty_texts,$9 AS empty_integers,$10 AS text_null",vec![text("typed✓'\\value"),Parameter::Integer(None),Parameter::Bytes(Some(vec![0,255,39])),Parameter::TextArray(Some(texts.clone())),Parameter::IntegerArray(Some(integers.clone())),Parameter::TextArray(None),Parameter::Bytes(None),Parameter::TextArray(Some(vec![])),Parameter::IntegerArray(Some(vec![])),Parameter::Text(None)],CountRule::Exactly(1));
        let reply = db.read_statement(&query).await?;
        let row = reply.rows.first().ok_or_else(|| decode_failure(true))?;
        let failed = |_| decode_failure(true);
        let valid = row.try_get::<_, String>("text_value").map_err(failed)? == "typed✓'\\value"
            && row
                .try_get::<_, Option<i64>>("integer_null")
                .map_err(failed)?
                .is_none()
            && row.try_get::<_, Vec<u8>>("bytes").map_err(failed)? == [0, 255, 39]
            && row
                .try_get::<_, Vec<Option<String>>>("texts")
                .map_err(failed)?
                == texts
            && row
                .try_get::<_, Vec<Option<i64>>>("integers")
                .map_err(failed)?
                == integers
            && row
                .try_get::<_, Option<Vec<String>>>("array_null")
                .map_err(failed)?
                .is_none()
            && row
                .try_get::<_, Option<Vec<u8>>>("bytes_null")
                .map_err(failed)?
                .is_none()
            && row
                .try_get::<_, Vec<String>>("empty_texts")
                .map_err(failed)?
                .is_empty()
            && row
                .try_get::<_, Vec<i64>>("empty_integers")
                .map_err(failed)?
                .is_empty()
            && row
                .try_get::<_, Option<String>>("text_null")
                .map_err(failed)?
                .is_none();
        if !valid {
            return Err(decode_failure(true));
        }
        return Ok(json!({"typed_values":true,"count":reply.affected}));
    }
    if matches!(case, Case::ReadCountMismatch) {
        let query = sql(
            "SELECT generate_series(1,2)::bigint AS n",
            vec![],
            CountRule::Exactly(1),
        );
        return db
            .read_statement(&query)
            .await
            .map(|reply| json!({"count":reply.affected}));
    }
    let statements=match case {
        Case::OrderedLarge=>(0..70).map(|i|increment(7000+i)).collect(),
        Case::WireSmall=>(0..3).map(|i|increment(7000+i)).collect(),
        Case::RollbackLater=>vec![increment(7000),sql("SELECT 1/0 AS rejected",vec![],CountRule::Exactly(1)),increment(7001)],
        Case::CountZero=>vec![sql("UPDATE n_poll_stat SET scan_busy=scan_busy+1 WHERE bucket=-1",vec![],CountRule::AtMost(1))],
        Case::CountOne=>vec![sql("UPDATE n_poll_stat SET scan_busy=scan_busy+1 WHERE bucket=7000",vec![],CountRule::Exactly(1))],
        Case::CountMultiple=>vec![sql("UPDATE n_poll_stat SET scan_busy=scan_busy+1 WHERE bucket IN(7000,7001)",vec![],CountRule::AtMost(1))],
        Case::ExactlyOneNoop=>vec![sql("UPDATE n_poll_stat SET scan_busy=scan_busy+1 WHERE bucket=-1",vec![],CountRule::Exactly(1))],
        Case::NoopDependency=>vec![
            sql("UPDATE n_poll_stat SET stale_commits=1 WHERE bucket=7000 AND scan_busy=-1",vec![],CountRule::AtMost(1)),
            sql("UPDATE n_poll_stat SET scan_busy=scan_busy+1 WHERE bucket=7001 AND EXISTS(SELECT 1 FROM n_poll_stat WHERE bucket=7000 AND stale_commits=1)",vec![],CountRule::AtMost(1)),
        ],
        Case::UnsafeInteger=>vec![increment(MAX_SAFE_INTEGER+1)],
        Case::RoleDefaults|Case::TypedValues|Case::ReadCountMismatch|Case::ReadUnsafeInteger=>unreachable!("read cases returned"),
    };
    let gate = sql(super::postgres::GATE, vec![], CountRule::Exactly(1));
    let reply = db.write_transaction(&gate, &statements).await?;
    Ok(
        json!({"counts":reply.statements.iter().map(|r|r.affected).collect::<Vec<_>>(),"transaction_open":db.is_in_transaction()}),
    )
}
pub(super) async fn handle(
    mut request: worker::Request,
    env: worker::Env,
) -> worker::Result<worker::Response> {
    if request.method() != worker::Method::Post
        || env.var("STORAGE_AUTHORITY")?.to_string() != "postgres"
    {
        return worker::Response::error("adapter_fixture_unavailable", 404);
    }
    let request: Request = match request.json().await {
        Ok(request) => request,
        Err(_) => return worker::Response::error("invalid_adapter_case", 400),
    };
    let mut db = match Database::connect(&env, pending().boxed_local().shared(), now()).await {
        Ok(db) => db,
        Err(error) => return worker::Response::from_json(&json!({"ok":false,"error":error})),
    };
    let result = run(&mut db, request.case).await;
    let (spans, cleanup) = db.finish().await;
    worker::Response::from_json(&match result {
        Ok(value) => json!({"ok":true,"value":value,"spans":spans,"cleanup":cleanup}),
        Err(error) => {
            json!({"ok":false,"retryable":error.retryable(),"error":error,"spans":spans,"cleanup":cleanup})
        }
    })
}

struct Plan(Value);
impl<'a> opencast_worker_database_core::PostgresFromSql<'a> for Plan {
    fn from_sql(
        _: &opencast_worker_database_core::PostgresType,
        raw: &'a [u8],
    ) -> std::result::Result<Self, Box<dyn std::error::Error + Sync + Send>> {
        Ok(Self(serde_json::from_slice(raw)?))
    }
    fn accepts(ty: &opencast_worker_database_core::PostgresType) -> bool {
        *ty == opencast_worker_database_core::PostgresType::JSON
    }
}
// Plan expression/output fields contain SQL and bound values. Retain only
// structural nodes and measured costs/counts; no raw plan is emitted or logged.
fn plan_metadata(value: Value) -> Value {
    const FIELDS: &[&str] = &[
        "Plan",
        "Plans",
        "Node Type",
        "Parent Relationship",
        "Relation Name",
        "Alias",
        "Index Name",
        "Scan Direction",
        "Join Type",
        "Strategy",
        "Operation",
        "Subplan Name",
        "Startup Cost",
        "Total Cost",
        "Plan Rows",
        "Plan Width",
        "Actual Startup Time",
        "Actual Total Time",
        "Actual Rows",
        "Actual Loops",
        "Rows Removed by Filter",
        "Rows Removed by Join Filter",
        "Shared Hit Blocks",
        "Shared Read Blocks",
        "Shared Dirtied Blocks",
        "Shared Written Blocks",
        "Temp Read Blocks",
        "Temp Written Blocks",
        "Planning Time",
        "Execution Time",
    ];
    match value {
        Value::Array(values) => Value::Array(values.into_iter().map(plan_metadata).collect()),
        Value::Object(values) => Value::Object(
            values
                .into_iter()
                .filter(|(key, _)| FIELDS.contains(&key.as_str()))
                .map(|(key, value)| (key, plan_metadata(value)))
                .collect(),
        ),
        value => value,
    }
}
pub(super) async fn plan(
    mut request: worker::Request,
    env: worker::Env,
) -> worker::Result<worker::Response> {
    if request.method() != worker::Method::Post
        || env.var("STORAGE_AUTHORITY")?.to_string() != "postgres"
    {
        return worker::Response::error("plan_fixture_unavailable", 404);
    }
    let operation: Operation = match request.json().await {
        Ok(operation) => operation,
        Err(_) => return worker::Response::error("invalid_plan_case", 400),
    };
    let result = async {
        let statement = super::postgres::plan_statement(&operation)?;
        let mut db = Database::connect(&env, pending().boxed_local().shared(), now()).await?;
        let reply = db.read_statement(&statement).await;
        let (_, _cleanup) = db.finish().await;
        let reply = reply?;
        if reply.rows.len() != 1 {
            return Err(decode_failure(true));
        }
        let plan: Plan = reply
            .rows
            .first()
            .ok_or_else(|| decode_failure(true))?
            .try_get(0)
            .map_err(|_| decode_failure(true))?;
        Ok::<_, Failure>(plan_metadata(plan.0))
    }
    .await;
    worker::Response::from_json(&match result {
        Ok(plan) => json!({"ok":true,"plan":plan}),
        Err(error) => json!({"ok":false,"error":error}),
    })
}

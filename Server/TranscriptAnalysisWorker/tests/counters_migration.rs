//! Pins migration 0003's `counters` schema against the upsert the worker
//! issues, so a schema edit cannot silently break the best-effort bumps.

#![cfg(not(target_arch = "wasm32"))]

use opencast_transcript_analysis_worker::counters::upsert_sql;
use rusqlite::{params, Connection};

fn setup_db() -> Connection {
    let db = Connection::open_in_memory().expect("open in-memory sqlite");
    db.execute_batch(include_str!("../migrations/0003_counters.sql"))
        .expect("create counters table");
    db
}

#[test]
fn multi_row_upsert_creates_then_accumulates() {
    let db = setup_db();
    db.execute(
        &upsert_sql(2),
        params![
            "jobs_started",
            1,
            1_780_000_000_i64,
            "prompt_tokens",
            120,
            1_780_000_000_i64
        ],
    )
    .expect("first upsert");
    db.execute(
        &upsert_sql(2),
        params![
            "jobs_started",
            1,
            1_780_000_060_i64,
            "prompt_tokens",
            95_255,
            1_780_000_060_i64
        ],
    )
    .expect("second upsert");

    let rows: Vec<(String, i64, i64)> = db
        .prepare("SELECT name, value, updated_at FROM counters ORDER BY name")
        .expect("prepare")
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .expect("query")
        .collect::<Result<_, _>>()
        .expect("rows");
    assert_eq!(
        rows,
        vec![
            ("jobs_started".to_string(), 2, 1_780_000_060),
            ("prompt_tokens".to_string(), 95_375, 1_780_000_060),
        ]
    );
}

#[test]
fn migration_is_idempotent() {
    let db = setup_db();
    db.execute_batch(include_str!("../migrations/0003_counters.sql"))
        .expect("re-applying the migration is a no-op");
}

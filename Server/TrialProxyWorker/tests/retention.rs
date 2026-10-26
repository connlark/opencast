//! Nothing from a request is kept: the object's schema is pinned column by
//! column, the D1 mirror's columns are pinned to its migration, and a full
//! dump after an admitted and settled window carries no byte of the
//! request's text, run id or install id.

mod support;

use std::collections::BTreeMap;

use opencast_trial_proxy_worker::admission::{admit_request, app_attest_subject};
use opencast_trial_proxy_worker::bundle::embedded;
use opencast_trial_proxy_worker::identifiers;
use opencast_trial_proxy_worker::ledger::{self, Lane, LedgerStore, MirrorKey};
use opencast_trial_proxy_worker::ledger_sql::{
    mirror_statement, SqlBackend, SqlStore, SqlValue, MIRROR_DAY_SQL, MIRROR_INSTALL_SQL,
    MIRROR_MONTH_SQL, MIRROR_PRUNE_RUNS_SQL, MIRROR_RUN_SQL, RETIRED_COLUMNS, STORED_COLUMNS,
};
use opencast_trial_proxy_worker::provider::classify_reply;
use opencast_trial_proxy_worker::request::parse_window;
use rusqlite::Connection;
use serde_json::json;
use support::{at, config, Harness, Sql};

const CANARY_TEXT: &str = "CANARY-TRANSCRIPT-7f3a9c";
const CANARY_RUN: &str = "CANARY-RUN-51e0";
const CANARY_INSTALL: &str = "CANARY-INSTALL-0b9d";

/// Column-name words that would mean content had a home.
const CONTENT_WORDS: &[&str] = &[
    "text",
    "body",
    "prompt",
    "content",
    "contents",
    "request",
    "payload",
    "message",
    "answer",
    "transcript",
    "title",
    "detail",
    "error",
    "api",
    "secret",
    "raw",
];

fn names_content(column: &str) -> bool {
    column.split('_').any(|word| CONTENT_WORDS.contains(&word))
}

fn columns(db: &Connection, table: &str) -> Vec<String> {
    let mut statement = db
        .prepare(&format!(
            "SELECT name FROM pragma_table_info('{table}') ORDER BY cid"
        ))
        .unwrap();
    statement
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

#[test]
fn the_object_stores_exactly_the_pinned_columns() {
    let sql = Sql::new();
    let db = &sql.0.backend().connection;
    let mut tables: Vec<String> = db
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    tables.sort();
    let mut pinned: Vec<String> = STORED_COLUMNS
        .iter()
        .map(|(table, _)| table.to_string())
        .collect();
    pinned.sort();
    assert_eq!(tables, pinned);
    for (table, expected) in STORED_COLUMNS {
        assert_eq!(columns(db, table), *expected, "{table}");
        for column in *expected {
            assert!(!names_content(column), "{table}.{column} names content");
        }
    }
}

#[test]
fn an_earlier_object_schema_drops_its_retired_columns_and_keeps_its_rows() {
    let store = SqlStore::new(support::Lite::new());
    let db = &store.backend().connection;
    // The reservations table as the first deployed version created it.
    db.execute_batch(
        "CREATE TABLE reservations (
            id TEXT PRIMARY KEY, subject TEXT NOT NULL, lane TEXT NOT NULL, run_id TEXT NOT NULL,
            window_index INTEGER NOT NULL, feature TEXT NOT NULL, model TEXT NOT NULL, mode TEXT NOT NULL,
            month TEXT NOT NULL, spill_month TEXT, day INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
            input_estimated INTEGER NOT NULL, max_output_tokens INTEGER NOT NULL,
            input_price INTEGER NOT NULL, output_price INTEGER NOT NULL,
            reserved_micros INTEGER NOT NULL, charged_micros INTEGER NOT NULL, state TEXT NOT NULL,
            outcome TEXT, created_at INTEGER NOT NULL, deadline INTEGER NOT NULL, finalized_at INTEGER);
         INSERT INTO reservations VALUES ('old', 'bearer:x', 'bearer', 'r', 0, 'ad_detection',
            'gemini-3.8-flash', 'open', '2026-10', NULL, 20385, 2039, 0, 16384, 750000, 3750000,
            63000, 32013, 'settled', 'usage', 1, 2, 3);",
    )
    .unwrap();
    store.create_schema().unwrap();
    // Twice: a restart finds nothing left to drop.
    store.create_schema().unwrap();
    let reservations = STORED_COLUMNS
        .iter()
        .find(|(table, _)| *table == "reservations")
        .unwrap()
        .1;
    assert_eq!(columns(db, "reservations"), reservations);
    for (table, column) in RETIRED_COLUMNS {
        assert!(!columns(db, table).iter().any(|name| name == column));
    }
    let kept = store.reservation("old").unwrap().expect("the row survives");
    assert_eq!((kept.input_tokens, kept.charged_micros), (2_039, 32_013));
}

#[test]
fn the_app_attest_tables_hold_only_checked_identifiers_and_hashes() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(include_str!("../migrations/0001_app_attest_auth.sql"))
        .unwrap();
    // Each text column and what fills it: an identifier whose shape the
    // routes check before any write, a hash, a constant or configuration.
    let expected: BTreeMap<&str, &[&str]> = BTreeMap::from([
        (
            "app_attest_challenges",
            &[
                "challenge_id",   // issued here (random)
                "challenge_hash", // SHA-256
                "purpose",        // "register" only
                "install_id",     // checked UUID
                "created_at",
                "expires_at",
                "consumed_at",
            ][..],
        ),
        (
            "app_attest_challenge_source_buckets",
            &[
                "source_token",
                "window_start",
                "request_count",
                "updated_at",
            ][..], // keyed hash
        ),
        (
            "app_attest_keys",
            &[
                "install_id", // checked UUID
                "key_id",     // canonical base64 of 32 bytes
                "public_key", // from the verified attestation
                "sign_counter",
                "app_id",      // configuration
                "environment", // configuration
                "created_at",
                "last_used_at",
            ][..],
        ),
    ]);
    for (table, columns_expected) in &expected {
        assert_eq!(columns(&db, table), *columns_expected, "{table}");
    }
    // Only these columns can hold text at all; the rest are integers and the
    // attested public key.
    let text_columns: Vec<String> = expected
        .keys()
        .flat_map(|table| {
            let mut statement = db
                .prepare(&format!(
                    "SELECT name FROM pragma_table_info('{table}') WHERE type = 'TEXT' ORDER BY cid"
                ))
                .unwrap();
            statement
                .query_map([], |row| row.get::<_, String>(0))
                .unwrap()
                .map(|name| format!("{table}.{}", name.unwrap()))
                .collect::<Vec<_>>()
        })
        .collect();
    assert_eq!(
        text_columns,
        [
            "app_attest_challenge_source_buckets.source_token",
            "app_attest_challenges.challenge_id",
            "app_attest_challenges.challenge_hash",
            "app_attest_challenges.purpose",
            "app_attest_challenges.install_id",
            "app_attest_keys.install_id",
            "app_attest_keys.key_id",
            "app_attest_keys.app_id",
            "app_attest_keys.environment",
        ]
    );
    // The request-fed identifiers refuse anything but their shape.
    let transcript = format!("{CANARY_TEXT} {}", "words ".repeat(200));
    for value in [CANARY_TEXT, CANARY_INSTALL, transcript.as_str(), ""] {
        assert!(!identifiers::is_install_id(value));
        assert_eq!(identifiers::key_id(value), None);
        assert!(!identifiers::is_challenge_id(value));
        assert!(!identifiers::is_challenge(value));
    }
}

#[test]
fn the_mirror_matches_its_migration_and_holds_no_content_columns() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(include_str!("../migrations/0001_app_attest_auth.sql"))
        .unwrap();
    db.execute_batch(include_str!("../migrations/0002_trial_ledger_mirror.sql"))
        .unwrap();
    let expected: BTreeMap<&str, &[&str]> = BTreeMap::from([
        (
            "trial_install",
            &[
                "subject",
                "trial_units_used",
                "open_runs",
                "version",
                "updated_at",
            ][..],
        ),
        (
            "trial_run",
            &[
                "subject",
                "run_id",
                "feature",
                "windows",
                "reservations",
                "reserved_input_tokens",
                "charged_micros",
                "unit_consumed",
                "created_at",
                "version",
                "updated_at",
            ][..],
        ),
        (
            "trial_month",
            &[
                "month",
                "charged_micros",
                "overrun_micros",
                "reservations",
                "paused_at",
                "version",
                "updated_at",
            ][..],
        ),
        (
            "trial_day",
            &[
                "day",
                "admitted",
                "input_tokens",
                "would_refuse_runs",
                "forwards",
                "provider_failures",
                "expired",
                "overruns",
                "overrun_micros",
                "version",
                "updated_at",
            ][..],
        ),
    ]);
    for (table, columns_expected) in &expected {
        assert_eq!(columns(&db, table), *columns_expected, "{table}");
    }
    // Every mirror statement runs against the migrated schema, and a stale
    // version never overwrites a newer row.
    let args = |values: &[rusqlite::types::Value]| values.to_vec();
    use rusqlite::types::Value::{Integer as I, Text as T};
    db.execute(
        MIRROR_INSTALL_SQL,
        rusqlite::params_from_iter(args(&[T("s".into()), I(1), I(0), I(5), I(10)])),
    )
    .unwrap();
    db.execute(
        MIRROR_INSTALL_SQL,
        rusqlite::params_from_iter(args(&[T("s".into()), I(0), I(0), I(4), I(11)])),
    )
    .unwrap();
    let used: i64 = db
        .query_row("SELECT trial_units_used FROM trial_install", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(used, 1, "an older version never moves a mirror row back");
    db.execute(
        MIRROR_RUN_SQL,
        rusqlite::params_from_iter(args(&[
            T("s".into()),
            T("r".into()),
            T("ad_detection".into()),
            I(1),
            I(1),
            I(10),
            I(5),
            I(1),
            I(1),
            I(1),
            I(1),
        ])),
    )
    .unwrap();
    db.execute(
        MIRROR_MONTH_SQL,
        rusqlite::params_from_iter(args(&[
            T("2027-01".into()),
            I(1),
            I(0),
            I(1),
            rusqlite::types::Value::Null,
            I(1),
            I(1),
        ])),
    )
    .unwrap();
    db.execute(
        MIRROR_DAY_SQL,
        rusqlite::params_from_iter(args(&[
            I(20_833),
            I(1),
            I(1),
            I(0),
            I(1),
            I(0),
            I(0),
            I(0),
            I(0),
            I(1),
            I(1),
        ])),
    )
    .unwrap();
    db.execute(MIRROR_PRUNE_RUNS_SQL, [i64::MAX]).unwrap();
    let kept: i64 = db
        .query_row("SELECT COUNT(*) FROM trial_run", [], |r| r.get(0))
        .unwrap();
    assert_eq!(kept, 1, "a run that consumed a unit stays in the archive");
    for table in expected.keys() {
        for column in columns(&db, table) {
            assert!(!names_content(&column), "{table}.{column}");
        }
    }
}

#[test]
fn a_dump_after_a_forward_carries_nothing_from_the_request() {
    let bundle = embedded().unwrap();
    let config = config();
    let body = json!({
        "feature": "ad_detection",
        "run_id": CANARY_RUN,
        "window_index": 3,
        "request": {
            "contents": [{"role": "user", "parts": [{"text": format!("{{\"segments\":[{{\"id\":1,\"text\":\"{CANARY_TEXT}\"}}]}}")}]}],
            "systemInstruction": {"parts": [{"text": format!("system {CANARY_TEXT}")}]},
            "generationConfig": {"maxOutputTokens": 1, "responseMimeType": CANARY_TEXT}
        }
    });
    let window = parse_window(&serde_json::to_vec(&body).unwrap(), bundle, 1_572_864).unwrap();
    let subject = app_attest_subject(CANARY_INSTALL);
    let now = at("2027-01-15T12:00:00Z");
    let request = admit_request(
        "reservation-1".into(),
        &subject,
        Lane::AppAttest,
        &window,
        bundle,
        2_041,
        117_000,
    );
    let mut sql = Sql::new();
    sql.op(|store| ledger::admit(store, &config, now, &request))
        .unwrap();
    // The provider's reply text never reaches the ledger either: only the
    // numbers the classifier read.
    let reply = format!(
        r#"{{"candidates":[{{"content":{{"parts":[{{"text":"{CANARY_TEXT}"}}]}}}}],"usageMetadata":{{"promptTokenCount":2041,"candidatesTokenCount":300,"thoughtsTokenCount":900,"totalTokenCount":3241}}}}"#
    );
    let outcome = classify_reply(200, reply.as_bytes());
    sql.op(|store| ledger::settle(store, now + 5_000, "reservation-1", &outcome))
        .unwrap();
    sql.op(|store| ledger::take_day_summaries(store, now + 2 * 86_400_000))
        .unwrap();

    let dump = sql.dump().join("\n");
    assert!(dump.contains("ad_detection"), "the dump is not empty");
    for canary in [CANARY_TEXT, CANARY_RUN, CANARY_INSTALL] {
        assert!(!dump.contains(canary), "{canary} reached object storage");
    }
    // The mirror rows built from the same store are clean too.
    let dirty = sql.store().dirty(100).unwrap();
    assert!(dirty
        .iter()
        .any(|(key, _)| matches!(key, MirrorKey::Run(..))));
    for (key, _) in dirty {
        if let Some(statement) = mirror_statement(sql.store(), &key).unwrap() {
            for arg in statement.args {
                if let SqlValue::Text(text) = arg {
                    for canary in [CANARY_TEXT, CANARY_RUN, CANARY_INSTALL] {
                        assert!(!text.contains(canary), "{canary} reached the mirror");
                    }
                }
            }
        }
    }
    // The run id is kept only as its hash.
    let hashed = sql.0.backend().run("SELECT run_id FROM runs", &[]).unwrap();
    match &hashed[0][0] {
        SqlValue::Text(run) => assert_eq!(run.len(), 64),
        other => panic!("{other:?}"),
    }
}

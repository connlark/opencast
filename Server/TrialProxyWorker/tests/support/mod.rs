//! Shared test harness: the ledger over the in-memory store and over the
//! production SQL statements on SQLite, each operation in a transaction that
//! rolls back on error (the Durable Object's `transactionSync`).

#![allow(dead_code)]

use std::cell::Cell;

use opencast_trial_proxy_worker::bundle::Feature;
use opencast_trial_proxy_worker::clock::parse_utc_timestamp_ms;
use opencast_trial_proxy_worker::config::{price_table, LedgerConfig};
use opencast_trial_proxy_worker::ledger::{
    AdmitRequest, Lane, LedgerStore, MemoryStore, StoreError, StoreResult,
};
use opencast_trial_proxy_worker::ledger_sql::{SqlBackend, SqlStore, SqlValue, STORED_COLUMNS};
use rusqlite::types::{Value, ValueRef};

pub const MODEL: &str = "gemini-3.8-flash";
pub const SEED_PRICES: &str = r#"[{"model":"gemini-3.8-flash","effective_from":"2026-01-01T00:00:00Z","input_usd_per_million":0.75,"output_usd_per_million":3.75,"max_input_tokens":1048576},{"model":"gemini-3.8-flash","effective_from":"2027-01-01T00:00:00Z","input_usd_per_million":1.5,"output_usd_per_million":7.5,"max_input_tokens":1048576}]"#;

pub fn at(timestamp: &str) -> i64 {
    parse_utc_timestamp_ms(timestamp).expect("test timestamp")
}

pub fn flip() -> i64 {
    at("2027-01-01T00:00:00Z")
}

pub fn config() -> LedgerConfig {
    LedgerConfig {
        mode_starts_at_ms: flip(),
        lifetime_units: 5,
        ceiling_micros: 50_000_000,
        run_max_windows: 12,
        run_max_input_tokens: 400_000,
        open_daily_requests: 300,
        open_daily_input_tokens: 8_000_000,
        bearer_daily_requests: 40,
        bearer_daily_input_tokens: 2_000_000,
        prices: price_table(SEED_PRICES).expect("seed prices"),
    }
}

pub struct Req {
    pub id: String,
    pub subject: String,
    pub lane: Lane,
    pub run: String,
    pub window: u16,
    pub feature: Feature,
    pub input: u64,
    pub max_output: u32,
    pub budget_ms: u64,
}

impl Req {
    pub fn new(id: &str, subject: &str, run: &str, window: u16) -> Self {
        Self {
            id: id.to_string(),
            subject: subject.to_string(),
            lane: Lane::AppAttest,
            run: run.to_string(),
            window,
            feature: Feature::AdDetection,
            input: 10_000,
            max_output: 16_384,
            budget_ms: 117_000,
        }
    }

    pub fn bearer(mut self) -> Self {
        self.lane = Lane::Bearer;
        self
    }

    pub fn input(mut self, input: u64) -> Self {
        self.input = input;
        self
    }

    pub fn feature(mut self, feature: Feature) -> Self {
        self.feature = feature;
        self
    }

    pub fn max_output(mut self, max_output: u32) -> Self {
        self.max_output = max_output;
        self
    }

    pub fn budget_ms(mut self, budget_ms: u64) -> Self {
        self.budget_ms = budget_ms;
        self
    }

    pub fn build(&self) -> AdmitRequest {
        AdmitRequest {
            reservation_id: self.id.clone(),
            subject: self.subject.clone(),
            lane: self.lane,
            run_id: self.run.clone(),
            window_index: self.window,
            feature: self.feature,
            model: MODEL.to_string(),
            input_tokens: self.input,
            max_output_tokens: self.max_output,
            forward_budget_ms: self.budget_ms,
        }
    }
}

/// SQLite through the production statements. `fail_at` makes the n-th
/// statement (counting from 0 since the last reset) fail.
pub struct Lite {
    pub connection: rusqlite::Connection,
    pub executed: Cell<usize>,
    pub fail_at: Cell<Option<usize>>,
}

impl Lite {
    pub fn new() -> Self {
        Self {
            connection: rusqlite::Connection::open_in_memory().expect("sqlite"),
            executed: Cell::new(0),
            fail_at: Cell::new(None),
        }
    }
}

impl SqlBackend for Lite {
    fn run(&self, sql: &str, args: &[SqlValue]) -> StoreResult<Vec<Vec<SqlValue>>> {
        let index = self.executed.get();
        self.executed.set(index + 1);
        if self.fail_at.get() == Some(index) {
            return Err(StoreError::Storage);
        }
        let mut statement = self
            .connection
            .prepare(sql)
            .map_err(|_| StoreError::Storage)?;
        let params: Vec<Value> = args
            .iter()
            .map(|value| match value {
                SqlValue::Null => Value::Null,
                SqlValue::Int(value) => Value::Integer(*value),
                SqlValue::Text(value) => Value::Text(value.clone()),
            })
            .collect();
        let columns = statement.column_count();
        let mut rows = statement
            .query(rusqlite::params_from_iter(params))
            .map_err(|_| StoreError::Storage)?;
        let mut out = Vec::new();
        while let Some(row) = rows.next().map_err(|_| StoreError::Storage)? {
            let mut values = Vec::with_capacity(columns);
            for column in 0..columns {
                values.push(
                    match row.get_ref(column).map_err(|_| StoreError::Storage)? {
                        ValueRef::Null => SqlValue::Null,
                        ValueRef::Integer(value) => SqlValue::Int(value),
                        ValueRef::Text(value) => {
                            SqlValue::Text(String::from_utf8(value.to_vec()).expect("utf-8"))
                        }
                        _ => return Err(StoreError::Corrupt),
                    },
                );
            }
            out.push(values);
        }
        Ok(out)
    }
}

/// One store under test, with transactional operations and a dump.
pub trait Harness {
    type Store: LedgerStore;
    fn store(&mut self) -> &mut Self::Store;
    fn op<T>(&mut self, f: impl FnOnce(&mut Self::Store) -> StoreResult<T>) -> StoreResult<T>;
    /// Every stored row, in a stable order.
    fn dump(&self) -> Vec<String>;
    /// (month, charged recorded on the month, sum of its reservations' charges).
    fn month_sums(&self) -> Vec<(String, u64, u64)>;
}

pub struct Mem(pub MemoryStore);

impl Harness for Mem {
    type Store = MemoryStore;

    fn store(&mut self) -> &mut MemoryStore {
        &mut self.0
    }

    fn op<T>(&mut self, f: impl FnOnce(&mut MemoryStore) -> StoreResult<T>) -> StoreResult<T> {
        let before = self.0.clone();
        let result = f(&mut self.0);
        if result.is_err() {
            self.0 = before;
        }
        result
    }

    fn dump(&self) -> Vec<String> {
        vec![format!("{:?}", self.0)]
    }

    fn month_sums(&self) -> Vec<(String, u64, u64)> {
        self.0
            .months
            .values()
            .map(|month| {
                let sum = self
                    .0
                    .reservations
                    .values()
                    .filter(|r| {
                        r.month == month.month || r.spill_month.as_deref() == Some(&month.month)
                    })
                    .map(|r| r.charged_micros)
                    .sum();
                (month.month.clone(), month.charged_micros, sum)
            })
            .collect()
    }
}

pub struct Sql(pub SqlStore<Lite>);

impl Sql {
    pub fn new() -> Self {
        let store = SqlStore::new(Lite::new());
        store.create_schema().expect("schema");
        Self(store)
    }

    pub fn query(&self, sql: &str) -> Vec<Vec<SqlValue>> {
        self.0.backend().run(sql, &[]).expect("query")
    }
}

impl Harness for Sql {
    type Store = SqlStore<Lite>;

    fn store(&mut self) -> &mut SqlStore<Lite> {
        &mut self.0
    }

    fn op<T>(&mut self, f: impl FnOnce(&mut SqlStore<Lite>) -> StoreResult<T>) -> StoreResult<T> {
        let connection = &self.0.backend().connection;
        connection.execute_batch("SAVEPOINT op").expect("savepoint");
        let result = f(&mut self.0);
        let connection = &self.0.backend().connection;
        if result.is_err() {
            connection
                .execute_batch("ROLLBACK TO op; RELEASE op")
                .expect("rollback");
        } else {
            connection.execute_batch("RELEASE op").expect("release");
        }
        result
    }

    fn dump(&self) -> Vec<String> {
        let mut rows = Vec::new();
        for (table, _) in STORED_COLUMNS {
            for row in self.query(&format!("SELECT * FROM {table} ORDER BY 1, 2")) {
                rows.push(format!("{table}: {row:?}"));
            }
        }
        rows
    }

    fn month_sums(&self) -> Vec<(String, u64, u64)> {
        self.query(
            "SELECT m.month, m.charged_micros, COALESCE((SELECT SUM(r.charged_micros) FROM reservations r \
             WHERE r.month = m.month OR r.spill_month = m.month), 0) FROM months m ORDER BY m.month",
        )
        .into_iter()
        .map(|row| match (&row[0], &row[1], &row[2]) {
            (SqlValue::Text(month), SqlValue::Int(charged), SqlValue::Int(sum)) => {
                (month.clone(), *charged as u64, *sum as u64)
            }
            other => panic!("unexpected row {other:?}"),
        })
        .collect()
    }
}

/// A deterministic xorshift generator for property runs.
pub struct Rng(pub u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    pub fn below(&mut self, bound: u64) -> u64 {
        self.next() % bound
    }
}

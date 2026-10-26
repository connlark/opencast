//! The ledger over SQL: the Durable Object's SQLite storage in production,
//! rusqlite in host tests, through one small `SqlBackend` trait so the same
//! statements run in both. Also the D1 mirror upserts.
//!
//! Every column is an integer, a closed enum, a subject hash, a validated
//! run id, a model id or a month/day key (`STORED_COLUMNS` pins the set).

use std::collections::BTreeSet;

use crate::bundle::Feature;
use crate::config::Mode;
use crate::ledger::{
    AlertKind, AlertRecord, BearerDay, Day, Install, Lane, LedgerStore, MirrorKey, Month,
    ProviderHour, PruneCutoffs, Reservation, ReservationState, Run, StoreError, StoreResult,
};

#[derive(Debug, Clone, PartialEq)]
pub enum SqlValue {
    Null,
    Int(i64),
    Text(String),
}

/// Runs one statement with positional `?` arguments and returns its rows.
pub trait SqlBackend {
    fn run(&self, sql: &str, args: &[SqlValue]) -> StoreResult<Vec<Vec<SqlValue>>>;
}

pub const SCHEMA: &[&str] = &[
    "CREATE TABLE IF NOT EXISTS reservations (
        id TEXT PRIMARY KEY, subject TEXT NOT NULL, lane TEXT NOT NULL, run_id TEXT NOT NULL,
        window_index INTEGER NOT NULL, feature TEXT NOT NULL, model TEXT NOT NULL, mode TEXT NOT NULL,
        month TEXT NOT NULL, spill_month TEXT, day INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
        max_output_tokens INTEGER NOT NULL,
        input_price INTEGER NOT NULL, output_price INTEGER NOT NULL,
        reserved_micros INTEGER NOT NULL, charged_micros INTEGER NOT NULL, state TEXT NOT NULL,
        outcome TEXT, created_at INTEGER NOT NULL, deadline INTEGER NOT NULL, finalized_at INTEGER,
        input_bound_tokens INTEGER NOT NULL DEFAULT 0)",
    "CREATE INDEX IF NOT EXISTS reservations_open_subject ON reservations (subject) WHERE state = 'open'",
    "CREATE INDEX IF NOT EXISTS reservations_open_deadline ON reservations (deadline) WHERE state = 'open'",
    "CREATE INDEX IF NOT EXISTS reservations_finalized ON reservations (finalized_at)",
    "CREATE TABLE IF NOT EXISTS installs (
        subject TEXT PRIMARY KEY, trial_units_used INTEGER NOT NULL, open_runs INTEGER NOT NULL,
        version INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS runs (
        subject TEXT NOT NULL, run_id TEXT NOT NULL, feature TEXT NOT NULL, windows TEXT NOT NULL,
        reservations INTEGER NOT NULL, reserved_input_tokens INTEGER NOT NULL,
        charged_micros INTEGER NOT NULL, unit_consumed INTEGER NOT NULL, created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, version INTEGER NOT NULL, PRIMARY KEY (subject, run_id))",
    "CREATE INDEX IF NOT EXISTS runs_updated ON runs (updated_at)",
    "CREATE TABLE IF NOT EXISTS months (
        month TEXT PRIMARY KEY, charged_micros INTEGER NOT NULL, overrun_micros INTEGER NOT NULL,
        reservations INTEGER NOT NULL, paused_at INTEGER, version INTEGER NOT NULL,
        updated_at INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS days (
        day INTEGER PRIMARY KEY, admitted INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
        would_refuse_runs INTEGER NOT NULL, forwards INTEGER NOT NULL,
        provider_failures INTEGER NOT NULL, expired INTEGER NOT NULL, overruns INTEGER NOT NULL,
        overrun_micros INTEGER NOT NULL, summary_logged INTEGER NOT NULL,
        version INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS bearer_days (
        day INTEGER NOT NULL, subject TEXT NOT NULL, requests INTEGER NOT NULL,
        input_tokens INTEGER NOT NULL, PRIMARY KEY (day, subject))",
    "CREATE TABLE IF NOT EXISTS provider_hours (
        hour INTEGER PRIMARY KEY, forwards INTEGER NOT NULL, failures INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS alerts (
        kind TEXT NOT NULL, period TEXT NOT NULL, sent INTEGER NOT NULL, attempts INTEGER NOT NULL,
        value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, created_at INTEGER NOT NULL,
        PRIMARY KEY (kind, period))",
    "CREATE TABLE IF NOT EXISTS mirror_dirty (
        tbl TEXT NOT NULL, key_a TEXT NOT NULL, key_b TEXT NOT NULL, version INTEGER NOT NULL,
        PRIMARY KEY (tbl, key_a, key_b))",
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)",
];

/// Columns an earlier version stored and this one does not: dropped from an
/// object's existing tables when it starts (the reservation used to record
/// whether its input was estimated; a window is now never admitted on an
/// estimate).
pub const RETIRED_COLUMNS: &[(&str, &str)] = &[("reservations", "input_estimated")];

/// Columns this version added to an existing table, with their definition:
/// added to an object's tables when it starts. The default keeps an earlier
/// version's inserts working after a rollback.
pub const ADDED_COLUMNS: &[(&str, &str, &str)] = &[(
    "reservations",
    "input_bound_tokens",
    "INTEGER NOT NULL DEFAULT 0",
)];

/// Every (table, column) the object stores. A schema test compares this with
/// the live schema, so a new column is a reviewed change.
pub const STORED_COLUMNS: &[(&str, &[&str])] = &[
    (
        "reservations",
        &[
            "id",
            "subject",
            "lane",
            "run_id",
            "window_index",
            "feature",
            "model",
            "mode",
            "month",
            "spill_month",
            "day",
            "input_tokens",
            "max_output_tokens",
            "input_price",
            "output_price",
            "reserved_micros",
            "charged_micros",
            "state",
            "outcome",
            "created_at",
            "deadline",
            "finalized_at",
            "input_bound_tokens",
        ],
    ),
    (
        "installs",
        &[
            "subject",
            "trial_units_used",
            "open_runs",
            "version",
            "updated_at",
        ],
    ),
    (
        "runs",
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
            "updated_at",
            "version",
        ],
    ),
    (
        "months",
        &[
            "month",
            "charged_micros",
            "overrun_micros",
            "reservations",
            "paused_at",
            "version",
            "updated_at",
        ],
    ),
    (
        "days",
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
            "summary_logged",
            "version",
            "updated_at",
        ],
    ),
    (
        "bearer_days",
        &["day", "subject", "requests", "input_tokens"],
    ),
    ("provider_hours", &["hour", "forwards", "failures"]),
    (
        "alerts",
        &[
            "kind",
            "period",
            "sent",
            "attempts",
            "value_a",
            "value_b",
            "created_at",
        ],
    ),
    ("mirror_dirty", &["tbl", "key_a", "key_b", "version"]),
    ("meta", &["key", "value"]),
];

/// Stored settlement labels; anything else read back is corruption.
const OUTCOME_LABELS: &[&str] = &[
    "usage",
    "rejected",
    "not_dispatched",
    "expired",
    "no_usage",
    "3xx",
    "4xx",
    "5xx",
    "other_status",
    "timeout",
    "unreachable",
    "body_too_large",
];

pub struct SqlStore<B: SqlBackend> {
    backend: B,
}

impl<B: SqlBackend> SqlStore<B> {
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    pub fn create_schema(&self) -> StoreResult<()> {
        for statement in SCHEMA {
            self.backend.run(statement, &[])?;
        }
        for (table, column) in RETIRED_COLUMNS {
            if self.has_column(table, column)? {
                self.backend
                    .run(&format!("ALTER TABLE {table} DROP COLUMN {column}"), &[])?;
            }
        }
        for (table, column, definition) in ADDED_COLUMNS {
            if !self.has_column(table, column)? {
                self.backend.run(
                    &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
                    &[],
                )?;
            }
        }
        Ok(())
    }

    fn has_column(&self, table: &str, column: &str) -> StoreResult<bool> {
        Ok(self
            .backend
            .run(&format!("PRAGMA table_info({table})"), &[])?
            .iter()
            .any(|row| matches!(row.get(1), Some(SqlValue::Text(name)) if name == column)))
    }

    pub fn backend(&self) -> &B {
        &self.backend
    }

    fn rows(&self, sql: &str, args: &[SqlValue]) -> StoreResult<Vec<Vec<SqlValue>>> {
        self.backend.run(sql, args)
    }

    fn exec(&self, sql: &str, args: &[SqlValue]) -> StoreResult<()> {
        self.backend.run(sql, args).map(|_| ())
    }
}

fn int(value: u64) -> StoreResult<SqlValue> {
    // JavaScript numbers carry 53 bits exactly; nothing here comes near.
    if value > crate::config::MAX_STORED_INTEGER {
        return Err(StoreError::Range);
    }
    Ok(SqlValue::Int(value as i64))
}

fn signed(value: i64) -> StoreResult<SqlValue> {
    if value.unsigned_abs() > (1 << 53) {
        return Err(StoreError::Range);
    }
    Ok(SqlValue::Int(value))
}

fn text(value: &str) -> SqlValue {
    SqlValue::Text(value.to_string())
}

fn optional(value: Option<i64>) -> StoreResult<SqlValue> {
    value.map(signed).unwrap_or(Ok(SqlValue::Null))
}

struct Row<'a>(&'a [SqlValue]);

impl Row<'_> {
    fn i64(&self, index: usize) -> StoreResult<i64> {
        match self.0.get(index) {
            Some(SqlValue::Int(value)) => Ok(*value),
            _ => Err(StoreError::Corrupt),
        }
    }

    fn u64(&self, index: usize) -> StoreResult<u64> {
        u64::try_from(self.i64(index)?).map_err(|_| StoreError::Corrupt)
    }

    fn u32(&self, index: usize) -> StoreResult<u32> {
        u32::try_from(self.i64(index)?).map_err(|_| StoreError::Corrupt)
    }

    fn bool(&self, index: usize) -> StoreResult<bool> {
        Ok(self.i64(index)? != 0)
    }

    fn opt_i64(&self, index: usize) -> StoreResult<Option<i64>> {
        match self.0.get(index) {
            Some(SqlValue::Null) => Ok(None),
            Some(SqlValue::Int(value)) => Ok(Some(*value)),
            _ => Err(StoreError::Corrupt),
        }
    }

    fn text(&self, index: usize) -> StoreResult<String> {
        match self.0.get(index) {
            Some(SqlValue::Text(value)) => Ok(value.clone()),
            _ => Err(StoreError::Corrupt),
        }
    }

    fn opt_text(&self, index: usize) -> StoreResult<Option<String>> {
        match self.0.get(index) {
            Some(SqlValue::Null) => Ok(None),
            Some(SqlValue::Text(value)) => Ok(Some(value.clone())),
            _ => Err(StoreError::Corrupt),
        }
    }
}

fn feature(value: &str) -> StoreResult<Feature> {
    Feature::parse(value).ok_or(StoreError::Corrupt)
}

fn mode(value: &str) -> StoreResult<Mode> {
    match value {
        "open" => Ok(Mode::Open),
        "trial" => Ok(Mode::Trial),
        _ => Err(StoreError::Corrupt),
    }
}

const RESERVATION_COLUMNS: &str = "id, subject, lane, run_id, window_index, feature, model, mode, \
     month, spill_month, day, input_tokens, max_output_tokens, input_price, output_price, \
     reserved_micros, charged_micros, state, outcome, created_at, deadline, finalized_at, \
     input_bound_tokens";

fn reservation(row: &[SqlValue]) -> StoreResult<Reservation> {
    let row = Row(row);
    let outcome = match row.opt_text(18)? {
        None => None,
        Some(label) => Some(
            *OUTCOME_LABELS
                .iter()
                .find(|known| **known == label)
                .ok_or(StoreError::Corrupt)?,
        ),
    };
    Ok(Reservation {
        id: row.text(0)?,
        subject: row.text(1)?,
        lane: Lane::parse(&row.text(2)?).ok_or(StoreError::Corrupt)?,
        run_id: row.text(3)?,
        window_index: u16::try_from(row.i64(4)?).map_err(|_| StoreError::Corrupt)?,
        feature: feature(&row.text(5)?)?,
        model: row.text(6)?,
        mode: mode(&row.text(7)?)?,
        month: row.text(8)?,
        spill_month: row.opt_text(9)?,
        day: row.i64(10)?,
        input_tokens: row.u64(11)?,
        max_output_tokens: row.u32(12)?,
        input_price: row.u64(13)?,
        output_price: row.u64(14)?,
        reserved_micros: row.u64(15)?,
        charged_micros: row.u64(16)?,
        state: ReservationState::parse(&row.text(17)?).ok_or(StoreError::Corrupt)?,
        outcome,
        created_at: row.i64(19)?,
        deadline: row.i64(20)?,
        finalized_at: row.opt_i64(21)?,
        input_bound_tokens: row.u64(22)?,
    })
}

fn windows_text(windows: &BTreeSet<u16>) -> String {
    windows
        .iter()
        .map(u16::to_string)
        .collect::<Vec<_>>()
        .join(",")
}

fn parse_windows(value: &str) -> StoreResult<BTreeSet<u16>> {
    if value.is_empty() {
        return Ok(BTreeSet::new());
    }
    value
        .split(',')
        .map(|index| index.parse().map_err(|_| StoreError::Corrupt))
        .collect()
}

fn mirror_parts(key: &MirrorKey) -> (&'static str, String, String) {
    match key {
        MirrorKey::Install(subject) => ("install", subject.clone(), String::new()),
        MirrorKey::Run(subject, run_id) => ("run", subject.clone(), run_id.clone()),
        MirrorKey::Month(month) => ("month", month.clone(), String::new()),
        MirrorKey::Day(day) => ("day", day.to_string(), String::new()),
    }
}

fn mirror_key(table: &str, key_a: String, key_b: String) -> StoreResult<MirrorKey> {
    match table {
        "install" => Ok(MirrorKey::Install(key_a)),
        "run" => Ok(MirrorKey::Run(key_a, key_b)),
        "month" => Ok(MirrorKey::Month(key_a)),
        "day" => key_a
            .parse()
            .map(MirrorKey::Day)
            .map_err(|_| StoreError::Corrupt),
        _ => Err(StoreError::Corrupt),
    }
}

impl<B: SqlBackend> LedgerStore for SqlStore<B> {
    fn reservation(&self, id: &str) -> StoreResult<Option<Reservation>> {
        self.rows(
            &format!("SELECT {RESERVATION_COLUMNS} FROM reservations WHERE id = ?"),
            &[text(id)],
        )?
        .first()
        .map(|row| reservation(row))
        .transpose()
    }

    fn open_reservations(&self, subject: &str) -> StoreResult<Vec<Reservation>> {
        self.rows(
            &format!(
                "SELECT {RESERVATION_COLUMNS} FROM reservations WHERE subject = ? AND state = 'open'"
            ),
            &[text(subject)],
        )?
        .iter()
        .map(|row| reservation(row))
        .collect()
    }

    fn due_reservations(&self, now: i64, limit: usize) -> StoreResult<Vec<Reservation>> {
        self.rows(
            &format!(
                "SELECT {RESERVATION_COLUMNS} FROM reservations \
                 WHERE state = 'open' AND deadline <= ? ORDER BY deadline LIMIT ?"
            ),
            &[signed(now)?, int(limit as u64)?],
        )?
        .iter()
        .map(|row| reservation(row))
        .collect()
    }

    fn earliest_open_deadline(&self) -> StoreResult<Option<i64>> {
        match self
            .rows(
                "SELECT MIN(deadline) FROM reservations WHERE state = 'open'",
                &[],
            )?
            .first()
        {
            Some(row) => Row(row).opt_i64(0),
            None => Ok(None),
        }
    }

    fn put_reservation(&mut self, r: &Reservation) -> StoreResult<()> {
        self.exec(
            &format!(
                "INSERT OR REPLACE INTO reservations ({RESERVATION_COLUMNS}) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            ),
            &[
                text(&r.id),
                text(&r.subject),
                text(r.lane.as_str()),
                text(&r.run_id),
                int(u64::from(r.window_index))?,
                text(r.feature.as_str()),
                text(&r.model),
                text(r.mode.as_str()),
                text(&r.month),
                r.spill_month.as_deref().map(text).unwrap_or(SqlValue::Null),
                signed(r.day)?,
                int(r.input_tokens)?,
                int(u64::from(r.max_output_tokens))?,
                int(r.input_price)?,
                int(r.output_price)?,
                int(r.reserved_micros)?,
                int(r.charged_micros)?,
                text(r.state.as_str()),
                r.outcome.map(text).unwrap_or(SqlValue::Null),
                signed(r.created_at)?,
                signed(r.deadline)?,
                optional(r.finalized_at)?,
                int(r.input_bound_tokens)?,
            ],
        )
    }

    fn install(&self, subject: &str) -> StoreResult<Option<Install>> {
        self.rows(
            "SELECT subject, trial_units_used, open_runs, version, updated_at FROM installs WHERE subject = ?",
            &[text(subject)],
        )?
        .first()
        .map(|row| {
            let row = Row(row);
            Ok(Install {
                subject: row.text(0)?,
                trial_units_used: row.u32(1)?,
                open_runs: row.u32(2)?,
                version: row.u64(3)?,
                updated_at: row.i64(4)?,
            })
        })
        .transpose()
    }

    fn put_install(&mut self, i: &Install) -> StoreResult<()> {
        self.exec(
            "INSERT OR REPLACE INTO installs (subject, trial_units_used, open_runs, version, updated_at) \
             VALUES (?, ?, ?, ?, ?)",
            &[
                text(&i.subject),
                int(u64::from(i.trial_units_used))?,
                int(u64::from(i.open_runs))?,
                int(i.version)?,
                signed(i.updated_at)?,
            ],
        )
    }

    fn run(&self, subject: &str, run_id: &str) -> StoreResult<Option<Run>> {
        self.rows(
            "SELECT subject, run_id, feature, windows, reservations, reserved_input_tokens, \
             charged_micros, unit_consumed, created_at, updated_at, version \
             FROM runs WHERE subject = ? AND run_id = ?",
            &[text(subject), text(run_id)],
        )?
        .first()
        .map(|row| {
            let row = Row(row);
            Ok(Run {
                subject: row.text(0)?,
                run_id: row.text(1)?,
                feature: feature(&row.text(2)?)?,
                windows: parse_windows(&row.text(3)?)?,
                reservations: row.u32(4)?,
                reserved_input_tokens: row.u64(5)?,
                charged_micros: row.u64(6)?,
                unit_consumed: row.bool(7)?,
                created_at: row.i64(8)?,
                updated_at: row.i64(9)?,
                version: row.u64(10)?,
            })
        })
        .transpose()
    }

    fn put_run(&mut self, r: &Run) -> StoreResult<()> {
        self.exec(
            "INSERT OR REPLACE INTO runs (subject, run_id, feature, windows, reservations, \
             reserved_input_tokens, charged_micros, unit_consumed, created_at, updated_at, version) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            &[
                text(&r.subject),
                text(&r.run_id),
                text(r.feature.as_str()),
                SqlValue::Text(windows_text(&r.windows)),
                int(u64::from(r.reservations))?,
                int(r.reserved_input_tokens)?,
                int(r.charged_micros)?,
                int(u64::from(r.unit_consumed))?,
                signed(r.created_at)?,
                signed(r.updated_at)?,
                int(r.version)?,
            ],
        )
    }

    fn month(&self, month: &str) -> StoreResult<Option<Month>> {
        self.rows(
            "SELECT month, charged_micros, overrun_micros, reservations, paused_at, version, updated_at \
             FROM months WHERE month = ?",
            &[text(month)],
        )?
        .first()
        .map(|row| {
            let row = Row(row);
            Ok(Month {
                month: row.text(0)?,
                charged_micros: row.u64(1)?,
                overrun_micros: row.u64(2)?,
                reservations: row.u64(3)?,
                paused_at: row.opt_i64(4)?,
                version: row.u64(5)?,
                updated_at: row.i64(6)?,
            })
        })
        .transpose()
    }

    fn put_month(&mut self, m: &Month) -> StoreResult<()> {
        self.exec(
            "INSERT OR REPLACE INTO months (month, charged_micros, overrun_micros, reservations, \
             paused_at, version, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            &[
                text(&m.month),
                int(m.charged_micros)?,
                int(m.overrun_micros)?,
                int(m.reservations)?,
                optional(m.paused_at)?,
                int(m.version)?,
                signed(m.updated_at)?,
            ],
        )
    }

    fn day(&self, day: i64) -> StoreResult<Option<Day>> {
        self.rows(&format!("{DAY_SELECT} WHERE day = ?"), &[signed(day)?])?
            .first()
            .map(|row| day_row(row))
            .transpose()
    }

    fn put_day(&mut self, d: &Day) -> StoreResult<()> {
        self.exec(
            "INSERT OR REPLACE INTO days (day, admitted, input_tokens, would_refuse_runs, forwards, \
             provider_failures, expired, overruns, overrun_micros, summary_logged, version, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            &[
                signed(d.day)?,
                int(d.admitted)?,
                int(d.input_tokens)?,
                int(d.would_refuse_runs)?,
                int(d.forwards)?,
                int(d.provider_failures)?,
                int(d.expired)?,
                int(d.overruns)?,
                int(d.overrun_micros)?,
                int(u64::from(d.summary_logged))?,
                int(d.version)?,
                signed(d.updated_at)?,
            ],
        )
    }

    fn unlogged_days_before(&self, day: i64) -> StoreResult<Vec<Day>> {
        self.rows(
            &format!("{DAY_SELECT} WHERE day < ? AND summary_logged = 0 ORDER BY day"),
            &[signed(day)?],
        )?
        .iter()
        .map(|row| day_row(row))
        .collect()
    }

    fn bearer_day(&self, day: i64, subject: &str) -> StoreResult<Option<BearerDay>> {
        self.rows(
            "SELECT day, subject, requests, input_tokens FROM bearer_days WHERE day = ? AND subject = ?",
            &[signed(day)?, text(subject)],
        )?
        .first()
        .map(|row| {
            let row = Row(row);
            Ok(BearerDay {
                day: row.i64(0)?,
                subject: row.text(1)?,
                requests: row.u64(2)?,
                input_tokens: row.u64(3)?,
            })
        })
        .transpose()
    }

    fn put_bearer_day(&mut self, d: &BearerDay) -> StoreResult<()> {
        self.exec(
            "INSERT OR REPLACE INTO bearer_days (day, subject, requests, input_tokens) VALUES (?, ?, ?, ?)",
            &[signed(d.day)?, text(&d.subject), int(d.requests)?, int(d.input_tokens)?],
        )
    }

    fn provider_hours_since(&self, hour: i64) -> StoreResult<Vec<ProviderHour>> {
        self.rows(
            "SELECT hour, forwards, failures FROM provider_hours WHERE hour >= ? ORDER BY hour",
            &[signed(hour)?],
        )?
        .iter()
        .map(|row| {
            let row = Row(row);
            Ok(ProviderHour {
                hour: row.i64(0)?,
                forwards: row.u64(1)?,
                failures: row.u64(2)?,
            })
        })
        .collect()
    }

    fn put_provider_hour(&mut self, h: &ProviderHour) -> StoreResult<()> {
        self.exec(
            "INSERT OR REPLACE INTO provider_hours (hour, forwards, failures) VALUES (?, ?, ?)",
            &[signed(h.hour)?, int(h.forwards)?, int(h.failures)?],
        )
    }

    fn alert(&self, kind: AlertKind, period: &str) -> StoreResult<Option<AlertRecord>> {
        self.rows(
            &format!("{ALERT_SELECT} WHERE kind = ? AND period = ?"),
            &[text(kind.as_str()), text(period)],
        )?
        .first()
        .map(|row| alert_row(row))
        .transpose()
    }

    fn pending_alerts(&self) -> StoreResult<Vec<AlertRecord>> {
        self.rows(
            &format!("{ALERT_SELECT} WHERE sent = 0 ORDER BY created_at"),
            &[],
        )?
        .iter()
        .map(|row| alert_row(row))
        .collect()
    }

    fn put_alert(&mut self, a: &AlertRecord) -> StoreResult<()> {
        self.exec(
            "INSERT OR REPLACE INTO alerts (kind, period, sent, attempts, value_a, value_b, created_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            &[
                text(a.kind.as_str()),
                text(&a.period),
                int(u64::from(a.sent))?,
                int(u64::from(a.attempts))?,
                int(a.value_a)?,
                int(a.value_b)?,
                signed(a.created_at)?,
            ],
        )
    }

    fn meta(&self, key: &str) -> StoreResult<Option<i64>> {
        match self
            .rows("SELECT value FROM meta WHERE key = ?", &[text(key)])?
            .first()
        {
            Some(row) => Ok(Some(Row(row).i64(0)?)),
            None => Ok(None),
        }
    }

    fn put_meta(&mut self, key: &str, value: i64) -> StoreResult<()> {
        self.exec(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
            &[text(key), signed(value)?],
        )
    }

    fn mark_dirty(&mut self, key: &MirrorKey, version: u64) -> StoreResult<()> {
        let (table, key_a, key_b) = mirror_parts(key);
        self.exec(
            "INSERT OR REPLACE INTO mirror_dirty (tbl, key_a, key_b, version) VALUES (?, ?, ?, ?)",
            &[
                text(table),
                SqlValue::Text(key_a),
                SqlValue::Text(key_b),
                int(version)?,
            ],
        )
    }

    fn dirty(&self, limit: usize) -> StoreResult<Vec<(MirrorKey, u64)>> {
        self.rows(
            "SELECT tbl, key_a, key_b, version FROM mirror_dirty ORDER BY version LIMIT ?",
            &[int(limit as u64)?],
        )?
        .iter()
        .map(|row| {
            let row = Row(row);
            Ok((
                mirror_key(&row.text(0)?, row.text(1)?, row.text(2)?)?,
                row.u64(3)?,
            ))
        })
        .collect()
    }

    fn clear_dirty(&mut self, key: &MirrorKey, version: u64) -> StoreResult<()> {
        let (table, key_a, key_b) = mirror_parts(key);
        self.exec(
            "DELETE FROM mirror_dirty WHERE tbl = ? AND key_a = ? AND key_b = ? AND version = ?",
            &[
                text(table),
                SqlValue::Text(key_a),
                SqlValue::Text(key_b),
                int(version)?,
            ],
        )
    }

    fn prune(&mut self, c: &PruneCutoffs) -> StoreResult<u64> {
        let before = self.count_rows()?;
        self.exec(
            "DELETE FROM reservations WHERE state != 'open' AND finalized_at < ?",
            &[signed(c.reservations_finalized_before)?],
        )?;
        // A run that consumed a unit is the proof it may resume for free:
        // kept for the life of the entitlement.
        self.exec(
            "DELETE FROM runs WHERE unit_consumed = 0 AND updated_at < ?",
            &[signed(c.runs_updated_before)?],
        )?;
        self.exec("DELETE FROM days WHERE day < ?", &[signed(c.days_before)?])?;
        self.exec(
            "DELETE FROM bearer_days WHERE day < ?",
            &[signed(c.bearer_days_before)?],
        )?;
        self.exec(
            "DELETE FROM provider_hours WHERE hour < ?",
            &[signed(c.provider_hours_before)?],
        )?;
        self.exec(
            "DELETE FROM alerts WHERE sent = 1 AND created_at < ?",
            &[signed(c.alerts_created_before)?],
        )?;
        Ok(before.saturating_sub(self.count_rows()?))
    }
}

impl<B: SqlBackend> SqlStore<B> {
    fn count_rows(&self) -> StoreResult<u64> {
        let rows = self.rows(
            "SELECT (SELECT COUNT(*) FROM reservations) + (SELECT COUNT(*) FROM runs) \
             + (SELECT COUNT(*) FROM days) + (SELECT COUNT(*) FROM bearer_days) \
             + (SELECT COUNT(*) FROM provider_hours) + (SELECT COUNT(*) FROM alerts)",
            &[],
        )?;
        rows.first().map(|row| Row(row).u64(0)).unwrap_or(Ok(0))
    }
}

const DAY_SELECT: &str = "SELECT day, admitted, input_tokens, would_refuse_runs, forwards, \
     provider_failures, expired, overruns, overrun_micros, summary_logged, version, updated_at FROM days";

fn day_row(row: &[SqlValue]) -> StoreResult<Day> {
    let row = Row(row);
    Ok(Day {
        day: row.i64(0)?,
        admitted: row.u64(1)?,
        input_tokens: row.u64(2)?,
        would_refuse_runs: row.u64(3)?,
        forwards: row.u64(4)?,
        provider_failures: row.u64(5)?,
        expired: row.u64(6)?,
        overruns: row.u64(7)?,
        overrun_micros: row.u64(8)?,
        summary_logged: row.bool(9)?,
        version: row.u64(10)?,
        updated_at: row.i64(11)?,
    })
}

const ALERT_SELECT: &str =
    "SELECT kind, period, sent, attempts, value_a, value_b, created_at FROM alerts";

fn alert_row(row: &[SqlValue]) -> StoreResult<AlertRecord> {
    let row = Row(row);
    Ok(AlertRecord {
        kind: AlertKind::parse(&row.text(0)?).ok_or(StoreError::Corrupt)?,
        period: row.text(1)?,
        sent: row.bool(2)?,
        attempts: row.u32(3)?,
        value_a: row.u64(4)?,
        value_b: row.u64(5)?,
        created_at: row.i64(6)?,
    })
}

/// One D1 mirror upsert: newer versions only, so a late or replayed flush
/// never moves a row backwards.
#[derive(Debug, Clone, PartialEq)]
pub struct MirrorStatement {
    pub sql: &'static str,
    pub args: Vec<SqlValue>,
}

pub const MIRROR_INSTALL_SQL: &str = "INSERT INTO trial_install \
     (subject, trial_units_used, open_runs, version, updated_at) VALUES (?1, ?2, ?3, ?4, ?5) \
     ON CONFLICT(subject) DO UPDATE SET trial_units_used = excluded.trial_units_used, \
     open_runs = excluded.open_runs, version = excluded.version, updated_at = excluded.updated_at \
     WHERE excluded.version > trial_install.version";
pub const MIRROR_RUN_SQL: &str = "INSERT INTO trial_run \
     (subject, run_id, feature, windows, reservations, reserved_input_tokens, charged_micros, \
     unit_consumed, created_at, version, updated_at) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) \
     ON CONFLICT(subject, run_id) DO UPDATE SET feature = excluded.feature, \
     windows = excluded.windows, reservations = excluded.reservations, \
     reserved_input_tokens = excluded.reserved_input_tokens, \
     charged_micros = excluded.charged_micros, unit_consumed = excluded.unit_consumed, \
     version = excluded.version, updated_at = excluded.updated_at \
     WHERE excluded.version > trial_run.version";
pub const MIRROR_MONTH_SQL: &str = "INSERT INTO trial_month \
     (month, charged_micros, overrun_micros, reservations, paused_at, version, updated_at) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
     ON CONFLICT(month) DO UPDATE SET charged_micros = excluded.charged_micros, \
     overrun_micros = excluded.overrun_micros, \
     reservations = excluded.reservations, paused_at = excluded.paused_at, \
     version = excluded.version, updated_at = excluded.updated_at \
     WHERE excluded.version > trial_month.version";
pub const MIRROR_DAY_SQL: &str = "INSERT INTO trial_day \
     (day, admitted, input_tokens, would_refuse_runs, forwards, provider_failures, expired, \
     overruns, overrun_micros, version, updated_at) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) \
     ON CONFLICT(day) DO UPDATE SET admitted = excluded.admitted, \
     input_tokens = excluded.input_tokens, would_refuse_runs = excluded.would_refuse_runs, \
     forwards = excluded.forwards, provider_failures = excluded.provider_failures, \
     expired = excluded.expired, overruns = excluded.overruns, \
     overrun_micros = excluded.overrun_micros, \
     version = excluded.version, updated_at = excluded.updated_at \
     WHERE excluded.version > trial_day.version";
/// The mirror is an ops archive: unit-free runs idle this long leave it;
/// runs that consumed a unit, months and days stay.
pub const MIRROR_RUN_RETENTION_MS: i64 = 90 * crate::clock::MS_PER_DAY;
pub const MIRROR_PRUNE_RUNS_SQL: &str =
    "DELETE FROM trial_run WHERE unit_consumed = 0 AND updated_at < ?1";

/// The mirror statement for a dirty key's current row (`None` when the row
/// is gone, e.g. pruned).
pub fn mirror_statement<S: LedgerStore>(
    store: &S,
    key: &MirrorKey,
) -> StoreResult<Option<MirrorStatement>> {
    match key {
        MirrorKey::Install(subject) => store.install(subject)?.map(|i| -> StoreResult<_> {
            Ok(MirrorStatement {
                sql: MIRROR_INSTALL_SQL,
                args: vec![
                    text(&i.subject),
                    int(u64::from(i.trial_units_used))?,
                    int(u64::from(i.open_runs))?,
                    int(i.version)?,
                    signed(i.updated_at)?,
                ],
            })
        }),
        MirrorKey::Run(subject, run_id) => store.run(subject, run_id)?.map(|r| {
            Ok(MirrorStatement {
                sql: MIRROR_RUN_SQL,
                args: vec![
                    text(&r.subject),
                    text(&r.run_id),
                    text(r.feature.as_str()),
                    int(r.windows.len() as u64)?,
                    int(u64::from(r.reservations))?,
                    int(r.reserved_input_tokens)?,
                    int(r.charged_micros)?,
                    int(u64::from(r.unit_consumed))?,
                    signed(r.created_at)?,
                    int(r.version)?,
                    signed(r.updated_at)?,
                ],
            })
        }),
        MirrorKey::Month(month) => store.month(month)?.map(|m| {
            Ok(MirrorStatement {
                sql: MIRROR_MONTH_SQL,
                args: vec![
                    text(&m.month),
                    int(m.charged_micros)?,
                    int(m.overrun_micros)?,
                    int(m.reservations)?,
                    optional(m.paused_at)?,
                    int(m.version)?,
                    signed(m.updated_at)?,
                ],
            })
        }),
        MirrorKey::Day(day) => store.day(*day)?.map(|d| {
            Ok(MirrorStatement {
                sql: MIRROR_DAY_SQL,
                args: vec![
                    signed(d.day)?,
                    int(d.admitted)?,
                    int(d.input_tokens)?,
                    int(d.would_refuse_runs)?,
                    int(d.forwards)?,
                    int(d.provider_failures)?,
                    int(d.expired)?,
                    int(d.overruns)?,
                    int(d.overrun_micros)?,
                    int(d.version)?,
                    signed(d.updated_at)?,
                ],
            })
        }),
    }
    .transpose()
}

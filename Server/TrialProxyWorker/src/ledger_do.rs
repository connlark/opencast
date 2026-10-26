//! `TrialLedger`: the one Durable Object (named `global`) that admits and
//! settles every trial window. A thin adapter: each operation runs the pure
//! state machine in `ledger.rs` over the object's SQLite storage inside
//! `transactionSync`, so a failed statement rolls the whole operation back.
//! It never awaits a provider call. After responding it flushes the D1
//! mirror and sends pending alerts; its alarm expires lapsed reservations,
//! logs closed days, prunes and retries both.

use std::cell::RefCell;
use std::rc::Rc;

use serde::{Deserialize, Serialize};
use worker::js_sys::{Function, Reflect};
use worker::wasm_bindgen::{closure::Closure, JsCast, JsValue};
use worker::{
    console_log, durable_object, wasm_bindgen, D1Type, Date, Delay, DurableObject, Env, Fetch,
    Headers, Method, Request, RequestInit, Response, Result, ScheduledTime, SqlStorage,
    SqlStorageValue, State,
};

use crate::alerts::{message, title, PUSHOVER_URL};
use crate::bundle;
use crate::config::{self, AlertLane, LedgerConfig};
use crate::ledger::{
    self, AdmitRequest, AdmitResult, AlertRecord, Decision, Lane, MirrorKey, SettleResult,
    StatusView, StoreError, StoreResult,
};
use crate::ledger_sql::{
    mirror_statement, SqlBackend, SqlStore, SqlValue, MIRROR_PRUNE_RUNS_SQL,
    MIRROR_RUN_RETENTION_MS,
};
use crate::provider::SettleOutcome;
use crate::telemetry::{
    line, AlertEvent, DaySummaryEvent, HousekeepingEvent, MirrorEvent, OverrunEvent, StageEvent,
};
use crate::worker_app::{json_response, EnvVars, TRIAL_DB};

const EXPIRE_BATCH: usize = 500;
const MIRROR_BATCH: usize = 200;
/// When an admission or settlement could not store the alarm: retry this
/// often in the background before leaving it to the next entry point.
const ALARM_RETRY_ATTEMPTS: u32 = 3;
const ALARM_RETRY_DELAY_MS: u64 = 1_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SettleRequest {
    pub reservation_id: String,
    pub outcome: SettleOutcome,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusRequest {
    pub subject: String,
    pub lane: Lane,
    pub model: String,
    pub smallest_max_output_tokens: u32,
    /// The forward budget that window's default call gets: its lock, and so
    /// its price interval and month, are the admission's.
    pub forward_budget_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdmitResponse {
    pub decision: Decision,
}

struct ObjectSql(SqlStorage);

impl SqlBackend for ObjectSql {
    fn run(&self, sql: &str, args: &[SqlValue]) -> StoreResult<Vec<Vec<SqlValue>>> {
        let bindings = args
            .iter()
            .map(|value| match value {
                SqlValue::Null => SqlStorageValue::Null,
                SqlValue::Int(value) => SqlStorageValue::Integer(*value),
                SqlValue::Text(value) => SqlStorageValue::String(value.clone()),
            })
            .collect::<Vec<_>>();
        let cursor = self
            .0
            .exec(sql, bindings)
            .map_err(|_| StoreError::Storage)?;
        cursor
            .raw()
            .map(|row| {
                row.map_err(|_| StoreError::Storage)?
                    .into_iter()
                    .map(|value| match value {
                        SqlStorageValue::Null => Ok(SqlValue::Null),
                        SqlStorageValue::Integer(value) => Ok(SqlValue::Int(value)),
                        SqlStorageValue::Boolean(value) => Ok(SqlValue::Int(i64::from(value))),
                        SqlStorageValue::String(value) => Ok(SqlValue::Text(value)),
                        SqlStorageValue::Float(_) | SqlStorageValue::Blob(_) => {
                            Err(StoreError::Corrupt)
                        }
                    })
                    .collect()
            })
            .collect()
    }
}

#[durable_object(alarm)]
pub struct TrialLedger {
    state: State,
    env: Env,
    sql: SqlStorage,
}

impl DurableObject for TrialLedger {
    fn new(state: State, env: Env) -> Self {
        let sql = state.storage().sql();
        if SqlStore::new(ObjectSql(sql.clone()))
            .create_schema()
            .is_err()
        {
            stage("schema", StoreError::Storage);
        }
        Self { state, env, sql }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        if req.method() != Method::Post {
            return json_response(405, br#"{"error":"method_not_allowed"}"#.to_vec());
        }
        let Some(ledger_config) = self.ledger_config() else {
            return unavailable("config", StoreError::Storage);
        };
        let body = match req.bytes().await {
            Ok(body) => body,
            Err(_) => return unavailable("read", StoreError::Storage),
        };
        match req.path().as_str() {
            "/admit" => self.admit(&ledger_config, &body).await,
            "/settle" => self.settle(&body).await,
            "/status" => self.status(&ledger_config, &body),
            _ => json_response(404, br#"{"error":"not_found"}"#.to_vec()),
        }
    }

    async fn alarm(&self) -> Result<Response> {
        let now = now_ms();
        // Re-arm first: a failure below must never leave the object
        // without a next alarm.
        let mut armed = self
            .state
            .storage()
            .set_alarm(at_epoch_ms(now + crate::clock::MS_PER_HOUR))
            .await
            .is_ok();
        if !armed {
            stage("alarm_rearm_failed", StoreError::Storage);
        }
        let expired = self
            .transaction(move |store| ledger::expire_due(store, now, EXPIRE_BATCH))
            .unwrap_or_else(|error| {
                stage("alarm_expire", error);
                0
            });
        match self.transaction(move |store| ledger::take_day_summaries(store, now)) {
            Ok(days) => {
                for day in days {
                    console_log!(
                        "{}",
                        line(&DaySummaryEvent {
                            event: "trial_day_summary",
                            day: day.day,
                            admitted: day.admitted,
                            input_tokens: day.input_tokens,
                            trial_would_refuse: day.would_refuse_runs,
                            forwards: day.forwards,
                            provider_failures: day.provider_failures,
                            expired: day.expired,
                            overruns: day.overruns,
                            overrun_micros: day.overrun_micros,
                        })
                    );
                }
            }
            Err(error) => stage("alarm_summaries", error),
        }
        let pruned = self
            .transaction(move |store| ledger::prune(store, now))
            .unwrap_or_else(|error| {
                stage("alarm_prune", error);
                0
            });
        console_log!(
            "{}",
            line(&HousekeepingEvent {
                event: "trial_housekeeping",
                expired,
                pruned,
            })
        );
        self.flush_mirror().await;
        if let Ok(db) = self.env.d1(TRIAL_DB) {
            let cutoff = now - MIRROR_RUN_RETENTION_MS;
            if let Ok(statement) = db
                .prepare(MIRROR_PRUNE_RUNS_SQL)
                .bind_refs(&[D1Type::Real(cutoff as f64)])
            {
                if statement.run().await.is_err() {
                    stage("mirror_prune", StoreError::Storage);
                }
            }
        }
        self.send_pending_alerts().await;
        armed |= self.alarm_arm().arm(now).await;
        if !armed {
            // No next alarm is stored: fail so the runtime retries this one,
            // or expiry, the mirror, pruning and pending alerts would wait
            // for the next request. A static message: nothing else reaches
            // the runtime's log.
            return Err(worker::Error::RustError("trial_alarm_not_rearmed".into()));
        }
        Response::ok("")
    }
}

impl TrialLedger {
    fn store(&self) -> SqlStore<ObjectSql> {
        SqlStore::new(ObjectSql(self.sql.clone()))
    }

    fn ledger_config(&self) -> Option<LedgerConfig> {
        let bundle = bundle::embedded().ok()?;
        config::load(&EnvVars(&self.env), bundle)
            .ok()
            .map(|config| config.ledger)
    }

    fn alert_lane(&self) -> AlertLane {
        bundle::embedded()
            .ok()
            .and_then(|bundle| config::load(&EnvVars(&self.env), bundle).ok())
            .map(|config| config.alert_lane)
            .unwrap_or(AlertLane::Dev)
    }

    /// Runs one ledger operation inside `storage.transactionSync`: an error
    /// from any statement rolls back everything the operation wrote.
    fn transaction<T: 'static>(
        &self,
        operation: impl FnOnce(&mut SqlStore<ObjectSql>) -> StoreResult<T> + 'static,
    ) -> StoreResult<T> {
        transaction_on(&self.state.storage(), self.store(), operation)
    }

    async fn admit(&self, ledger_config: &LedgerConfig, body: &[u8]) -> Result<Response> {
        let Ok(request) = serde_json::from_slice::<AdmitRequest>(body) else {
            return unavailable("admit_decode", StoreError::Corrupt);
        };
        let now = now_ms();
        let config = ledger_config.clone();
        let result: AdmitResult =
            match self.transaction(move |store| ledger::admit(store, &config, now, &request)) {
                Ok(result) => result,
                Err(error) => return unavailable("admit", error),
            };
        // A new reservation, a pending alert from a refusal, or a previous
        // arm that failed: every admission ends with an alarm stored.
        self.ensure_alarm(now).await;
        if !result.alerts.is_empty() {
            self.schedule_alerts(result.alerts.clone());
        }
        json(
            200,
            &AdmitResponse {
                decision: result.decision,
            },
        )
    }

    async fn settle(&self, body: &[u8]) -> Result<Response> {
        let Ok(request) = serde_json::from_slice::<SettleRequest>(body) else {
            return unavailable("settle_decode", StoreError::Corrupt);
        };
        let now = now_ms();
        let outcome = request.outcome;
        let effects = match self
            .transaction(move |store| ledger::settle(store, now, &request.reservation_id, &outcome))
        {
            Ok(effects) => effects,
            Err(error) => return unavailable("settle", error),
        };
        if let (
            SettleResult::Settled {
                reserved_micros,
                overrun_micros,
                ..
            },
            SettleOutcome::Usage { usage, .. },
        ) = (&effects.result, outcome)
        {
            if *overrun_micros > 0 {
                console_log!(
                    "{}",
                    line(&OverrunEvent {
                        event: "trial_settle_overrun",
                        reserved_micros: *reserved_micros,
                        overrun_micros: *overrun_micros,
                        prompt_tokens: usage.prompt_tokens,
                        output_tokens: usage.output_tokens,
                    })
                );
            }
        }
        let alerts = effects.alerts.clone();
        // Every settlement too (dirty mirror rows, pending alerts, and an
        // admission whose own arm may have failed).
        self.ensure_alarm(now).await;
        let ledger = self.clone_handles();
        self.state.wait_until(async move {
            ledger.flush_mirror().await;
            for alert in alerts {
                ledger.send_alert(alert).await;
            }
        });
        json(200, &effects.result)
    }

    fn status(&self, ledger_config: &LedgerConfig, body: &[u8]) -> Result<Response> {
        let Ok(request) = serde_json::from_slice::<StatusRequest>(body) else {
            return unavailable("status_decode", StoreError::Corrupt);
        };
        let view: StoreResult<StatusView> = ledger::status(
            &self.store(),
            ledger_config,
            now_ms(),
            &request.subject,
            request.lane,
            &request.model,
            request.smallest_max_output_tokens,
            request.forward_budget_ms,
        );
        match view {
            Ok(view) => json(200, &view),
            Err(error) => unavailable("status", error),
        }
    }

    fn alarm_arm(&self) -> AlarmArm {
        AlarmArm {
            storage: self.state.storage(),
            sql: self.sql.clone(),
        }
    }

    /// The end of every mutating entry point: an alarm stored while
    /// housekeeping is due (always: at least the hourly pass). Never fails
    /// the caller's request. A failure is retried in the background a few
    /// times, then by the next entry point.
    async fn ensure_alarm(&self, now: i64) {
        let alarm = self.alarm_arm();
        if alarm.arm(now).await {
            return;
        }
        self.state.wait_until(async move {
            for _ in 0..ALARM_RETRY_ATTEMPTS {
                Delay::from(std::time::Duration::from_millis(ALARM_RETRY_DELAY_MS)).await;
                if alarm.arm(now_ms()).await {
                    return;
                }
            }
        });
    }

    fn clone_handles(&self) -> Handles {
        Handles {
            state_storage: self.state.storage(),
            env: self.env.clone(),
            sql: self.sql.clone(),
            lane: self.alert_lane(),
        }
    }

    fn schedule_alerts(&self, alerts: Vec<AlertRecord>) {
        let handles = self.clone_handles();
        self.state.wait_until(async move {
            for alert in alerts {
                handles.send_alert(alert).await;
            }
        });
    }

    async fn flush_mirror(&self) {
        self.clone_handles().flush_mirror().await;
    }

    async fn send_pending_alerts(&self) {
        let handles = self.clone_handles();
        let pending = match ledger::alerts_to_send(&self.store()) {
            Ok(pending) => pending,
            Err(error) => return stage("alerts_pending", error),
        };
        for alert in pending {
            handles.send_alert(alert).await;
        }
    }
}

/// What arming the alarm needs, owned so a background retry can hold it.
struct AlarmArm {
    storage: worker::Storage,
    sql: SqlStorage,
}

impl AlarmArm {
    /// The alarm fires at the earliest open deadline, at most an hour out.
    /// True when an alarm at or before that time is stored afterwards; a
    /// failure is logged (`alarm_rearm_failed`).
    async fn arm(&self, now: i64) -> bool {
        let next = match ledger::next_alarm(&SqlStore::new(ObjectSql(self.sql.clone())), now) {
            Ok(next) => next,
            Err(error) => {
                stage("alarm_rearm_failed", error);
                return false;
            }
        };
        let current = self.storage.get_alarm().await.ok().flatten();
        if current.is_some_and(|current| current <= next) {
            return true;
        }
        let set = self.storage.set_alarm(at_epoch_ms(next)).await.is_ok();
        if !set {
            stage("alarm_rearm_failed", StoreError::Storage);
        }
        set
    }
}

/// What a `wait_until` future needs after the request has been answered.
struct Handles {
    state_storage: worker::Storage,
    env: Env,
    sql: SqlStorage,
    lane: AlertLane,
}

impl Handles {
    fn store(&self) -> SqlStore<ObjectSql> {
        SqlStore::new(ObjectSql(self.sql.clone()))
    }

    fn transaction<T: 'static>(
        &self,
        operation: impl FnOnce(&mut SqlStore<ObjectSql>) -> StoreResult<T> + 'static,
    ) -> StoreResult<T> {
        transaction_on(&self.state_storage, self.store(), operation)
    }

    /// Writes every dirty row's current state to D1 (newer versions only)
    /// and clears the marks that did not move meanwhile.
    async fn flush_mirror(&self) {
        let now = now_ms();
        let store = self.store();
        let dirty = match ledger::LedgerStore::dirty(&store, MIRROR_BATCH) {
            Ok(dirty) if !dirty.is_empty() => dirty,
            Ok(_) => return,
            Err(error) => return stage("mirror_dirty", error),
        };
        let mut rows: Vec<(MirrorKey, u64, Option<crate::ledger_sql::MirrorStatement>)> =
            Vec::with_capacity(dirty.len());
        for (key, version) in dirty {
            match mirror_statement(&store, &key) {
                Ok(statement) => rows.push((key, version, statement)),
                Err(error) => return stage("mirror_read", error),
            }
        }
        let written = match self.env.d1(TRIAL_DB) {
            Ok(db) => {
                let mut statements = Vec::new();
                let mut bound = true;
                for (_, _, statement) in &rows {
                    let Some(statement) = statement else { continue };
                    let args: Vec<D1Type<'_>> = statement
                        .args
                        .iter()
                        .map(|value| match value {
                            SqlValue::Null => D1Type::Null,
                            SqlValue::Int(value) => D1Type::Real(*value as f64),
                            SqlValue::Text(value) => D1Type::Text(value),
                        })
                        .collect();
                    match db.prepare(statement.sql).bind_refs(&args) {
                        Ok(prepared) => statements.push(prepared),
                        Err(_) => bound = false,
                    }
                }
                bound && (statements.is_empty() || db.batch(statements).await.is_ok())
            }
            Err(_) => false,
        };
        let row_count = rows.len() as u64;
        let outcome = self.transaction(move |store| {
            if written {
                for (key, version, _) in &rows {
                    ledger::LedgerStore::clear_dirty(store, key, *version)?;
                }
            }
            ledger::record_mirror_flush(store, now, written)
        });
        match outcome {
            Ok((consecutive_failures, alert)) => {
                console_log!(
                    "{}",
                    line(&MirrorEvent {
                        event: "trial_mirror",
                        outcome: if written { "ok" } else { "failed" },
                        rows: row_count,
                        consecutive_failures,
                    })
                );
                if let Some(alert) = alert {
                    self.send_alert(alert).await;
                }
            }
            Err(error) => stage("mirror_record", error),
        }
    }

    /// One Pushover attempt; the alert stays pending (and the alarm retries
    /// it) until a 2xx.
    /// One Pushover attempt, claimed before the send; the alarm retries an
    /// unsent alert until it is sent or out of attempts (at least once).
    async fn send_alert(&self, alert: AlertRecord) {
        let kind = alert.kind;
        let period = alert.period.clone();
        let claimed = match self
            .transaction(move |store| ledger::claim_alert_attempt(store, kind, &period))
        {
            Ok(Some(claimed)) => claimed,
            Ok(None) => return,
            Err(error) => return stage("alert_claim", error),
        };
        let sent = match (
            self.env.secret("PUSHOVER_APP_TOKEN"),
            self.env.secret("PUSHOVER_USER_KEY"),
        ) {
            (Ok(token), Ok(user)) => {
                let body = url::form_urlencoded::Serializer::new(String::new())
                    .append_pair("token", &token.to_string())
                    .append_pair("user", &user.to_string())
                    .append_pair("title", &title(self.lane))
                    .append_pair("message", &message(&claimed))
                    .finish();
                let headers = Headers::new();
                let request = headers
                    .set("content-type", "application/x-www-form-urlencoded")
                    .and_then(|_| {
                        let mut init = RequestInit::new();
                        init.with_method(Method::Post)
                            .with_headers(headers)
                            .with_body(Some(body.into()));
                        Request::new_with_init(PUSHOVER_URL, &init)
                    });
                match request {
                    Ok(request) => match Fetch::Request(request).send().await {
                        Ok(response) => (200..300).contains(&response.status_code()),
                        Err(_) => false,
                    },
                    Err(_) => false,
                }
            }
            _ => false,
        };
        if sent {
            let period = claimed.period.clone();
            if let Err(error) =
                self.transaction(move |store| ledger::mark_alert_sent(store, kind, &period))
            {
                stage("alert_record", error);
            }
        }
        console_log!(
            "{}",
            line(&AlertEvent {
                event: "trial_alert",
                kind: kind.as_str(),
                sent,
                attempts: claimed.attempts,
            })
        );
    }
}

fn transaction_on<T: 'static>(
    storage: &worker::Storage,
    mut store: SqlStore<ObjectSql>,
    operation: impl FnOnce(&mut SqlStore<ObjectSql>) -> StoreResult<T> + 'static,
) -> StoreResult<T> {
    let slot: Rc<RefCell<Option<StoreResult<T>>>> = Rc::new(RefCell::new(None));
    let out = slot.clone();
    let callback = Closure::once(move || -> std::result::Result<JsValue, JsValue> {
        let result = operation(&mut store);
        let failed = result.is_err();
        *out.borrow_mut() = Some(result);
        if failed {
            Err(JsValue::from_str("trial_ledger_rollback"))
        } else {
            Ok(JsValue::UNDEFINED)
        }
    });
    let raw: &JsValue = storage.as_raw().as_ref();
    let function = Reflect::get(raw, &JsValue::from_str("transactionSync"))
        .ok()
        .and_then(|method| method.dyn_into::<Function>().ok())
        .ok_or(StoreError::Storage)?;
    let call = function.call1(raw, callback.as_ref().unchecked_ref());
    drop(callback);
    let result = slot.borrow_mut().take();
    // Success needs both: the operation returned Ok and transactionSync
    // committed. A throw after a successful callback is a rollback.
    match (call, result) {
        (Ok(_), Some(Ok(value))) => Ok(value),
        (_, Some(Err(error))) => Err(error),
        _ => Err(StoreError::Storage),
    }
}

/// An absolute alarm time. workers-rs reads a bare `i64` as an offset from
/// now, so epoch milliseconds must go through a `Date`.
fn at_epoch_ms(epoch_ms: i64) -> ScheduledTime {
    ScheduledTime::new(worker::js_sys::Date::new(&JsValue::from_f64(
        epoch_ms as f64,
    )))
}

fn now_ms() -> i64 {
    i64::try_from(Date::now().as_millis()).unwrap_or(i64::MAX)
}

fn stage(stage: &'static str, error: StoreError) {
    console_log!(
        "{}",
        line(&StageEvent {
            event: "trial_ledger_error",
            stage,
            kind: error.as_str(),
        })
    );
}

fn unavailable(op: &'static str, error: StoreError) -> Result<Response> {
    stage(op, error);
    json_response(503, br#"{"error":"ledger_unavailable"}"#.to_vec())
}

fn json(status: u16, body: &impl Serialize) -> Result<Response> {
    match serde_json::to_vec(body) {
        Ok(body) => json_response(status, body),
        Err(_) => unavailable("encode", StoreError::Corrupt),
    }
}

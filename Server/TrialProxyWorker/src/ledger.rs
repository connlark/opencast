//! The trial accounting state machine: reserve before a window is forwarded,
//! settle after. One instance (the `TrialLedger` Durable Object) owns every
//! counter, so the monthly ceiling and the daily backstop are checked
//! against one serialized state. Every function takes `now` (Unix ms); none
//! awaits anything, so a Durable Object runs each one atomically.
//!
//! Money is integer micro-dollars. A reservation is the worst case Google's
//! documented limits allow for one window: the model's maximum input (a
//! prompt above it is rejected unbilled) at the input price plus the
//! bundle's maximum output (thinking included) at the output price, a
//! per-window constant; settlement only ever lowers it. Google's count of
//! the input is what the run bound, the daily caps and telemetry measure.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::bundle::Feature;
use crate::clock::{day_index, hour_index, month_key, MS_PER_DAY, MS_PER_HOUR, MS_PER_SECOND};
use crate::config::{cost_micros, LedgerConfig, Micros, Mode, Pricing, MAX_STORED_INTEGER};
use crate::provider::{SettleOutcome, Usage};

/// A reservation not settled within its call timeout plus this margin is
/// ambiguous: charged in full and no longer holding its locks.
pub const EXPIRY_MARGIN_MS: i64 = 60_000;
/// Provider-failure alert: at least this many failures, and at least this
/// share of forwards, over the last six hourly buckets.
pub const ALERT_WINDOW_HOURS: i64 = 6;
pub const ALERT_MIN_FAILURES: u64 = 5;
pub const ALERT_FAILURE_PERCENT: u64 = 20;
pub const ALERT_MAX_ATTEMPTS: u32 = 5;
pub const MIRROR_ALERT_CONSECUTIVE_FAILURES: i64 = 5;
/// A busy device is told to come back within this, not after the whole
/// lease: a settle usually frees the lock long before the lease ends.
pub const BUSY_RETRY_AFTER_MAX_SECONDS: u64 = 10;
const META_VERSION: &str = "version";
const META_MIRROR_FAILURES: &str = "mirror_consecutive_failures";

pub const RESERVATION_RETENTION_MS: i64 = 40 * MS_PER_DAY;
pub const RUN_RETENTION_MS: i64 = 45 * MS_PER_DAY;
pub const DAY_RETENTION_DAYS: i64 = 120;
pub const BEARER_DAY_RETENTION_DAYS: i64 = 7;
pub const PROVIDER_HOUR_RETENTION_HOURS: i64 = 48;
pub const ALERT_RETENTION_MS: i64 = 40 * MS_PER_DAY;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lane {
    AppAttest,
    Bearer,
}

impl Lane {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AppAttest => "app_attest",
            Self::Bearer => "bearer",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "app_attest" => Some(Self::AppAttest),
            "bearer" => Some(Self::Bearer),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReservationState {
    Open,
    Settled,
    Expired,
}

impl ReservationState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Settled => "settled",
            Self::Expired => "expired",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "open" => Some(Self::Open),
            "settled" => Some(Self::Settled),
            "expired" => Some(Self::Expired),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reservation {
    pub id: String,
    pub subject: String,
    pub lane: Lane,
    pub run_id: String,
    pub window_index: u16,
    pub feature: Feature,
    pub model: String,
    pub mode: Mode,
    pub month: String,
    /// The later month a reservation's deadline reaches into, if any: the
    /// provider may bill it there, so both months hold it.
    pub spill_month: Option<String>,
    pub day: i64,
    /// Google's count (the run bound's and the daily caps' quantity).
    pub input_tokens: u64,
    /// The input the money reservation covers: the model's documented
    /// maximum input from the price table.
    pub input_bound_tokens: u64,
    pub max_output_tokens: u32,
    /// Micro-dollars per million tokens, fixed at admission: the highest in
    /// force at any instant until the deadline.
    pub input_price: u64,
    pub output_price: u64,
    pub reserved_micros: Micros,
    /// What the reservation holds against its month: the reservation while
    /// open or expired, the settled amount once settled.
    pub charged_micros: Micros,
    pub state: ReservationState,
    pub outcome: Option<&'static str>,
    pub created_at: i64,
    pub deadline: i64,
    pub finalized_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Install {
    pub subject: String,
    pub trial_units_used: u32,
    pub open_runs: u32,
    pub version: u64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub subject: String,
    pub run_id: String,
    pub feature: Feature,
    pub windows: BTreeSet<u16>,
    pub reservations: u32,
    pub reserved_input_tokens: u64,
    pub charged_micros: Micros,
    pub unit_consumed: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub version: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Month {
    pub month: String,
    pub charged_micros: Micros,
    /// Reported usage beyond what its reservations held. Not part of any
    /// reservation's charge, but the ceiling gate counts it.
    pub overrun_micros: Micros,
    pub reservations: u64,
    pub paused_at: Option<i64>,
    pub version: u64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Day {
    pub day: i64,
    pub admitted: u64,
    pub input_tokens: u64,
    pub would_refuse_runs: u64,
    pub forwards: u64,
    pub provider_failures: u64,
    /// Reservations that reached their deadline without a settle.
    pub expired: u64,
    /// Settlements whose reported usage exceeded the reservation, and by how
    /// much in total. Input is reserved at the model's documented maximum
    /// and output at its cap, so this stays zero; anything else means a
    /// documented limit or the price table was wrong (it alerts).
    pub overruns: u64,
    pub overrun_micros: Micros,
    pub summary_logged: bool,
    pub version: u64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BearerDay {
    pub day: i64,
    pub subject: String,
    pub requests: u64,
    pub input_tokens: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderHour {
    pub hour: i64,
    pub forwards: u64,
    pub failures: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlertKind {
    Ceiling,
    Backstop,
    NoPrice,
    ProviderFailures,
    Mirror,
    Overrun,
}

impl AlertKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ceiling => "ceiling",
            Self::Backstop => "backstop",
            Self::NoPrice => "no_price",
            Self::ProviderFailures => "provider_failures",
            Self::Mirror => "mirror",
            Self::Overrun => "overrun",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        [
            Self::Ceiling,
            Self::Backstop,
            Self::NoPrice,
            Self::ProviderFailures,
            Self::Mirror,
            Self::Overrun,
        ]
        .into_iter()
        .find(|kind| kind.as_str() == value)
    }
}

/// One alert per kind and period (a month, a day, a six-hour window). The
/// two values are the numbers its message quotes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlertRecord {
    pub kind: AlertKind,
    pub period: String,
    pub sent: bool,
    pub attempts: u32,
    pub value_a: u64,
    pub value_b: u64,
    pub created_at: i64,
}

/// A row of the D1 mirror that changed since it was last written.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum MirrorKey {
    Install(String),
    Run(String, String),
    Month(String),
    Day(i64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreError {
    Storage,
    Corrupt,
    Range,
    /// A replayed admission that no longer matches an open reservation.
    Conflict,
}

impl StoreError {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Storage => "storage",
            Self::Corrupt => "corrupt",
            Self::Range => "range",
            Self::Conflict => "conflict",
        }
    }
}

pub type StoreResult<T> = Result<T, StoreError>;

/// What the state machine reads and writes. Implemented over the Durable
/// Object's SQL storage and, for tests, in memory and over SQLite.
pub trait LedgerStore {
    fn reservation(&self, id: &str) -> StoreResult<Option<Reservation>>;
    fn open_reservations(&self, subject: &str) -> StoreResult<Vec<Reservation>>;
    fn due_reservations(&self, now: i64, limit: usize) -> StoreResult<Vec<Reservation>>;
    fn earliest_open_deadline(&self) -> StoreResult<Option<i64>>;
    fn put_reservation(&mut self, reservation: &Reservation) -> StoreResult<()>;
    fn install(&self, subject: &str) -> StoreResult<Option<Install>>;
    fn put_install(&mut self, install: &Install) -> StoreResult<()>;
    fn run(&self, subject: &str, run_id: &str) -> StoreResult<Option<Run>>;
    fn put_run(&mut self, run: &Run) -> StoreResult<()>;
    fn month(&self, month: &str) -> StoreResult<Option<Month>>;
    fn put_month(&mut self, month: &Month) -> StoreResult<()>;
    fn day(&self, day: i64) -> StoreResult<Option<Day>>;
    fn put_day(&mut self, day: &Day) -> StoreResult<()>;
    fn unlogged_days_before(&self, day: i64) -> StoreResult<Vec<Day>>;
    fn bearer_day(&self, day: i64, subject: &str) -> StoreResult<Option<BearerDay>>;
    fn put_bearer_day(&mut self, day: &BearerDay) -> StoreResult<()>;
    fn provider_hours_since(&self, hour: i64) -> StoreResult<Vec<ProviderHour>>;
    fn put_provider_hour(&mut self, hour: &ProviderHour) -> StoreResult<()>;
    fn alert(&self, kind: AlertKind, period: &str) -> StoreResult<Option<AlertRecord>>;
    fn pending_alerts(&self) -> StoreResult<Vec<AlertRecord>>;
    fn put_alert(&mut self, alert: &AlertRecord) -> StoreResult<()>;
    fn meta(&self, key: &str) -> StoreResult<Option<i64>>;
    fn put_meta(&mut self, key: &str, value: i64) -> StoreResult<()>;
    fn mark_dirty(&mut self, key: &MirrorKey, version: u64) -> StoreResult<()>;
    fn dirty(&self, limit: usize) -> StoreResult<Vec<(MirrorKey, u64)>>;
    /// Clears a mark only if no later change moved its version.
    fn clear_dirty(&mut self, key: &MirrorKey, version: u64) -> StoreResult<()>;
    fn prune(&mut self, cutoffs: &PruneCutoffs) -> StoreResult<u64>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PruneCutoffs {
    pub reservations_finalized_before: i64,
    pub runs_updated_before: i64,
    pub days_before: i64,
    pub bearer_days_before: i64,
    pub provider_hours_before: i64,
    pub alerts_created_before: i64,
}

impl PruneCutoffs {
    pub fn at(now: i64) -> Self {
        Self {
            reservations_finalized_before: now - RESERVATION_RETENTION_MS,
            runs_updated_before: now - RUN_RETENTION_MS,
            days_before: day_index(now) - DAY_RETENTION_DAYS,
            bearer_days_before: day_index(now) - BEARER_DAY_RETENTION_DAYS,
            provider_hours_before: hour_index(now) - PROVIDER_HOUR_RETENTION_HOURS,
            alerts_created_before: now - ALERT_RETENTION_MS,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdmitRequest {
    pub reservation_id: String,
    pub subject: String,
    pub lane: Lane,
    pub run_id: String,
    pub window_index: u16,
    pub feature: Feature,
    pub model: String,
    /// Google's count of the rebuilt body (never an estimate): what the run
    /// bound, the daily caps and telemetry measure. Never what is reserved.
    pub input_tokens: u64,
    pub max_output_tokens: u32,
    /// How long the Worker may forward for; the lock outlives it by
    /// `EXPIRY_MARGIN_MS` so a settle can still land.
    pub forward_budget_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefusalCode {
    TrialBusy,
    TrialExhausted,
    TrialRunBound,
    TrialPaused,
    BearerLimited,
    RequestInvalid,
}

impl RefusalCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TrialBusy => "trial_busy",
            Self::TrialExhausted => "trial_exhausted",
            Self::TrialRunBound => "trial_run_bound",
            Self::TrialPaused => "trial_paused",
            Self::BearerLimited => "bearer_limited",
            Self::RequestInvalid => "request_invalid",
        }
    }
}

/// Why a window was paused, for telemetry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PauseReason {
    Ceiling,
    Backstop,
    NoPrice,
}

impl PauseReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ceiling => "ceiling",
            Self::Backstop => "backstop",
            Self::NoPrice => "no_price",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum Decision {
    Admitted {
        reservation_id: String,
        reserved_micros: Micros,
        mode: Mode,
        replayed: bool,
    },
    Refused {
        code: RefusalCode,
        mode: Mode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        retry_after_seconds: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pause: Option<PauseReason>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdmitResult {
    pub decision: Decision,
    /// Alerts this admission raised (already recorded as pending).
    pub alerts: Vec<AlertRecord>,
    pub expired: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum SettleResult {
    Settled {
        reserved_micros: Micros,
        charged_micros: Micros,
        /// Reported usage beyond the reservation (charged to the month's
        /// overrun, not to the reservation).
        overrun_micros: Micros,
    },
    AlreadyFinal {
        state: ReservationState,
        reserved_micros: Micros,
        charged_micros: Micros,
    },
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettleEffects {
    pub result: SettleResult,
    pub alerts: Vec<AlertRecord>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusView {
    pub mode: Mode,
    pub units_remaining: u32,
    pub month_paused: bool,
}

fn bump<S: LedgerStore>(store: &mut S, key: MirrorKey) -> StoreResult<u64> {
    let version = store.meta(META_VERSION)?.unwrap_or(0).saturating_add(1);
    store.put_meta(META_VERSION, version)?;
    let version = u64::try_from(version).map_err(|_| StoreError::Range)?;
    store.mark_dirty(&key, version)?;
    Ok(version)
}

fn month_of<S: LedgerStore>(store: &S, month: &str, now: i64) -> StoreResult<Month> {
    Ok(store.month(month)?.unwrap_or(Month {
        month: month.to_string(),
        charged_micros: 0,
        overrun_micros: 0,
        reservations: 0,
        paused_at: None,
        version: 0,
        updated_at: now,
    }))
}

fn day_of<S: LedgerStore>(store: &S, day: i64, now: i64) -> StoreResult<Day> {
    Ok(store.day(day)?.unwrap_or(Day {
        day,
        admitted: 0,
        input_tokens: 0,
        would_refuse_runs: 0,
        forwards: 0,
        provider_failures: 0,
        expired: 0,
        overruns: 0,
        overrun_micros: 0,
        summary_logged: false,
        version: 0,
        updated_at: now,
    }))
}

fn write_month<S: LedgerStore>(store: &mut S, mut month: Month, now: i64) -> StoreResult<()> {
    month.version = bump(store, MirrorKey::Month(month.month.clone()))?;
    month.updated_at = now;
    store.put_month(&month)
}

fn write_day<S: LedgerStore>(store: &mut S, mut day: Day, now: i64) -> StoreResult<()> {
    day.version = bump(store, MirrorKey::Day(day.day))?;
    day.updated_at = now;
    store.put_day(&day)
}

fn write_run<S: LedgerStore>(store: &mut S, mut run: Run, now: i64) -> StoreResult<()> {
    run.version = bump(
        store,
        MirrorKey::Run(run.subject.clone(), run.run_id.clone()),
    )?;
    run.updated_at = now;
    store.put_run(&run)
}

fn write_install<S: LedgerStore>(store: &mut S, mut install: Install, now: i64) -> StoreResult<()> {
    install.version = bump(store, MirrorKey::Install(install.subject.clone()))?;
    install.updated_at = now;
    store.put_install(&install)
}

/// Raises an alert once per (kind, period). Returns it when new.
fn raise<S: LedgerStore>(
    store: &mut S,
    kind: AlertKind,
    period: String,
    now: i64,
    value_a: u64,
    value_b: u64,
) -> StoreResult<Option<AlertRecord>> {
    if store.alert(kind, &period)?.is_some() {
        return Ok(None);
    }
    let alert = AlertRecord {
        kind,
        period,
        sent: false,
        attempts: 0,
        value_a,
        value_b,
        created_at: now,
    };
    store.put_alert(&alert)?;
    Ok(Some(alert))
}

fn expire<S: LedgerStore>(
    store: &mut S,
    mut reservation: Reservation,
    now: i64,
) -> StoreResult<()> {
    // The charge stays the whole reservation: the provider may have billed
    // a dispatch whose answer never reached a settle.
    reservation.state = ReservationState::Expired;
    reservation.charged_micros = reservation.reserved_micros;
    reservation.outcome = Some("expired");
    reservation.finalized_at = Some(now);
    store.put_reservation(&reservation)?;
    let mut today = day_of(store, day_index(now), now)?;
    today.expired += 1;
    write_day(store, today, now)
}

fn retry_after_seconds(deadline: i64, now: i64) -> u64 {
    let millis = deadline.saturating_sub(now).max(0) as u64;
    millis
        .div_ceil(MS_PER_SECOND as u64)
        .clamp(1, BUSY_RETRY_AFTER_MAX_SECONDS)
}

/// A replay matches only the request that created the reservation, and only
/// while that reservation may still be forwarded.
fn replay_matches(existing: &Reservation, request: &AdmitRequest, now: i64) -> bool {
    existing.state == ReservationState::Open
        && existing.deadline > now
        && existing.subject == request.subject
        && existing.lane == request.lane
        && existing.run_id == request.run_id
        && existing.window_index == request.window_index
        && existing.feature == request.feature
        && existing.model == request.model
        && existing.input_tokens == request.input_tokens
        && existing.max_output_tokens == request.max_output_tokens
}

pub fn admit<S: LedgerStore>(
    store: &mut S,
    config: &LedgerConfig,
    now: i64,
    request: &AdmitRequest,
) -> StoreResult<AdmitResult> {
    let mode = config.mode_at(now);
    if let Some(existing) = store.reservation(&request.reservation_id)? {
        // A retried exchange whose first try committed: same decision, no
        // second reservation, and never a licence to forward a reservation
        // that is already final.
        if !replay_matches(&existing, request, now) {
            return Err(StoreError::Conflict);
        }
        // A replay forwards only under the terms its settlement will charge:
        // the stored rates and amount must be exactly what this version
        // reserves for the same window now (an earlier version's smaller
        // amount, or a price row edited in place, fails it). Refused, the
        // reservation stays as it is and expires as usual.
        let honoured = config
            .prices
            .max_over(&existing.model, existing.created_at, existing.deadline)
            .is_some_and(|pricing| {
                pricing.input_micros_per_million == existing.input_price
                    && pricing.output_micros_per_million == existing.output_price
                    && window_reservation(&pricing, existing.max_output_tokens)
                        == existing.reserved_micros
            });
        if !honoured {
            return Err(StoreError::Conflict);
        }
        return Ok(AdmitResult {
            decision: Decision::Admitted {
                reservation_id: existing.id,
                reserved_micros: existing.reserved_micros,
                mode: existing.mode,
                replayed: true,
            },
            alerts: Vec::new(),
            expired: 0,
        });
    }
    let refused = |code, retry_after_seconds, pause| AdmitResult {
        decision: Decision::Refused {
            code,
            mode,
            retry_after_seconds,
            pause,
        },
        alerts: Vec::new(),
        expired: 0,
    };

    let mut expired = 0;
    let mut open = Vec::new();
    for reservation in store.open_reservations(&request.subject)? {
        if reservation.deadline <= now {
            expire(store, reservation, now)?;
            expired += 1;
        } else {
            open.push(reservation);
        }
    }
    let blocking = open
        .iter()
        .filter(|reservation| match request.lane {
            // One window in flight per run and one run in flight per install.
            Lane::AppAttest => true,
            Lane::Bearer => reservation.run_id == request.run_id,
        })
        .map(|reservation| reservation.deadline)
        .min();
    if let Some(deadline) = blocking {
        let mut result = refused(
            RefusalCode::TrialBusy,
            Some(retry_after_seconds(deadline, now)),
            None,
        );
        result.expired = expired;
        return Ok(result);
    }

    let run = store.run(&request.subject, &request.run_id)?;
    if run
        .as_ref()
        .is_some_and(|run| run.feature != request.feature)
    {
        return Ok(AdmitResult {
            expired,
            ..refused(RefusalCode::RequestInvalid, None, None)
        });
    }
    let install = match request.lane {
        Lane::AppAttest => Some(store.install(&request.subject)?.unwrap_or(Install {
            subject: request.subject.clone(),
            trial_units_used: 0,
            open_runs: 0,
            version: 0,
            updated_at: now,
        })),
        Lane::Bearer => None,
    };
    let new_run = run.is_none();
    // In trial mode every run without a consumed unit takes one, including a
    // run started while open: run ids seeded before the flip are not free
    // after it.
    let needs_unit = mode == Mode::Trial
        && request.lane == Lane::AppAttest
        && run.as_ref().is_none_or(|run| !run.unit_consumed);
    if needs_unit
        && install
            .as_ref()
            .is_some_and(|install| install.trial_units_used >= config.lifetime_units)
    {
        return Ok(AdmitResult {
            expired,
            ..refused(RefusalCode::TrialExhausted, None, None)
        });
    }
    let windows = run.as_ref().map(|run| run.windows.len()).unwrap_or(0);
    let has_window = run
        .as_ref()
        .is_some_and(|run| run.windows.contains(&request.window_index));
    let reserved_input = run
        .as_ref()
        .map(|run| run.reserved_input_tokens)
        .unwrap_or(0);
    if (!has_window && windows >= config.run_max_windows as usize)
        || reserved_input.saturating_add(request.input_tokens) > config.run_max_input_tokens
    {
        return Ok(AdmitResult {
            expired,
            ..refused(RefusalCode::TrialRunBound, None, None)
        });
    }

    let day = day_index(now);
    let deadline = lock_deadline(now, request.forward_budget_ms);
    let Some(pricing) = config.prices.max_over(&request.model, now, deadline) else {
        let alerts = raise(store, AlertKind::NoPrice, format!("d{day}"), now, 0, 0)?
            .into_iter()
            .collect();
        return Ok(AdmitResult {
            alerts,
            expired,
            ..refused(RefusalCode::TrialPaused, None, Some(PauseReason::NoPrice))
        });
    };
    // A prompt above the model's limit is one Google would refuse: refuse
    // it here, before anything is reserved.
    if request.input_tokens > pricing.max_input_tokens {
        return Ok(AdmitResult {
            expired,
            ..refused(RefusalCode::TrialRunBound, None, None)
        });
    }
    let (input_price, output_price) = (
        pricing.input_micros_per_million,
        pricing.output_micros_per_million,
    );
    let reserved = window_reservation(&pricing, request.max_output_tokens);

    let MoneyGate {
        mut month,
        mut spill,
        failed,
    } = money_gate(store, config, now, deadline, reserved)?;
    let month_key = month.month.clone();
    let spill_key = spill.as_ref().map(|spill| spill.month.clone());
    let mut today = day_of(store, day, now)?;
    if let Some(failed) = failed {
        // The alert names the month that did not fit (the admission month,
        // or the next month a straddling window would reach into).
        let mut failed_month = match failed {
            GateFailure::Month => month,
            GateFailure::Spill => spill.take().ok_or(StoreError::Corrupt)?,
        };
        let failed_spent = failed_month
            .charged_micros
            .saturating_add(failed_month.overrun_micros);
        let alerts: Vec<_> = raise(
            store,
            AlertKind::Ceiling,
            failed_month.month.clone(),
            now,
            failed_spent,
            config.ceiling_micros,
        )?
        .into_iter()
        .collect();
        if failed_month.paused_at.is_none() {
            failed_month.paused_at = Some(now);
            write_month(store, failed_month, now)?;
        }
        return Ok(AdmitResult {
            alerts,
            expired,
            ..refused(RefusalCode::TrialPaused, None, Some(PauseReason::Ceiling))
        });
    }
    if mode == Mode::Open
        && (today.admitted.saturating_add(1) > config.open_daily_requests
            || today.input_tokens.saturating_add(request.input_tokens)
                > config.open_daily_input_tokens)
    {
        let alerts = raise(
            store,
            AlertKind::Backstop,
            format!("d{day}"),
            now,
            today.admitted,
            today.input_tokens,
        )?
        .into_iter()
        .collect();
        return Ok(AdmitResult {
            alerts,
            expired,
            ..refused(RefusalCode::TrialPaused, None, Some(PauseReason::Backstop))
        });
    }
    let bearer_day = match request.lane {
        Lane::Bearer => {
            let bearer_day = store
                .bearer_day(day, &request.subject)?
                .unwrap_or(BearerDay {
                    day,
                    subject: request.subject.clone(),
                    requests: 0,
                    input_tokens: 0,
                });
            if bearer_day.requests.saturating_add(1) > config.bearer_daily_requests
                || bearer_day.input_tokens.saturating_add(request.input_tokens)
                    > config.bearer_daily_input_tokens
            {
                return Ok(AdmitResult {
                    expired,
                    ..refused(RefusalCode::BearerLimited, None, None)
                });
            }
            Some(bearer_day)
        }
        Lane::AppAttest => None,
    };

    store.put_reservation(&Reservation {
        id: request.reservation_id.clone(),
        subject: request.subject.clone(),
        lane: request.lane,
        run_id: request.run_id.clone(),
        window_index: request.window_index,
        feature: request.feature,
        model: request.model.clone(),
        mode,
        month: month_key,
        spill_month: spill_key,
        day,
        input_tokens: request.input_tokens,
        input_bound_tokens: pricing.max_input_tokens,
        max_output_tokens: request.max_output_tokens,
        input_price,
        output_price,
        reserved_micros: reserved,
        charged_micros: reserved,
        state: ReservationState::Open,
        outcome: None,
        created_at: now,
        deadline,
        finalized_at: None,
    })?;
    month.charged_micros = month.charged_micros.saturating_add(reserved);
    month.reservations += 1;
    write_month(store, month, now)?;
    if let Some(mut spill) = spill.take() {
        spill.charged_micros = spill.charged_micros.saturating_add(reserved);
        write_month(store, spill, now)?;
    }
    today.admitted += 1;
    today.input_tokens = today.input_tokens.saturating_add(request.input_tokens);
    let mut run = run.unwrap_or(Run {
        subject: request.subject.clone(),
        run_id: request.run_id.clone(),
        feature: request.feature,
        windows: BTreeSet::new(),
        reservations: 0,
        reserved_input_tokens: 0,
        charged_micros: 0,
        unit_consumed: false,
        created_at: now,
        updated_at: now,
        version: 0,
    });
    run.windows.insert(request.window_index);
    run.reservations += 1;
    run.reserved_input_tokens = run
        .reserved_input_tokens
        .saturating_add(request.input_tokens);
    run.charged_micros = run.charged_micros.saturating_add(reserved);
    if let Some(mut install) = install {
        let mut changed = false;
        if needs_unit {
            run.unit_consumed = true;
            install.trial_units_used += 1;
            changed = true;
        }
        if mode == Mode::Open && new_run {
            // The notice-period signal: this run would have been refused
            // had trial mode been on.
            if install.open_runs >= config.lifetime_units {
                today.would_refuse_runs += 1;
            }
            install.open_runs = install.open_runs.saturating_add(1);
            changed = true;
        }
        if changed {
            write_install(store, install, now)?;
        }
    }
    write_run(store, run, now)?;
    write_day(store, today, now)?;
    if let Some(mut bearer_day) = bearer_day {
        bearer_day.requests += 1;
        bearer_day.input_tokens = bearer_day.input_tokens.saturating_add(request.input_tokens);
        store.put_bearer_day(&bearer_day)?;
    }
    Ok(AdmitResult {
        decision: Decision::Admitted {
            reservation_id: request.reservation_id.clone(),
            reserved_micros: reserved,
            mode,
            replayed: false,
        },
        alerts: Vec::new(),
        expired,
    })
}

/// The stored label of a settlement (a closed set).
pub fn outcome_label(outcome: &SettleOutcome) -> &'static str {
    match outcome {
        SettleOutcome::Usage { .. } => "usage",
        SettleOutcome::Rejected { .. } => "rejected",
        SettleOutcome::Ambiguous { class, .. } => class.as_str(),
        SettleOutcome::NotDispatched => "not_dispatched",
    }
}

pub fn settle<S: LedgerStore>(
    store: &mut S,
    now: i64,
    reservation_id: &str,
    outcome: &SettleOutcome,
) -> StoreResult<SettleEffects> {
    let Some(mut reservation) = store.reservation(reservation_id)? else {
        return Ok(SettleEffects {
            result: SettleResult::Unknown,
            alerts: Vec::new(),
        });
    };
    if reservation.state == ReservationState::Open && reservation.deadline <= now {
        // Past its deadline the reservation is ambiguous whatever arrives
        // now: no reservation is released retroactively.
        expire(store, reservation.clone(), now)?;
        reservation = store
            .reservation(reservation_id)?
            .ok_or(StoreError::Corrupt)?;
    }
    if reservation.state != ReservationState::Open {
        return Ok(SettleEffects {
            result: SettleResult::AlreadyFinal {
                state: reservation.state,
                reserved_micros: reservation.reserved_micros,
                charged_micros: reservation.charged_micros,
            },
            alerts: Vec::new(),
        });
    }
    let reserved = reservation.reserved_micros;
    let (charged, overrun_micros) = match outcome {
        SettleOutcome::Usage {
            usage:
                Usage {
                    prompt_tokens,
                    output_tokens,
                },
            ..
        } => {
            let cost = cost_micros(*prompt_tokens, reservation.input_price)
                .saturating_add(cost_micros(*output_tokens, reservation.output_price));
            (cost.min(reserved), cost.saturating_sub(reserved))
        }
        SettleOutcome::Rejected { .. } | SettleOutcome::NotDispatched => (0, 0),
        SettleOutcome::Ambiguous { .. } => (reserved, 0),
    };
    let released = reserved - charged;
    reservation.state = ReservationState::Settled;
    reservation.charged_micros = charged;
    reservation.outcome = Some(outcome_label(outcome));
    reservation.finalized_at = Some(now);
    store.put_reservation(&reservation)?;
    let mut alerts = Vec::new();
    if released > 0 || overrun_micros > 0 {
        let months =
            std::iter::once(reservation.month.clone()).chain(reservation.spill_month.clone());
        for key in months {
            let mut month = month_of(store, &key, now)?;
            month.charged_micros = month.charged_micros.saturating_sub(released);
            let overrun = month.overrun_micros.saturating_add(overrun_micros);
            if overrun > MAX_STORED_INTEGER {
                // More than storage can hold: keep the accounting, saturated,
                // and pause the month (the gate refuses a full month in
                // either mode) rather than lose the settlement.
                month.overrun_micros = MAX_STORED_INTEGER;
                month.paused_at.get_or_insert(now);
                alerts.extend(raise(
                    store,
                    AlertKind::Ceiling,
                    key.clone(),
                    now,
                    MAX_STORED_INTEGER,
                    MAX_STORED_INTEGER,
                )?);
            } else {
                month.overrun_micros = overrun;
            }
            write_month(store, month, now)?;
        }
        if let Some(mut run) = store.run(&reservation.subject, &reservation.run_id)? {
            run.charged_micros = run.charged_micros.saturating_sub(released);
            write_run(store, run, now)?;
        }
    }

    if overrun_micros > 0 {
        // Usage beyond the reservation means a documented limit behind it
        // failed: say so the day it happens.
        alerts.extend(raise(
            store,
            AlertKind::Overrun,
            format!("d{}", day_index(now)),
            now,
            overrun_micros.min(MAX_STORED_INTEGER),
            reserved,
        )?);
    }
    if outcome.dispatched() {
        let failure = u64::from(outcome.provider_failure());
        let mut today = day_of(store, day_index(now), now)?;
        today.forwards += 1;
        today.provider_failures += failure;
        if overrun_micros > 0 {
            today.overruns += 1;
            today.overrun_micros = today
                .overrun_micros
                .saturating_add(overrun_micros)
                .min(MAX_STORED_INTEGER);
        }
        write_day(store, today, now)?;
        let hour = hour_index(now);
        let since = hour - (ALERT_WINDOW_HOURS - 1);
        let mut hours = store.provider_hours_since(since)?;
        let mut current = hours
            .iter()
            .find(|bucket| bucket.hour == hour)
            .copied()
            .unwrap_or(ProviderHour {
                hour,
                forwards: 0,
                failures: 0,
            });
        current.forwards += 1;
        current.failures += failure;
        store.put_provider_hour(&current)?;
        hours.retain(|bucket| bucket.hour != hour);
        hours.push(current);
        let forwards: u64 = hours.iter().map(|bucket| bucket.forwards).sum();
        let failures: u64 = hours.iter().map(|bucket| bucket.failures).sum();
        if failure == 1
            && failures >= ALERT_MIN_FAILURES
            && failures * 100 >= forwards * ALERT_FAILURE_PERCENT
        {
            let window = hour.div_euclid(ALERT_WINDOW_HOURS);
            alerts.extend(raise(
                store,
                AlertKind::ProviderFailures,
                format!("h{window}"),
                now,
                failures,
                forwards,
            )?);
        }
    }
    Ok(SettleEffects {
        result: SettleResult::Settled {
            reserved_micros: reserved,
            charged_micros: charged,
            overrun_micros,
        },
        alerts,
    })
}

/// Expires every open reservation past its deadline (at most `limit`).
pub fn expire_due<S: LedgerStore>(store: &mut S, now: i64, limit: usize) -> StoreResult<u32> {
    let due = store.due_reservations(now, limit)?;
    let count = due.len() as u32;
    for reservation in due {
        expire(store, reservation, now)?;
    }
    Ok(count)
}

/// `month_paused` is the ceiling gate's answer for the cheaper window
/// (`smallest_max_output_tokens`, locked for `forward_budget_ms`) admitted
/// now: true exactly when admission would refuse it for the ceiling (or
/// for a missing price).
#[allow(clippy::too_many_arguments)]
pub fn status<S: LedgerStore>(
    store: &S,
    config: &LedgerConfig,
    now: i64,
    subject: &str,
    lane: Lane,
    model: &str,
    smallest_max_output_tokens: u32,
    forward_budget_ms: u64,
) -> StoreResult<StatusView> {
    let mode = config.mode_at(now);
    let used = match lane {
        Lane::AppAttest => store
            .install(subject)?
            .map(|install| install.trial_units_used)
            .unwrap_or(0),
        Lane::Bearer => 0,
    };
    // The admission gate's own arithmetic for that window now: its price
    // interval and months run to the deadline its admission would set.
    let deadline = lock_deadline(now, forward_budget_ms);
    let month_paused = match config.prices.max_over(model, now, deadline) {
        None => true,
        Some(pricing) => {
            let reserved = window_reservation(&pricing, smallest_max_output_tokens);
            money_gate(store, config, now, deadline, reserved)?
                .failed
                .is_some()
        }
    };
    Ok(StatusView {
        mode,
        units_remaining: config.lifetime_units.saturating_sub(used),
        month_paused,
    })
}

/// When a window admitted at `now` with `forward_budget_ms` stops holding
/// its locks: the forward budget plus `EXPIRY_MARGIN_MS`.
fn lock_deadline(now: i64, forward_budget_ms: u64) -> i64 {
    now.saturating_add(i64::try_from(forward_budget_ms).unwrap_or(i64::MAX))
        .saturating_add(EXPIRY_MARGIN_MS)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GateFailure {
    /// The admission month (trial mode) has no room.
    Month,
    /// A later month the lock reaches into (trial mode there) has no room.
    Spill,
}

struct MoneyGate {
    month: Month,
    spill: Option<Month>,
    failed: Option<GateFailure>,
}

/// The ceiling gate for one window admitted at `now`, locked until
/// `deadline`, reserving `reserved`: the months it is charged to and which
/// of them, if any, it does not fit. Admission and `month_paused` both ask
/// this, so status says paused exactly when admission would refuse.
fn money_gate<S: LedgerStore>(
    store: &S,
    config: &LedgerConfig,
    now: i64,
    deadline: i64,
    reserved: Micros,
) -> StoreResult<MoneyGate> {
    let month = month_of(store, &month_key(now), now)?;
    let spill = match Some(month_key(deadline)).filter(|key| *key != month.month) {
        Some(key) => Some(month_of(store, &key, now)?),
        None => None,
    };
    let spent = |month: &Month| {
        month
            .charged_micros
            .saturating_add(month.overrun_micros)
            .saturating_add(reserved)
    };
    let over_ceiling = |month: &Month| spent(month) > config.ceiling_micros;
    // In either mode, a month whose amounts storage could not hold (one
    // saturated by an overflowing settlement) takes nothing more.
    let over_store = |month: &Month| spent(month) > MAX_STORED_INTEGER;
    let failed =
        if (config.mode_at(now) == Mode::Trial && over_ceiling(&month)) || over_store(&month) {
            Some(GateFailure::Month)
        } else if spill.as_ref().is_some_and(|spill| {
            (config.mode_at(deadline) == Mode::Trial && over_ceiling(spill)) || over_store(spill)
        }) {
            // A reservation reaching into a trial-mode month must fit that
            // month too.
            Some(GateFailure::Spill)
        } else {
            None
        };
    Ok(MoneyGate {
        month,
        spill,
        failed,
    })
}

/// One window's reservation: the model's documented maximum input at the
/// input price plus `max_output_tokens` at the output price.
pub fn window_reservation(pricing: &Pricing, max_output_tokens: u32) -> Micros {
    cost_micros(pricing.max_input_tokens, pricing.input_micros_per_million).saturating_add(
        cost_micros(
            u64::from(max_output_tokens),
            pricing.output_micros_per_million,
        ),
    )
}

/// The status a lane answers before trial mode starts, without the object:
/// every install has its full lifetime count and nothing is paused.
pub fn open_mode_status(config: &LedgerConfig) -> StatusView {
    StatusView {
        mode: Mode::Open,
        units_remaining: config.lifetime_units,
        month_paused: false,
    }
}

/// Closed UTC days whose summary line has not been logged yet; marks them.
pub fn take_day_summaries<S: LedgerStore>(store: &mut S, now: i64) -> StoreResult<Vec<Day>> {
    let days = store.unlogged_days_before(day_index(now))?;
    for day in &days {
        let mut logged = day.clone();
        logged.summary_logged = true;
        write_day(store, logged, now)?;
    }
    Ok(days)
}

pub fn prune<S: LedgerStore>(store: &mut S, now: i64) -> StoreResult<u64> {
    store.prune(&PruneCutoffs::at(now))
}

/// Claims one send attempt before the send, so an interrupted send is
/// counted and the record stops being retried after `ALERT_MAX_ATTEMPTS`.
/// `None` when the alert is already sent or out of attempts. Delivery is
/// at least once: a send whose success was not recorded can repeat.
pub fn claim_alert_attempt<S: LedgerStore>(
    store: &mut S,
    kind: AlertKind,
    period: &str,
) -> StoreResult<Option<AlertRecord>> {
    let Some(mut alert) = store.alert(kind, period)? else {
        return Ok(None);
    };
    if alert.sent || alert.attempts >= ALERT_MAX_ATTEMPTS {
        return Ok(None);
    }
    alert.attempts += 1;
    store.put_alert(&alert)?;
    Ok(Some(alert))
}

pub fn mark_alert_sent<S: LedgerStore>(
    store: &mut S,
    kind: AlertKind,
    period: &str,
) -> StoreResult<()> {
    if let Some(mut alert) = store.alert(kind, period)? {
        alert.sent = true;
        store.put_alert(&alert)?;
    }
    Ok(())
}

/// Alerts still owed a send.
pub fn alerts_to_send<S: LedgerStore>(store: &S) -> StoreResult<Vec<AlertRecord>> {
    Ok(store
        .pending_alerts()?
        .into_iter()
        .filter(|alert| alert.attempts < ALERT_MAX_ATTEMPTS)
        .collect())
}

/// Counts a mirror flush; the fifth consecutive failure raises the mirror
/// alert (once per UTC day).
pub fn record_mirror_flush<S: LedgerStore>(
    store: &mut S,
    now: i64,
    ok: bool,
) -> StoreResult<(i64, Option<AlertRecord>)> {
    let failures = if ok {
        0
    } else {
        store
            .meta(META_MIRROR_FAILURES)?
            .unwrap_or(0)
            .saturating_add(1)
    };
    store.put_meta(META_MIRROR_FAILURES, failures)?;
    let alert = if failures >= MIRROR_ALERT_CONSECUTIVE_FAILURES {
        raise(
            store,
            AlertKind::Mirror,
            format!("d{}", day_index(now)),
            now,
            failures as u64,
            0,
        )?
    } else {
        None
    };
    Ok((failures, alert))
}

/// The next alarm: the earliest open deadline, at most an hour away.
pub fn next_alarm<S: LedgerStore>(store: &S, now: i64) -> StoreResult<i64> {
    let hourly = now + MS_PER_HOUR;
    Ok(store
        .earliest_open_deadline()?
        .map(|deadline| deadline.clamp(now + MS_PER_SECOND, hourly))
        .unwrap_or(hourly))
}

/// An in-memory store for tests and property checks.
#[derive(Debug, Default, Clone)]
pub struct MemoryStore {
    pub reservations: BTreeMap<String, Reservation>,
    pub installs: BTreeMap<String, Install>,
    pub runs: BTreeMap<(String, String), Run>,
    pub months: BTreeMap<String, Month>,
    pub days: BTreeMap<i64, Day>,
    pub bearer_days: BTreeMap<(i64, String), BearerDay>,
    pub provider_hours: BTreeMap<i64, ProviderHour>,
    pub alerts: BTreeMap<(AlertKind, String), AlertRecord>,
    pub meta: BTreeMap<String, i64>,
    pub dirty: BTreeMap<MirrorKey, u64>,
}

impl LedgerStore for MemoryStore {
    fn reservation(&self, id: &str) -> StoreResult<Option<Reservation>> {
        Ok(self.reservations.get(id).cloned())
    }

    fn open_reservations(&self, subject: &str) -> StoreResult<Vec<Reservation>> {
        Ok(self
            .reservations
            .values()
            .filter(|r| r.subject == subject && r.state == ReservationState::Open)
            .cloned()
            .collect())
    }

    fn due_reservations(&self, now: i64, limit: usize) -> StoreResult<Vec<Reservation>> {
        let mut due: Vec<_> = self
            .reservations
            .values()
            .filter(|r| r.state == ReservationState::Open && r.deadline <= now)
            .cloned()
            .collect();
        due.sort_by_key(|r| r.deadline);
        due.truncate(limit);
        Ok(due)
    }

    fn earliest_open_deadline(&self) -> StoreResult<Option<i64>> {
        Ok(self
            .reservations
            .values()
            .filter(|r| r.state == ReservationState::Open)
            .map(|r| r.deadline)
            .min())
    }

    fn put_reservation(&mut self, reservation: &Reservation) -> StoreResult<()> {
        self.reservations
            .insert(reservation.id.clone(), reservation.clone());
        Ok(())
    }

    fn install(&self, subject: &str) -> StoreResult<Option<Install>> {
        Ok(self.installs.get(subject).cloned())
    }

    fn put_install(&mut self, install: &Install) -> StoreResult<()> {
        self.installs
            .insert(install.subject.clone(), install.clone());
        Ok(())
    }

    fn run(&self, subject: &str, run_id: &str) -> StoreResult<Option<Run>> {
        Ok(self
            .runs
            .get(&(subject.to_string(), run_id.to_string()))
            .cloned())
    }

    fn put_run(&mut self, run: &Run) -> StoreResult<()> {
        self.runs
            .insert((run.subject.clone(), run.run_id.clone()), run.clone());
        Ok(())
    }

    fn month(&self, month: &str) -> StoreResult<Option<Month>> {
        Ok(self.months.get(month).cloned())
    }

    fn put_month(&mut self, month: &Month) -> StoreResult<()> {
        self.months.insert(month.month.clone(), month.clone());
        Ok(())
    }

    fn day(&self, day: i64) -> StoreResult<Option<Day>> {
        Ok(self.days.get(&day).cloned())
    }

    fn put_day(&mut self, day: &Day) -> StoreResult<()> {
        self.days.insert(day.day, day.clone());
        Ok(())
    }

    fn unlogged_days_before(&self, day: i64) -> StoreResult<Vec<Day>> {
        Ok(self
            .days
            .values()
            .filter(|d| d.day < day && !d.summary_logged)
            .cloned()
            .collect())
    }

    fn bearer_day(&self, day: i64, subject: &str) -> StoreResult<Option<BearerDay>> {
        Ok(self.bearer_days.get(&(day, subject.to_string())).cloned())
    }

    fn put_bearer_day(&mut self, day: &BearerDay) -> StoreResult<()> {
        self.bearer_days
            .insert((day.day, day.subject.clone()), day.clone());
        Ok(())
    }

    fn provider_hours_since(&self, hour: i64) -> StoreResult<Vec<ProviderHour>> {
        Ok(self.provider_hours.range(hour..).map(|(_, h)| *h).collect())
    }

    fn put_provider_hour(&mut self, hour: &ProviderHour) -> StoreResult<()> {
        self.provider_hours.insert(hour.hour, *hour);
        Ok(())
    }

    fn alert(&self, kind: AlertKind, period: &str) -> StoreResult<Option<AlertRecord>> {
        Ok(self.alerts.get(&(kind, period.to_string())).cloned())
    }

    fn pending_alerts(&self) -> StoreResult<Vec<AlertRecord>> {
        Ok(self.alerts.values().filter(|a| !a.sent).cloned().collect())
    }

    fn put_alert(&mut self, alert: &AlertRecord) -> StoreResult<()> {
        self.alerts
            .insert((alert.kind, alert.period.clone()), alert.clone());
        Ok(())
    }

    fn meta(&self, key: &str) -> StoreResult<Option<i64>> {
        Ok(self.meta.get(key).copied())
    }

    fn put_meta(&mut self, key: &str, value: i64) -> StoreResult<()> {
        self.meta.insert(key.to_string(), value);
        Ok(())
    }

    fn mark_dirty(&mut self, key: &MirrorKey, version: u64) -> StoreResult<()> {
        self.dirty.insert(key.clone(), version);
        Ok(())
    }

    fn dirty(&self, limit: usize) -> StoreResult<Vec<(MirrorKey, u64)>> {
        Ok(self
            .dirty
            .iter()
            .take(limit)
            .map(|(k, v)| (k.clone(), *v))
            .collect())
    }

    fn clear_dirty(&mut self, key: &MirrorKey, version: u64) -> StoreResult<()> {
        if self.dirty.get(key) == Some(&version) {
            self.dirty.remove(key);
        }
        Ok(())
    }

    fn prune(&mut self, cutoffs: &PruneCutoffs) -> StoreResult<u64> {
        let before = self.reservations.len()
            + self.runs.len()
            + self.days.len()
            + self.bearer_days.len()
            + self.provider_hours.len()
            + self.alerts.len();
        self.reservations.retain(|_, r| {
            r.state == ReservationState::Open
                || r.finalized_at.unwrap_or(i64::MAX) >= cutoffs.reservations_finalized_before
        });
        self.runs
            .retain(|_, r| r.unit_consumed || r.updated_at >= cutoffs.runs_updated_before);
        self.days.retain(|day, _| *day >= cutoffs.days_before);
        self.bearer_days
            .retain(|(day, _), _| *day >= cutoffs.bearer_days_before);
        self.provider_hours
            .retain(|hour, _| *hour >= cutoffs.provider_hours_before);
        self.alerts
            .retain(|_, a| !a.sent || a.created_at >= cutoffs.alerts_created_before);
        let after = self.reservations.len()
            + self.runs.len()
            + self.days.len()
            + self.bearer_days.len()
            + self.provider_hours.len()
            + self.alerts.len();
        Ok((before - after) as u64)
    }
}

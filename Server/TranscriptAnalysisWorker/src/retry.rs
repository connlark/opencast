//! Host-visible ladder math for the model call: per-level call deadlines, the
//! whole-run budget those deadlines are cut from, the transport-retry ladder,
//! and the attempt-level failure vocabulary. `analysis.rs` (wasm-only) drives
//! the real clock and fetch through these types; `tests/gemini_retry.rs`
//! proves the arithmetic on a synthetic clock.

use std::time::Duration;

use crate::gemini::{GeminiErrorBody, GeminiParseError};
use crate::types::UpstreamError;

/// Per-call deadline at medium thinking. Measured generation latency on
/// long episodes runs 15–60 s with thinking-token spikes past two minutes,
/// so a flat 60 s bound abandoned healthy generations the worker was still
/// billed for and then repeated.
pub const GEMINI_CALL_TIMEOUT_MEDIUM_SECONDS: u64 = 120;
/// Per-call deadline at high thinking. High is the escalation level, so it
/// produces the most thinking tokens and needs minutes, not seconds.
pub const GEMINI_CALL_TIMEOUT_HIGH_SECONDS: u64 = 300;
/// Whole-run budget, measured from the persisted job start (route entry on
/// the inline lane). Every call's deadline is the smaller of its level cap
/// and the remaining budget; backoff sleeps and timeout resends count
/// against it as well, so the run as a whole ends inside the budget.
pub const ANALYSIS_RUN_BUDGET_SECONDS: u64 = 540;
/// A call never starts with less than this left: a shorter deadline could
/// only abandon a generation the worker would still pay for.
pub const ANALYSIS_BUDGET_FLOOR_SECONDS: u64 = 30;
/// After a timeout the identical payload is resent at most this many times,
/// immediately: the timed-out request was aborted, so there is nothing to
/// wait for, and a payload that timed out twice needs a different attempt
/// (the next thinking level), not a third identical send.
pub const MAX_TIMEOUT_RESENDS: usize = 1;
/// Longest pause between fast failures: a `Retry-After` header is honoured
/// up to this many seconds and `backoff_seconds` never exceeds it.
pub const MAX_RETRY_DELAY_SECONDS: u64 = 30;
/// Slack the job's running deadline keeps beyond the run budget for the
/// terminal record write and its billing bookkeeping.
pub const TERMINAL_WRITE_MARGIN_SECONDS: u64 = 60;
/// Development-lane override: wall-clock milliseconds per ladder second, so
/// the local runtime suites exercise the real ladder in a fraction of the
/// time. Ignored outside the development lane and outside `1..=1000`.
pub const LADDER_OVERRIDE_VAR: &str = "ANALYSIS_LADDER_MILLIS_PER_SECOND";

const REAL_TIME_MILLIS_PER_SECOND: u64 = 1_000;

/// Exponential backoff between fast failures when the upstream sent no
/// `Retry-After`: 2, 4, 8, then 16 s.
pub fn backoff_seconds(attempt: usize) -> u64 {
    (1u64 << attempt.min(4)).min(20)
}

/// The ladder's tunables, resolved once per run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LadderConfig {
    pub medium_call_timeout_seconds: u64,
    pub high_call_timeout_seconds: u64,
    pub run_budget_seconds: u64,
    pub floor_seconds: u64,
    pub max_timeout_resends: usize,
    /// Wall-clock milliseconds per ladder second; 1000 is real time.
    pub millis_per_second: u64,
}

impl LadderConfig {
    pub const fn production() -> Self {
        Self {
            medium_call_timeout_seconds: GEMINI_CALL_TIMEOUT_MEDIUM_SECONDS,
            high_call_timeout_seconds: GEMINI_CALL_TIMEOUT_HIGH_SECONDS,
            run_budget_seconds: ANALYSIS_RUN_BUDGET_SECONDS,
            floor_seconds: ANALYSIS_BUDGET_FLOOR_SECONDS,
            max_timeout_resends: MAX_TIMEOUT_RESENDS,
            millis_per_second: REAL_TIME_MILLIS_PER_SECOND,
        }
    }

    /// Production values, with the time scale overridden only when the lane
    /// is `development` and the override parses inside `1..=1000`. Every
    /// other lane, value, or absence is production time.
    pub fn resolve(lane: Option<&str>, override_value: Option<&str>) -> Self {
        let mut config = Self::production();
        if lane.map(str::trim) != Some("development") {
            return config;
        }
        if let Some(millis) = override_value.and_then(|value| value.trim().parse::<u64>().ok()) {
            if (1..=REAL_TIME_MILLIS_PER_SECOND).contains(&millis) {
                config.millis_per_second = millis;
            }
        }
        config
    }

    /// The per-call cap for a thinking level; every level below high shares
    /// the medium cap.
    pub fn call_cap_seconds(&self, level: &str) -> u64 {
        if level == "high" {
            self.high_call_timeout_seconds
        } else {
            self.medium_call_timeout_seconds
        }
    }

    /// Ladder seconds as wall-clock time under this configuration.
    pub fn duration(&self, seconds: u64) -> Duration {
        Duration::from_millis(self.wall_millis(seconds))
    }

    fn wall_millis(&self, seconds: u64) -> u64 {
        seconds.saturating_mul(self.millis_per_second.max(1))
    }
}

/// The guarantee the caps are sized for: a first-level call that times out
/// and is resent once, then an escalated call that gets its whole high cap.
pub fn escalation_worst_case_seconds(config: &LadderConfig) -> u64 {
    let sends = (config.max_timeout_resends as u64).saturating_add(1);
    sends
        .saturating_mul(config.medium_call_timeout_seconds)
        .saturating_add(config.high_call_timeout_seconds)
}

/// Returned when the budget cannot fit another call (or a sleep and the
/// call after it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BudgetExhausted;

/// The run budget anchored to an explicit start instant. All time is passed
/// in as `now_ms` (the wall clock in production, a synthetic clock in tests)
/// and the arithmetic saturates, so a clock that jumps can shorten a run but
/// never overflow it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunBudget {
    config: LadderConfig,
    deadline_ms: u64,
}

impl RunBudget {
    pub fn start(config: LadderConfig, now_ms: u64) -> Self {
        Self {
            config,
            deadline_ms: now_ms.saturating_add(config.wall_millis(config.run_budget_seconds)),
        }
    }

    pub fn config(&self) -> &LadderConfig {
        &self.config
    }

    /// Whole ladder seconds left before the deadline, never more than the
    /// budget itself (a clock that reads earlier than the anchor cannot
    /// grant extra time).
    pub fn remaining_seconds(&self, now_ms: u64) -> u64 {
        (self.deadline_ms.saturating_sub(now_ms) / self.config.millis_per_second.max(1))
            .min(self.config.run_budget_seconds)
    }

    /// The deadline for a call at `level`: the level cap, or the remainder
    /// of the budget when that is smaller, and never less than the floor.
    pub fn call_timeout(&self, level: &str, now_ms: u64) -> Result<Duration, BudgetExhausted> {
        let remaining = self.remaining_seconds(now_ms);
        if remaining < self.config.floor_seconds {
            return Err(BudgetExhausted);
        }
        Ok(self
            .config
            .duration(remaining.min(self.config.call_cap_seconds(level))))
    }

    /// A sleep before a resend, refused when it would not leave room for the
    /// call it precedes.
    pub fn backoff(&self, seconds: u64, now_ms: u64) -> Result<Duration, BudgetExhausted> {
        let remaining = self.remaining_seconds(now_ms);
        if remaining < seconds.saturating_add(self.config.floor_seconds) {
            return Err(BudgetExhausted);
        }
        Ok(self.config.duration(seconds))
    }
}

/// Why one transport try failed without a usable reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportFailure {
    /// The deadline elapsed; the request was aborted.
    Timeout,
    /// The fetch was rejected or the body stream failed.
    FetchError,
    /// A retryable status (5xx, or a 429 that is not a hard quota).
    RetryableStatus { retry_after_seconds: Option<u64> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LadderStep {
    /// Send the identical payload again after `delay_seconds` (zero after a
    /// timeout: the aborted request left nothing to wait for).
    Resend { delay_seconds: u64 },
    /// The ladder is spent. `delay_seconds` is the pause the last failure
    /// asked for (`Retry-After`, or the backoff step it would have taken):
    /// the caller honours it before anything else is sent, so the next
    /// analysis attempt does not spend its first send on an upstream that
    /// just said it was not ready. Zero after a timeout.
    GiveUp { delay_seconds: u64 },
}

/// The transport-retry ladder for one analysis attempt: at most `max_tries`
/// sends in total, of which timeouts may claim at most `max_timeout_resends`
/// resends. Parametric in the try count so it never needs the pinned
/// attempt constants.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportLadder {
    max_tries: usize,
    max_timeout_resends: usize,
    failed_tries: usize,
    timeout_resends: usize,
}

impl TransportLadder {
    pub fn new(max_tries: usize, max_timeout_resends: usize) -> Self {
        Self {
            max_tries,
            max_timeout_resends,
            failed_tries: 0,
            timeout_resends: 0,
        }
    }

    /// Tries that have failed so far.
    pub fn failed_tries(&self) -> usize {
        self.failed_tries
    }

    /// Records a failed try and decides what follows it. The delay is the
    /// same whether the ladder resends or gives up: what the failure asked
    /// for, capped, or nothing after a timeout.
    pub fn next_after(&mut self, failure: TransportFailure) -> LadderStep {
        self.failed_tries = self.failed_tries.saturating_add(1);
        let delay_seconds = match failure {
            TransportFailure::Timeout => 0,
            TransportFailure::FetchError => backoff_seconds(self.failed_tries),
            TransportFailure::RetryableStatus {
                retry_after_seconds,
            } => retry_after_seconds
                .unwrap_or_else(|| backoff_seconds(self.failed_tries))
                .min(MAX_RETRY_DELAY_SECONDS),
        };
        if self.failed_tries >= self.max_tries {
            return LadderStep::GiveUp { delay_seconds };
        }
        if failure == TransportFailure::Timeout {
            if self.timeout_resends >= self.max_timeout_resends {
                return LadderStep::GiveUp { delay_seconds };
            }
            self.timeout_resends = self.timeout_resends.saturating_add(1);
        }
        LadderStep::Resend { delay_seconds }
    }
}

/// How one analysis attempt ended without a validated result. Each variant
/// moves the run to its next attempt while budget remains; the last one
/// standing names the run's failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttemptFailure {
    /// Hard validation violations; the fixed rule codes, comma-joined.
    Validation(String),
    Parse(GeminiParseError),
    /// The transport ladder gave up (two timeouts, or five fast failures).
    Transport(UpstreamError),
}

impl AttemptFailure {
    /// The typed error a run ends with when this was its last failure.
    pub fn into_error(self) -> UpstreamError {
        match self {
            AttemptFailure::Validation(codes) => {
                UpstreamError::with_detail(502, "invalid_model_output", codes)
            }
            AttemptFailure::Parse(GeminiParseError::MaxTokensTruncated) => {
                UpstreamError::new(502, "model_output_truncated")
            }
            AttemptFailure::Parse(_) => UpstreamError::new(502, "invalid_model_output"),
            AttemptFailure::Transport(error) => error,
        }
    }
}

/// The run's terminal error: the last attempt's failure, or, when the budget
/// ran out before any attempt could fail, the deterministic timeout code.
pub fn run_failure_error(last_failure: Option<AttemptFailure>) -> UpstreamError {
    last_failure
        .map(AttemptFailure::into_error)
        .unwrap_or_else(|| UpstreamError::new(503, "gemini_timeout"))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RetryDecision {
    Retry { retry_after_seconds: Option<u64> },
    HardQuota,
    DoNotRetry,
}

impl RetryDecision {
    pub fn is_retry(&self) -> bool {
        matches!(self, RetryDecision::Retry { .. })
    }
}

pub fn classify_http_status(
    status: u16,
    retry_after: Option<&str>,
    error: Option<&GeminiErrorBody>,
) -> RetryDecision {
    match status {
        500 | 502 | 503 | 504 => RetryDecision::Retry {
            retry_after_seconds: retry_after.and_then(parse_retry_after_seconds),
        },
        429 => {
            if is_hard_quota(error) {
                RetryDecision::HardQuota
            } else {
                RetryDecision::Retry {
                    retry_after_seconds: retry_after.and_then(parse_retry_after_seconds),
                }
            }
        }
        _ => RetryDecision::DoNotRetry,
    }
}

pub fn parse_retry_after_seconds(value: &str) -> Option<u64> {
    let seconds = value.trim().parse::<u64>().ok()?;
    Some(seconds.min(MAX_RETRY_DELAY_SECONDS))
}

fn is_hard_quota(error: Option<&GeminiErrorBody>) -> bool {
    let Some(error) = error else {
        return false;
    };
    let status = error.status.as_deref().unwrap_or_default();
    let message = error.message.to_ascii_lowercase();
    status == "RESOURCE_EXHAUSTED"
        && (message.contains("quota")
            || message.contains("billing")
            || message.contains("prepay")
            || message.contains("credit"))
}

//! Log lines. Every field is a `&'static str` from a closed set or a number:
//! the types make it impossible to log a string that came from a request, a
//! provider reply, an error's `Display`, a run id or a subject.

use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ForwardEvent {
    pub event: &'static str,
    pub lane: &'static str,
    pub feature: Option<&'static str>,
    pub mode: Option<&'static str>,
    /// A refusal code, a provider status family, `timeout`, `unreachable`,
    /// `body_too_large`, `auth_failed`, `invalid`, `unavailable`, `disabled`.
    pub outcome: &'static str,
    pub detail: Option<&'static str>,
    pub admitted: bool,
    pub provider_status: Option<u16>,
    /// `counted` or `none` (a window is never forwarded on an estimate).
    pub count: &'static str,
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub reserved_micros: Option<u64>,
    pub charged_micros: Option<u64>,
    /// Reported usage beyond the reservation.
    pub overrun_micros: Option<u64>,
    pub duration_ms: u64,
}

impl ForwardEvent {
    pub fn new(lane: &'static str, outcome: &'static str, duration_ms: u64) -> Self {
        Self {
            event: "trial_forward",
            lane,
            feature: None,
            mode: None,
            outcome,
            detail: None,
            admitted: false,
            provider_status: None,
            count: "none",
            input_tokens: None,
            output_tokens: None,
            reserved_micros: None,
            charged_micros: None,
            overrun_micros: None,
            duration_ms,
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct StatusEvent {
    pub event: &'static str,
    pub lane: &'static str,
    pub mode: Option<&'static str>,
    pub outcome: &'static str,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ConfigErrorEvent {
    pub event: &'static str,
    pub field: &'static str,
    pub reason: &'static str,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct StageEvent {
    pub event: &'static str,
    pub stage: &'static str,
    pub kind: &'static str,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct AlertEvent {
    pub event: &'static str,
    pub kind: &'static str,
    pub sent: bool,
    pub attempts: u32,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MirrorEvent {
    pub event: &'static str,
    pub outcome: &'static str,
    pub rows: u64,
    pub consecutive_failures: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct DaySummaryEvent {
    pub event: &'static str,
    /// UTC day index (days since 1970-01-01).
    pub day: i64,
    pub admitted: u64,
    pub input_tokens: u64,
    /// Runs admitted while open that trial mode would have refused: the
    /// notice-period signal.
    pub trial_would_refuse: u64,
    pub forwards: u64,
    pub provider_failures: u64,
    pub expired: u64,
    /// Settlements whose usage exceeded the reservation, and the excess.
    pub overruns: u64,
    pub overrun_micros: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct OverrunEvent {
    pub event: &'static str,
    pub reserved_micros: u64,
    pub overrun_micros: u64,
    pub prompt_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct HousekeepingEvent {
    pub event: &'static str,
    pub expired: u32,
    pub pruned: u64,
}

pub fn line(event: &impl Serialize) -> String {
    serde_json::to_string(event).unwrap_or_else(|_| r#"{"event":"trial_log_error"}"#.to_string())
}

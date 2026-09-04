use crate::gemini::GeminiErrorBody;

/// Each Gemini attempt is bounded so a stalled upstream cannot eat the job
/// deadline. 60 s: 4 of the 16 archived 3.5-flash runs on Security Now-length
/// fixtures exceeded the previous 30 s bound (sn1085 up to 63.9 s), so that
/// timeout fired in production and paid Google for generations the worker
/// then abandoned (2026-09-03 bakeoff prep).
pub const GEMINI_CALL_TIMEOUT_SECONDS: u64 = 60;
/// Transport ladder for the first request of a window.
pub const MAX_GEMINI_ATTEMPTS: usize = 3;
/// Shorter ladder for the single malformed-output re-request
/// (`analysis::analyze_window`).
pub const MAX_GEMINI_REREQUEST_ATTEMPTS: usize = 2;
/// Longest pause between attempts: a `Retry-After` header is honoured up to
/// this many seconds and `backoff_seconds` never exceeds it.
pub const MAX_RETRY_DELAY_SECONDS: u64 = 30;
/// Slack the job deadline keeps beyond the worst-case ladders for the
/// unbounded response-body read, Durable Object bookkeeping, and the fan-out
/// over concurrent windows.
pub const LADDER_DEADLINE_HEADROOM_SECONDS: u64 = 120;

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

/// Exponential backoff between attempts when the upstream sent no
/// `Retry-After`: 2, 4, 8, 16, then 20 s.
pub fn backoff_seconds(attempt: usize) -> u64 {
    (1u64 << attempt.min(4)).min(20)
}

/// Upper bound on one ladder: every attempt times out and every gap waits the
/// longest allowed delay.
pub fn worst_case_ladder_seconds(attempts: usize) -> u64 {
    let attempts = attempts as u64;
    attempts * GEMINI_CALL_TIMEOUT_SECONDS + attempts.saturating_sub(1) * MAX_RETRY_DELAY_SECONDS
}

/// Upper bound on one window, and therefore on one request (windows run
/// concurrently): the first ladder plus the re-request ladder,
/// (3×60 + 2×30) + (2×60 + 1×30) = 390 s, 210 s under the 600 s job deadline
/// (`job::JOB_RUNNING_DEADLINE_SECONDS`). RemoteTranscriptionWorker's 900 s
/// ad-analysis deadline still allows one full resubmit on top.
pub fn worst_case_window_seconds() -> u64 {
    worst_case_ladder_seconds(MAX_GEMINI_ATTEMPTS)
        + worst_case_ladder_seconds(MAX_GEMINI_REREQUEST_ATTEMPTS)
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

use crate::gemini::GeminiErrorBody;

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
    Some(seconds.min(30))
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

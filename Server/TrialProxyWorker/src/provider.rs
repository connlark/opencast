//! What the proxy reads from Gemini: the `countTokens` total the
//! reservation is sized on and `usageMetadata` for settlement. Numbers only;
//! no text from a provider body is kept or logged.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The reply body the forward will buffer; above it the reply is not
/// returned (the device refuses bodies over 512 KiB anyway).
pub const MAX_PROVIDER_BODY_BYTES: usize = 2 * 1024 * 1024;
pub const COUNT_TOKENS_TIMEOUT_MS: u64 = 10_000;
/// A window whose count failed is refused with this `retry-after`: the
/// count endpoint's failures are transient, and no estimate is a ceiling.
pub const COUNT_FAILED_RETRY_AFTER_SECONDS: u64 = 10;
const MAX_COUNT_BODY_BYTES: usize = 64 * 1024;

/// `countTokens` over the exact body that will be forwarded.
pub fn count_tokens_body(model: &str, outbound: &Value) -> Vec<u8> {
    let mut request = match outbound {
        Value::Object(fields) => fields.clone(),
        _ => Map::new(),
    };
    request.insert("model".into(), format!("models/{model}").into());
    serde_json::to_vec(&serde_json::json!({ "generateContentRequest": request }))
        .unwrap_or_default()
}

pub fn parse_count_tokens(body: &[u8]) -> Option<u64> {
    #[derive(Deserialize)]
    struct Count {
        #[serde(rename = "totalTokens")]
        total_tokens: u64,
    }
    if body.len() > MAX_COUNT_BODY_BYTES {
        return None;
    }
    serde_json::from_slice::<Count>(body)
        .ok()
        .map(|count| count.total_tokens)
        .filter(|total| *total > 0)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub prompt_tokens: u64,
    /// Billed output: answer plus thinking tokens.
    pub output_tokens: u64,
}

/// Usage the proxy can settle on: `promptTokenCount` and `totalTokenCount`
/// both present. Billed output is at least answer plus thinking and at least
/// what the total says beyond the prompt; a total below the prompt is
/// contradictory and settles nothing.
pub fn parse_usage(body: &[u8]) -> Option<Usage> {
    #[derive(Deserialize)]
    struct Reply {
        #[serde(rename = "usageMetadata")]
        usage: Option<Metadata>,
    }
    #[derive(Deserialize)]
    struct Metadata {
        #[serde(rename = "promptTokenCount")]
        prompt: Option<u64>,
        #[serde(rename = "totalTokenCount")]
        total: Option<u64>,
        #[serde(rename = "candidatesTokenCount", default)]
        candidates: u64,
        #[serde(rename = "thoughtsTokenCount", default)]
        thoughts: u64,
    }
    let usage = serde_json::from_slice::<Reply>(body).ok()?.usage?;
    let (prompt, total) = (usage.prompt?, usage.total?);
    let beyond_prompt = total.checked_sub(prompt)?;
    Some(Usage {
        prompt_tokens: prompt,
        output_tokens: usage
            .candidates
            .saturating_add(usage.thoughts)
            .max(beyond_prompt),
    })
}

/// A provider `Retry-After` the device can use: whole seconds, capped at 30
/// (the device's own cap); anything else is dropped.
pub fn sanitized_retry_after(value: Option<&str>) -> Option<u64> {
    let value = value?.trim();
    if value.is_empty() || value.len() > 6 || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    value.parse::<u64>().ok().map(|seconds| seconds.min(30))
}

/// Why a dispatch without usage keeps its whole reservation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AmbiguousClass {
    NoUsage,
    Status3xx,
    Status4xx,
    Status5xx,
    OtherStatus,
    Timeout,
    Unreachable,
    BodyTooLarge,
}

impl AmbiguousClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NoUsage => "no_usage",
            Self::Status3xx => "3xx",
            Self::Status4xx => "4xx",
            Self::Status5xx => "5xx",
            Self::OtherStatus => "other_status",
            Self::Timeout => "timeout",
            Self::Unreachable => "unreachable",
            Self::BodyTooLarge => "body_too_large",
        }
    }

    /// Counted toward the provider-failure alert.
    pub fn is_provider_failure(self) -> bool {
        matches!(self, Self::Status5xx | Self::Timeout | Self::Unreachable)
    }
}

/// How a reservation settles. `Usage` charges what the reply reports (never
/// more than the reservation); `Rejected` and `NotDispatched` charge nothing;
/// `Ambiguous` charges the whole reservation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SettleOutcome {
    Usage {
        status: u16,
        usage: Usage,
    },
    Rejected {
        status: u16,
    },
    Ambiguous {
        class: AmbiguousClass,
        status: Option<u16>,
    },
    NotDispatched,
}

impl SettleOutcome {
    pub fn kind(self) -> &'static str {
        match self {
            Self::Usage { .. } => "usage",
            Self::Rejected { .. } => "rejected",
            Self::Ambiguous { .. } => "ambiguous",
            Self::NotDispatched => "not_dispatched",
        }
    }

    pub fn dispatched(self) -> bool {
        !matches!(self, Self::NotDispatched)
    }

    pub fn provider_failure(self) -> bool {
        matches!(self, Self::Ambiguous { class, .. } if class.is_provider_failure())
    }
}

/// Statuses Gemini returns before generating anything (invalid argument,
/// bad key, permission, unknown model, rate limit): nothing is billed.
pub const UNBILLED_STATUSES: [u16; 5] = [400, 401, 403, 404, 429];

/// The settlement for a reply that arrived.
pub fn classify_reply(status: u16, body: &[u8]) -> SettleOutcome {
    if (200..300).contains(&status) {
        return match parse_usage(body) {
            Some(usage) => SettleOutcome::Usage { status, usage },
            None => SettleOutcome::Ambiguous {
                class: AmbiguousClass::NoUsage,
                status: Some(status),
            },
        };
    }
    if UNBILLED_STATUSES.contains(&status) {
        return SettleOutcome::Rejected { status };
    }
    let class = match status {
        300..=399 => AmbiguousClass::Status3xx,
        400..=499 => AmbiguousClass::Status4xx,
        500..=599 => AmbiguousClass::Status5xx,
        _ => AmbiguousClass::OtherStatus,
    };
    SettleOutcome::Ambiguous {
        class,
        status: Some(status),
    }
}

/// The status family of a reply, for telemetry.
pub fn status_family(status: u16) -> &'static str {
    match status {
        200..=299 => "2xx",
        300..=399 => "3xx",
        400..=499 => "4xx",
        500..=599 => "5xx",
        _ => "other_status",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_reads_prompt_and_billed_output() {
        let body = br#"{"candidates":[{"content":{"parts":[{"text":"{}"}]}}],"usageMetadata":{"promptTokenCount":2039,"candidatesTokenCount":377,"thoughtsTokenCount":10349,"totalTokenCount":12765},"modelVersion":"gemini-3.8-flash"}"#;
        assert_eq!(
            parse_usage(body),
            Some(Usage {
                prompt_tokens: 2039,
                output_tokens: 10_726
            })
        );
        assert_eq!(
            parse_usage(br#"{"usageMetadata":{"candidatesTokenCount":5}}"#),
            None
        );
        assert_eq!(
            parse_usage(br#"{"usageMetadata":{"promptTokenCount":10}}"#),
            None
        );
        assert_eq!(
            parse_usage(br#"{"usageMetadata":{"promptTokenCount":10,"totalTokenCount":9}}"#),
            None
        );
        // An omitted answer count is not read as zero output.
        assert_eq!(
            parse_usage(br#"{"usageMetadata":{"promptTokenCount":10,"totalTokenCount":510,"thoughtsTokenCount":20}}"#),
            Some(Usage {
                prompt_tokens: 10,
                output_tokens: 500
            })
        );
        assert_eq!(parse_usage(b"not json"), None);
    }

    #[test]
    fn retry_after_is_whole_seconds_capped_at_thirty() {
        assert_eq!(sanitized_retry_after(Some("7")), Some(7));
        assert_eq!(sanitized_retry_after(Some(" 120 ")), Some(30));
        assert_eq!(
            sanitized_retry_after(Some("Wed, 21 Oct 2026 07:28:00 GMT")),
            None
        );
        assert_eq!(sanitized_retry_after(Some("-1")), None);
        assert_eq!(sanitized_retry_after(Some("1.5")), None);
        assert_eq!(sanitized_retry_after(None), None);
    }

    #[test]
    fn every_settlement_branch_is_pinned() {
        let usage = br#"{"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12}}"#;
        assert_eq!(
            classify_reply(200, usage),
            SettleOutcome::Usage {
                status: 200,
                usage: Usage {
                    prompt_tokens: 10,
                    output_tokens: 2
                }
            }
        );
        assert_eq!(
            classify_reply(200, b"{}"),
            SettleOutcome::Ambiguous {
                class: AmbiguousClass::NoUsage,
                status: Some(200)
            }
        );
        for status in UNBILLED_STATUSES {
            assert_eq!(
                classify_reply(status, b"{\"error\":{}}"),
                SettleOutcome::Rejected { status }
            );
        }
        for (status, class) in [
            (302, AmbiguousClass::Status3xx),
            (408, AmbiguousClass::Status4xx),
            (409, AmbiguousClass::Status4xx),
            (499, AmbiguousClass::Status4xx),
            (500, AmbiguousClass::Status5xx),
            (503, AmbiguousClass::Status5xx),
            (600, AmbiguousClass::OtherStatus),
        ] {
            assert_eq!(
                classify_reply(status, usage),
                SettleOutcome::Ambiguous {
                    class,
                    status: Some(status)
                },
                "{status}"
            );
        }
    }

    #[test]
    fn count_tokens_wraps_the_forwarded_body() {
        let outbound =
            serde_json::json!({"contents": [{"role": "user", "parts": [{"text": "x"}]}]});
        let body: Value =
            serde_json::from_slice(&count_tokens_body("gemini-3.8-flash", &outbound)).unwrap();
        assert_eq!(
            body["generateContentRequest"]["model"],
            "models/gemini-3.8-flash"
        );
        assert_eq!(
            body["generateContentRequest"]["contents"],
            outbound["contents"]
        );
        assert_eq!(parse_count_tokens(br#"{"totalTokens":2041}"#), Some(2041));
        assert_eq!(parse_count_tokens(br#"{"totalTokens":0}"#), None);
        assert_eq!(parse_count_tokens(b"{}"), None);
    }
}

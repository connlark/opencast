use serde::Serialize;

/// One structured line per request. Fields are the full logging
/// surface: no query text, Apple IDs, upstream bodies, or credentials.
#[derive(Debug, Serialize)]
pub struct RequestLog<'a> {
    pub route: &'a str,
    pub status: u16,
    pub cache: &'a str,
    #[serde(rename = "providerLatencyMs", skip_serializing_if = "Option::is_none")]
    pub provider_latency_ms: Option<u64>,
    #[serde(rename = "resultCount", skip_serializing_if = "Option::is_none")]
    pub result_count: Option<usize>,
    #[serde(rename = "errorClass", skip_serializing_if = "Option::is_none")]
    pub error_class: Option<&'a str>,
}

pub fn log_line(log: &RequestLog) -> String {
    serde_json::to_string(log).unwrap_or_else(|_| format!("{{\"route\":\"{}\"}}", log.route))
}

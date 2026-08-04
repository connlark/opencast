use serde::Serialize;

/// Subscriptions-sync response payload rows. Host-gated (unlike the wasm-only
/// `worker_app` that assembles them) so their serialization tests compile and
/// run under host `cargo test` — a `#[cfg(test)]` inside `worker_app` never
/// compiles on any lane.
#[derive(Serialize)]
pub(crate) struct AcceptedSubscription {
    pub(crate) feed_url: String,
    pub(crate) title: Option<String>,
    /// Advisory poll-health snapshot for the client's diagnostics; absent for
    /// feeds admitted lazily that have never been polled. Additive and
    /// optional both directions: old clients ignore it, new clients treat
    /// absence as "no data".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) health: Option<AcceptedSubscriptionHealth>,
}

#[derive(Serialize)]
pub(crate) struct AcceptedSubscriptionHealth {
    pub(crate) consecutive_failures: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) last_http_status: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) last_error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) last_polled_at: Option<i64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepted_subscription_serializes_health_and_omits_it_when_absent() {
        let with_health = AcceptedSubscription {
            feed_url: "https://example.com/feed.xml".to_string(),
            title: Some("Show".to_string()),
            health: Some(AcceptedSubscriptionHealth {
                consecutive_failures: 4,
                last_http_status: Some(503),
                last_error: Some("http_error".to_string()),
                last_polled_at: Some(1_780_000_000),
            }),
        };
        let json = serde_json::to_value(&with_health).expect("serialize accepted");
        assert_eq!(json["feed_url"], "https://example.com/feed.xml");
        assert_eq!(json["health"]["consecutive_failures"], 4);
        assert_eq!(json["health"]["last_http_status"], 503);
        assert_eq!(json["health"]["last_error"], "http_error");
        assert_eq!(json["health"]["last_polled_at"], 1_780_000_000_i64);

        let without_health = AcceptedSubscription {
            feed_url: "https://example.com/feed.xml".to_string(),
            title: None,
            health: None,
        };
        let json = serde_json::to_value(&without_health).expect("serialize accepted");
        assert!(json.get("health").is_none());

        let never_polled = AcceptedSubscriptionHealth {
            consecutive_failures: 0,
            last_http_status: None,
            last_error: None,
            last_polled_at: None,
        };
        let json = serde_json::to_value(&never_polled).expect("serialize health");
        assert_eq!(json["consecutive_failures"], 0);
        assert!(json.get("last_http_status").is_none());
        assert!(json.get("last_error").is_none());
        assert!(json.get("last_polled_at").is_none());
    }
}

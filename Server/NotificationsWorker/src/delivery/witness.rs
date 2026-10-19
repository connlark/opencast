//! The per-send APNs witness: one structured line per durable send attempt,
//! written where `send::deliver` decides the delivery's disposition. Opaque
//! identifiers only: the event digest and a prefix of the stored token hash,
//! never a token, installation, feed URL or payload.
use serde_json::{json, Value};

/// Enough of the stored SHA-256 token hash to tell an installation's devices
/// apart in a tail. The delivery row joins through `apns_id`.
const DEVICE_HASH_CHARS: usize = 16;

pub(crate) struct ApnsSend<'a> {
    pub source: &'a str,
    pub kind: &'a str,
    pub event_id: &'a str,
    pub device_token_hash: &'a str,
    pub attempt: i64,
    /// `None` when the response was lost or the send deadline expired.
    pub status: Option<u16>,
    /// The `apns-id` APNs answered with.
    pub apns_id: Option<&'a str>,
    pub apns_reason: &'a str,
    pub latency_ms: u64,
    /// The chosen state and reason, logged before the final delivery update
    /// and so no proof that it committed; `None` when deciding them failed
    /// and the delivery is left to the handling-failure path.
    pub disposition: Option<(&'a str, &'a str)>,
}

impl ApnsSend<'_> {
    pub(crate) fn accepted(&self) -> bool {
        matches!(self.disposition, Some(("accepted", _)))
    }

    pub(crate) fn line(&self) -> Value {
        let device = self
            .device_token_hash
            .get(..DEVICE_HASH_CHARS)
            .unwrap_or(self.device_token_hash);
        json!({
            "event": "notification_apns_send",
            "source": self.source,
            "kind": self.kind,
            "event_id": self.event_id,
            "device_hash": device,
            "attempt": self.attempt,
            "status": self.status,
            "apns_id": self.apns_id,
            "apns_reason": (!self.apns_reason.is_empty()).then_some(self.apns_reason),
            "latency_ms": self.latency_ms,
            "state": self.disposition.map(|(state, _)| state),
            "reason": self.disposition.map(|(_, reason)| reason),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdeffedcba98765432100123456789abcdeffedcba9876543210";

    fn send<'a>() -> ApnsSend<'a> {
        ApnsSend {
            source: "feed_polling",
            kind: "episode",
            event_id: "e1",
            device_token_hash: HASH,
            attempt: 1,
            status: Some(200),
            apns_id: Some("00000000-0000-4000-8000-000000000001"),
            apns_reason: "",
            latency_ms: 42,
            disposition: Some(("accepted", "accepted")),
        }
    }

    #[test]
    fn an_accepted_send_carries_every_witness_field_and_a_device_hash_prefix() {
        let witness = send();
        assert!(witness.accepted());
        assert_eq!(
            witness.line(),
            json!({
                "event": "notification_apns_send",
                "source": "feed_polling",
                "kind": "episode",
                "event_id": "e1",
                "device_hash": "0123456789abcdef",
                "attempt": 1,
                "status": 200,
                "apns_id": "00000000-0000-4000-8000-000000000001",
                "apns_reason": null,
                "latency_ms": 42,
                "state": "accepted",
                "reason": "accepted",
            })
        );
        assert!(!witness.line().to_string().contains(HASH));
    }

    #[test]
    fn rejected_lost_and_undecided_sends_keep_the_same_shape() {
        let rejected = ApnsSend {
            status: Some(410),
            apns_id: None,
            apns_reason: "Unregistered",
            disposition: Some(("suppressed", "token_invalid")),
            ..send()
        };
        assert!(!rejected.accepted());
        let rejected = rejected.line();
        assert_eq!(rejected["status"], 410);
        assert_eq!(rejected["apns_reason"], "Unregistered");
        assert_eq!(rejected["state"], "suppressed");
        assert_eq!(rejected["reason"], "token_invalid");
        let lost = ApnsSend {
            status: None,
            apns_id: None,
            disposition: Some(("uncertain", "response_unknown")),
            ..send()
        }
        .line();
        assert_eq!(lost["status"], Value::Null);
        assert_eq!(lost["apns_id"], Value::Null);
        let undecided = ApnsSend {
            disposition: None,
            ..send()
        };
        assert!(!undecided.accepted());
        let undecided = undecided.line();
        assert_eq!(undecided["state"], Value::Null);
        assert_eq!(undecided["reason"], Value::Null);
        let keys = |line: &Value| {
            line.as_object()
                .map(|o| o.keys().cloned().collect::<Vec<_>>())
        };
        for line in [&rejected, &lost, &undecided] {
            assert_eq!(keys(line), keys(&send().line()));
        }
    }
}

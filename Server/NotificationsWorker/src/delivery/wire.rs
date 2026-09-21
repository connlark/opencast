use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub const EVENT_LIMIT: usize = 16 * 1024;
pub const TOMBSTONE_SECONDS: i64 = 30 * 86400;

pub fn hash(parts: &[&str]) -> String {
    hex::encode(Sha256::digest(
        serde_json::to_vec(parts).expect("string array"),
    ))
}
pub fn digest(value: &Value) -> String {
    // serde_json's default map is a BTreeMap; all v1 integers are safe integers.
    hex::encode(Sha256::digest(
        serde_json::to_vec(value).expect("JSON value"),
    ))
}
pub fn hex_id(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
}
pub fn string<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
pub fn int(v: &Value, key: &str) -> i64 {
    v[key].as_i64().unwrap_or(0)
}
fn keys(v: &Value, required: &[&str], optional: &[&str]) -> bool {
    v.as_object().is_some_and(|m| {
        required.iter().all(|k| m.contains_key(*k))
            && m.keys()
                .all(|k| required.contains(&k.as_str()) || optional.contains(&k.as_str()))
    })
}
fn text(v: &Value, key: &str, limit: usize) -> bool {
    v[key]
        .as_str()
        .is_some_and(|s| !s.is_empty() && s.len() <= limit && !s.chars().any(char::is_control))
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Event {
    pub schema_version: u32,
    pub environment: String,
    pub source: String,
    pub event_id: String,
    pub kind: String,
    pub occurred_at: i64,
    pub eligible_at: i64,
    pub expires_at: i64,
    pub routing: Value,
    pub data: Value,
}
impl Event {
    pub fn validate(&self, producer: &str, lane: &str, now: i64) -> Result<(), &'static str> {
        if self.schema_version != 1 || !hex_id(&self.event_id) {
            return Err("invalid_request");
        }
        if self.source != producer {
            return Err("producer_mismatch");
        }
        if self.environment != lane {
            return Err("environment_mismatch");
        }
        if self.expires_at <= now {
            return Err("event_expired");
        }
        if self.occurred_at < 0 || self.occurred_at > now + 60 || self.eligible_at > now + 60 {
            return Err("invalid_time");
        }
        if self.kind == "episode" {
            let r = &self.routing;
            let d = &self.data;
            if producer != "feed_polling"
                || !keys(
                    r,
                    &[
                        "feed_id",
                        "observation_id",
                        "observation_generation",
                        "owner_epoch",
                        "episode_id",
                    ],
                    &[],
                )
                || !keys(
                    d,
                    &[
                        "feed_url",
                        "podcast_title",
                        "episode_title",
                        "first_observed_at",
                        "decision_reason",
                    ],
                    &[
                        "fingerprint",
                        "episode_summary",
                        "episode_duration_seconds",
                        "artwork_url",
                        "episode_artwork_url",
                        "published_at",
                    ],
                )
                || !hex_id(string(r, "feed_id"))
                || !uuid(string(r, "observation_id"))
                || !text(r, "episode_id", 512)
                || int(r, "owner_epoch") < 1
                || int(r, "observation_generation") < 1
                || self.expires_at != self.eligible_at.saturating_add(86400)
                || self.eligible_at < self.occurred_at
                || d["first_observed_at"].as_i64() != Some(self.occurred_at)
                || !["recent", "undated", "anomalous_date", "future"]
                    .contains(&string(d, "decision_reason"))
                || !text(d, "podcast_title", 512)
                || !text(d, "episode_title", 512)
                || !text(d, "feed_url", 4096)
                || crate::feed_identity::canonical_string_for_raw_url(string(d, "feed_url"))
                    .ok()
                    .as_deref()
                    != Some(string(d, "feed_url"))
                || hash(&["feed-v1", string(d, "feed_url")]) != string(r, "feed_id")
                || self.event_id
                    != hash(&[
                        "episode-v1",
                        lane,
                        string(r, "feed_id"),
                        string(r, "episode_id"),
                    ])
            {
                return Err("invalid_request");
            }
            for k in ["episode_summary", "artwork_url", "episode_artwork_url"] {
                if d.get(k).is_some() && !text(d, k, 512) {
                    return Err("invalid_request");
                }
            }
            if d.get("fingerprint")
                .is_some_and(|v| !v.as_str().is_some_and(hex_id))
            {
                return Err("invalid_request");
            }
            if d.get("published_at").is_some_and(|v| v.as_i64().is_none())
                || d.get("episode_duration_seconds")
                    .is_some_and(|v| !v.as_i64().is_some_and(|n| (0..=86400).contains(&n)))
            {
                return Err("invalid_request");
            }
        } else {
            let r = &self.routing;
            let d = &self.data;
            if !["ad_analysis", "remote_transcription"].contains(&producer)
                || ![
                    format!("{producer}.completed"),
                    format!("{producer}.failed"),
                ]
                .contains(&self.kind)
                || !keys(
                    r,
                    &[
                        "interest_id",
                        "interest_generation",
                        "operation_id",
                        "run_id",
                    ],
                    &[],
                )
                || !hex_id(string(r, "interest_id"))
                || int(r, "interest_generation") < 1
                || !uuid(string(r, "operation_id"))
                || !uuid(string(r, "run_id"))
                || self.eligible_at != self.occurred_at
                || self.expires_at != self.occurred_at.saturating_add(21600)
                || !keys(
                    d,
                    &[
                        "job_handle",
                        "title",
                        "body",
                        if self.kind.ends_with(".completed") {
                            "result_expires_at"
                        } else {
                            "failure_code"
                        },
                    ],
                    &["ad_analysis_state"],
                )
                || !text(d, "job_handle", 256)
                || !text(d, "title", 512)
                || !text(d, "body", 512)
                || self.event_id
                    != hash(&[
                        "job-v1",
                        lane,
                        producer,
                        string(r, "run_id"),
                        string(r, "operation_id"),
                        string(r, "interest_id"),
                        &self.kind,
                    ])
            {
                return Err("invalid_request");
            }
            if self.kind.ends_with(".completed") && int(d, "result_expires_at") <= self.occurred_at
            {
                return Err("invalid_request");
            }
            if self.kind.ends_with(".failed")
                && ![
                    "analysis_failed",
                    "transcription_failed",
                    "execution_timeout",
                    "insufficient_credits",
                    "source_unavailable",
                ]
                .contains(&string(d, "failure_code"))
            {
                return Err("invalid_request");
            }
            if d.get("ad_analysis_state").is_some()
                && (producer != "remote_transcription"
                    || string(d, "ad_analysis_state") != "failed")
            {
                return Err("invalid_request");
            }
        }
        Ok(())
    }
    pub fn value(&self) -> Value {
        serde_json::to_value(self).expect("event JSON")
    }
}

// Reject duplicate keys at every level, unsafe/fractional numbers, and unpaired
// surrogates before typed decoding. Value alone silently overwrites duplicates.
pub fn parse(bytes: &[u8]) -> Result<Value, &'static str> {
    struct Strict(Value);
    impl<'de> Deserialize<'de> for Strict {
        fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
            struct Visitor;
            impl<'de> serde::de::Visitor<'de> for Visitor {
                type Value = Strict;
                fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                    f.write_str("canonical JSON")
                }
                fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<Strict, E> {
                    Ok(Strict(json!(v)))
                }
                fn visit_unit<E: serde::de::Error>(self) -> Result<Strict, E> {
                    Ok(Strict(Value::Null))
                }
                fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Strict, E> {
                    Ok(Strict(json!(v)))
                }
                fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<Strict, E> {
                    if v.unsigned_abs() > 9007199254740991 {
                        Err(E::custom("unsafe integer"))
                    } else {
                        Ok(Strict(json!(v)))
                    }
                }
                fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<Strict, E> {
                    if v > 9007199254740991 {
                        Err(E::custom("unsafe integer"))
                    } else {
                        Ok(Strict(json!(v)))
                    }
                }
                fn visit_seq<A: serde::de::SeqAccess<'de>>(
                    self,
                    mut a: A,
                ) -> Result<Strict, A::Error> {
                    let mut v = vec![];
                    while let Some(Strict(x)) = a.next_element()? {
                        v.push(x)
                    }
                    Ok(Strict(Value::Array(v)))
                }
                fn visit_map<A: serde::de::MapAccess<'de>>(
                    self,
                    mut a: A,
                ) -> Result<Strict, A::Error> {
                    let mut m = serde_json::Map::new();
                    while let Some((k, Strict(v))) = a.next_entry::<String, Strict>()? {
                        if m.insert(k, v).is_some() {
                            return Err(serde::de::Error::custom("duplicate key"));
                        }
                    }
                    Ok(Strict(Value::Object(m)))
                }
            }
            d.deserialize_any(Visitor)
        }
    }
    serde_json::from_slice::<Strict>(bytes)
        .map(|s| s.0)
        .map_err(|_| "invalid_request")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_ambiguous_json() {
        for s in [
            r#"{"x":1,"x":2}"#,
            r#"{"x":{"a":0,"a":1}}"#,
            r#"{"x":1.5}"#,
            r#"{"x":9007199254740992}"#,
            r#"{"x":"\ud800"}"#,
        ] {
            assert!(parse(s.as_bytes()).is_err(), "{s}");
        }
    }
    #[test]
    fn canonical_digest_and_array_hash() {
        assert_eq!(
            digest(&parse(br#"{"b":2,"a":1}"#).unwrap()),
            digest(&parse(br#"{"a":1,"b":2}"#).unwrap())
        );
        assert_ne!(hash(&["a:b", "c"]), hash(&["a", "b:c"]));
    }
}

//! Phase-0 fixtures exercise the current public helpers; no shipped code changes.
use opencast_notifications_worker::{apns, app_attest, feed_identity};
use serde_json::Value;
use sha2::{Digest, Sha256};
fn fixtures() -> Value {
    serde_json::from_str(include_str!(
        "../../../scripts/notifications-overhaul/fixtures/wire.json"
    ))
    .unwrap()
}
#[test]
fn legacy_episode_fixture_matches_current_renderer_and_identity() {
    let fixture = fixtures();
    let expected = &fixture["episode"]["opencast"];
    let feed = expected["feed_url"].as_str().unwrap();
    let id = feed_identity::episode_id(feed, Some("owned-episode"), None, "Owned episode", None);
    assert_eq!(id, expected["episode_id"]);
    let request = apns::episode_delivery_push_request(
        fixture["register"]["device_token"].as_str().unwrap(),
        "com.example.opencast",
        apns::ApnsEnvironment::Development,
        apns::EpisodeNotification {
            podcast_title: "Owned fixture",
            episode_title: "Owned episode",
            episode_summary: Some("Synthetic summary."),
            show_notes_html: None,
            duration_seconds: Some(2640),
            podcast_artwork_url: Some("https://art.example.invalid/show.jpg"),
            episode_artwork_url: None,
            feed_url: feed,
            episode_id: &id,
        },
        1_800_000_000,
    )
    .unwrap();
    let actual: Value = serde_json::from_str(&request.body).unwrap();
    for (key, value) in expected.as_object().unwrap() {
        assert_eq!(&actual["opencast"][key], value, "{key}");
    }
    assert_eq!(actual["aps"]["category"], "OPENCAST_EPISODE");
    assert_eq!(actual["aps"]["mutable-content"], 1);
}
#[test]
fn legacy_envelope_keeps_exact_method_path_payload_binding() {
    let fixture = fixtures();
    let actual = app_attest::request_client_data_hash(
        "POST",
        "/v1/subscriptions/sync",
        fixture["envelope"]["payload"].as_str().unwrap(),
    );
    assert_eq!(hex::encode(actual), fixture["binding"]["sha256"]);
}

// Test-only reference serializer. Production ingress still belongs to later passes.
fn canonical_json(value: &Value) -> String {
    match value {
        Value::Object(object) => {
            let mut keys: Vec<_> = object.keys().collect();
            keys.sort();
            let fields: Vec<_> = keys
                .into_iter()
                .map(|key| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(key).unwrap(),
                        canonical_json(&object[key])
                    )
                })
                .collect();
            format!("{{{}}}", fields.join(","))
        }
        Value::Array(values) => format!(
            "[{}]",
            values
                .iter()
                .map(canonical_json)
                .collect::<Vec<_>>()
                .join(",")
        ),
        Value::Number(number) => {
            let integer = number.as_i64().expect("canonical numbers must be integers");
            assert!(integer.unsigned_abs() <= 9_007_199_254_740_991);
            integer.to_string()
        }
        _ => serde_json::to_string(value).unwrap(),
    }
}

#[test]
fn overhaul_identifiers_and_envelope_match_cross_language_known_answers() {
    let fixture = fixtures();
    for (name, vector) in fixture["identifiers"].as_object().unwrap() {
        let encoded = serde_json::to_string(&vector["parts"]).unwrap();
        assert_eq!(encoded, vector["utf8"], "{name}");
        assert_eq!(
            hex::encode(Sha256::digest(encoded.as_bytes())),
            vector["sha256"],
            "{name}"
        );
    }
    let vector = &fixture["payload_digest"];
    let encoded = canonical_json(&vector["envelope"]);
    assert_eq!(encoded, vector["canonical_utf8"]);
    assert_eq!(
        hex::encode(Sha256::digest(encoded.as_bytes())),
        vector["sha256"]
    );
    assert!(vector["envelope"]["data"]
        .get(vector["omitted_optional_field"].as_str().unwrap())
        .is_none());
    assert_eq!(
        apns::episode_collapse_id(
            fixture["legacy_collapse_id"]["episode_id"]
                .as_str()
                .unwrap()
        ),
        fixture["legacy_collapse_id"]["sha256"]
    );
}

#[test]
fn grouped_payload_preserves_installed_episode_route_and_size() {
    let fixture = fixtures();
    let expected = &fixture["grouped_episode"];
    for count in [1, 3, 5, 100_000] {
        let mut request = apns::episode_delivery_push_request(
            fixture["register"]["device_token"].as_str().unwrap(),
            "com.example.opencast",
            apns::ApnsEnvironment::Development,
            apns::EpisodeNotification {
                podcast_title: "Owned fixture",
                episode_title: "Owned episode",
                episode_summary: Some(&"🎧".repeat(500)),
                show_notes_html: None,
                duration_seconds: Some(2640),
                podcast_artwork_url: Some("https://art.example.invalid/show.jpg"),
                episode_artwork_url: None,
                feed_url: expected["opencast"]["feed_url"].as_str().unwrap(),
                episode_id: expected["opencast"]["episode_id"].as_str().unwrap(),
            },
            1_800_000_000,
        )
        .unwrap();
        let before = request.body.clone();
        apns::group_episode_request(&mut request, count).unwrap();
        assert!(request.body.len() <= 3800);
        let value: Value = serde_json::from_str(&request.body).unwrap();
        assert_eq!(value["aps"]["category"], expected["aps"]["category"]);
        assert_eq!(
            value["opencast"]["episode_id"],
            expected["opencast"]["episode_id"]
        );
        assert_eq!(value["opencast"]["kind"], "episode");
        if count <= 3 {
            assert_eq!(request.body, before);
        } else {
            assert_eq!(value["opencast"]["episode_count"], count);
        }
        if count == 5 {
            assert_eq!(
                value["aps"]["alert"]["body"],
                expected["aps"]["alert"]["body"]
            );
        }
    }
}

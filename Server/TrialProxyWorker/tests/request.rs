//! The request contract and the rewrite, on the recorded live carousel
//! request the device sends.

use opencast_trial_proxy_worker::bundle::{embedded, Feature};
use opencast_trial_proxy_worker::request::{
    parse_window, InvalidReason, RequestError, CHAPTERS_ESCALATED_CALL_TIMEOUT_SECONDS,
};
use opencast_trial_proxy_worker::route::refused_unlogged;
use serde_json::{json, Value};

const CAP: usize = 1_572_864;
const CAROUSEL: &str = include_str!(
    "../../../Packages/OpenCastAnalysis/Tests/OpenCastAnalysisTests/Fixtures/providers/gemini-carousel-success.json"
);

fn device_body() -> Value {
    let fixture: Value = serde_json::from_str(CAROUSEL).unwrap();
    serde_json::from_str(fixture["request"]["body"].as_str().unwrap()).unwrap()
}

fn wrap(feature: &str, request: Value) -> Value {
    json!({"feature": feature, "run_id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF", "window_index": 0, "request": request})
}

fn parse(body: &Value) -> Result<opencast_trial_proxy_worker::request::TrialWindow, RequestError> {
    parse_window(&serde_json::to_vec(body).unwrap(), embedded().unwrap(), CAP)
}

fn invalid(body: &Value) -> InvalidReason {
    match parse(body) {
        Err(RequestError::Invalid(reason)) => reason,
        other => panic!("expected a refusal, got {other:?}"),
    }
}

fn chapters_request(thinking: &str) -> Value {
    json!({
        "contents": [{"role": "user", "parts": [{"text": "{\"segments\":[]}"}]}],
        "generationConfig": {
            "maxOutputTokens": 32768,
            "responseJsonSchema": {"type": "object"},
            "responseMimeType": "application/json",
            "temperature": 0,
            "thinkingConfig": {"thinkingLevel": thinking},
            "topP": 0.95
        }
    })
}

#[test]
fn the_device_body_is_forwarded_unchanged() {
    let device = device_body();
    let window = parse(&wrap("ad_detection", device.clone())).unwrap();
    // The device built it from the same bundle: nothing differs at all.
    assert_eq!(window.outbound, device);
    let bundle = embedded().unwrap();
    assert_eq!(
        window.max_output_tokens,
        bundle.ad_detection.max_output_tokens
    );
    assert_eq!(
        window.call_timeout_seconds,
        bundle.ad_detection.per_call_timeout_seconds
    );
    assert_eq!(window.feature, Feature::AdDetection);
    let reparsed: Value = serde_json::from_slice(&window.outbound_bytes).unwrap();
    assert_eq!(reparsed, device);
}

#[test]
fn only_the_bundle_chargeable_fields_are_overwritten() {
    let device = device_body();
    let mut tampered = device.clone();
    tampered["model"] = json!("gemini-3.5-pro");
    let config = &mut tampered["generationConfig"];
    config["maxOutputTokens"] = json!(65_536);
    config["thinkingConfig"] =
        json!({"thinkingLevel": "high", "includeThoughts": true, "thinkingBudget": 99_999});
    config["responseMimeType"] = json!("text/plain");
    config["responseJsonSchema"] = json!({"type": "string"});
    let window = parse(&wrap("ad_detection", tampered.clone())).unwrap();
    assert_eq!(
        window.outbound, device,
        "the tampered fields are rebuilt from the bundle"
    );
    assert!(window.outbound.get("model").is_none());
    // contents and systemInstruction are the device's, deep-equal.
    assert_eq!(window.outbound["contents"], tampered["contents"]);
    assert_eq!(
        window.outbound["systemInstruction"],
        tampered["systemInstruction"]
    );
}

#[test]
fn chapters_keeps_high_only_when_asked_and_only_for_chapters() {
    let bundle = embedded().unwrap();
    let high = parse(&wrap("chapters_summary", chapters_request("high"))).unwrap();
    assert_eq!(
        high.outbound["generationConfig"]["thinkingConfig"],
        json!({"thinkingLevel": "high"})
    );
    assert_eq!(
        high.call_timeout_seconds,
        CHAPTERS_ESCALATED_CALL_TIMEOUT_SECONDS
    );
    assert_eq!(
        high.max_output_tokens,
        bundle.chapters_summary.max_output_tokens
    );
    assert_eq!(
        high.outbound["generationConfig"]["maxOutputTokens"],
        json!(bundle.chapters_summary.max_output_tokens)
    );
    // Sampling settings pass through.
    assert_eq!(high.outbound["generationConfig"]["temperature"], json!(0));
    assert_eq!(high.outbound["generationConfig"]["topP"], json!(0.95));
    // Any other level becomes the entry's, with the entry's timeout.
    for level in ["low", "medium", "minimal", "HIGH"] {
        let window = parse(&wrap("chapters_summary", chapters_request(level))).unwrap();
        assert_eq!(
            window.outbound["generationConfig"]["thinkingConfig"]["thinkingLevel"],
            json!(bundle.chapters_summary.thinking)
        );
        assert_eq!(
            window.call_timeout_seconds,
            bundle.chapters_summary.per_call_timeout_seconds
        );
    }
    // Ad detection never escalates.
    let mut ad = device_body();
    ad["generationConfig"]["thinkingConfig"] = json!({"thinkingLevel": "high"});
    let window = parse(&wrap("ad_detection", ad)).unwrap();
    assert_eq!(window.thinking, bundle.ad_detection.thinking);
    assert_eq!(
        window.call_timeout_seconds,
        bundle.ad_detection.per_call_timeout_seconds
    );
    // The schema is the feature's own whatever the device sent.
    assert_eq!(
        high.outbound["generationConfig"]["responseJsonSchema"],
        bundle.chapters_summary.response_schema
    );
}

#[test]
fn the_device_may_only_shorten_the_budget() {
    let mut body = wrap("ad_detection", device_body());
    body["timeout_seconds"] = json!(30);
    assert_eq!(parse(&body).unwrap().call_timeout_seconds, 30);
    body["timeout_seconds"] = json!(500);
    assert_eq!(parse(&body).unwrap().call_timeout_seconds, 120);
    for bad in [json!(0), json!(601), json!(1.5), json!("30"), json!(-1)] {
        body["timeout_seconds"] = bad;
        assert_eq!(invalid(&body), InvalidReason::Timeout);
    }
}

#[test]
fn chargeable_or_unknown_request_keys_are_refused() {
    for key in [
        "tools",
        "toolConfig",
        "cachedContent",
        "safetySettings",
        "labels",
        "contentsx",
    ] {
        let mut request = device_body();
        request[key] = json!([]);
        assert_eq!(
            invalid(&wrap("ad_detection", request)),
            InvalidReason::RequestKeys,
            "{key}"
        );
    }
    for key in [
        "candidateCount",
        "responseModalities",
        "responseSchema",
        "stopSequences",
        "seed",
        "topK",
        "mediaResolution",
        "speechConfig",
        "responseLogprobs",
    ] {
        let mut request = device_body();
        request["generationConfig"][key] = json!(2);
        assert_eq!(
            invalid(&wrap("ad_detection", request)),
            InvalidReason::GenerationConfig,
            "{key}"
        );
    }
    for (key, value) in [
        ("temperature", json!(2.5)),
        ("topP", json!(-0.1)),
        ("temperature", json!("0")),
    ] {
        let mut request = device_body();
        request["generationConfig"][key] = value;
        assert_eq!(
            invalid(&wrap("ad_detection", request)),
            InvalidReason::Sampling
        );
    }
    let mut request = device_body();
    request.as_object_mut().unwrap().remove("contents");
    assert_eq!(
        invalid(&wrap("ad_detection", request)),
        InvalidReason::RequestKeys
    );
}

#[test]
fn only_text_parts_and_two_roles_are_accepted() {
    let bad_parts = [
        json!({"inlineData": {"mimeType": "audio/mp3", "data": "AAAA"}}),
        json!({"fileData": {"fileUri": "https://www.youtube.com/watch?v=x"}}),
        json!({"functionCall": {"name": "x"}}),
        json!({"text": "x", "thoughtSignature": "abc"}),
        json!({"text": 5}),
        json!("bare string"),
    ];
    for part in bad_parts {
        let mut request = device_body();
        request["contents"][0]["parts"] = json!([part.clone()]);
        assert_eq!(
            invalid(&wrap("ad_detection", request)),
            InvalidReason::Parts,
            "{part}"
        );
        let mut request = device_body();
        request["systemInstruction"]["parts"] = json!([part]);
        assert_eq!(
            invalid(&wrap("ad_detection", request)),
            InvalidReason::Parts
        );
    }
    for role in ["system", "function", ""] {
        let mut request = device_body();
        request["contents"][0]["role"] = json!(role);
        assert_eq!(invalid(&wrap("ad_detection", request)), InvalidReason::Turn);
    }
    let mut request = device_body();
    request["contents"] = json!([]);
    assert_eq!(
        invalid(&wrap("ad_detection", request)),
        InvalidReason::Contents
    );
    let mut request = device_body();
    request["systemInstruction"] = json!({"parts": [{"text": "x"}], "role": "user"});
    assert_eq!(
        invalid(&wrap("ad_detection", request)),
        InvalidReason::SystemInstruction
    );
    // An ad repair turn (model then user text) is accepted.
    let mut repair = device_body();
    let turns = repair["contents"].as_array_mut().unwrap();
    turns.push(json!({"parts": [{"text": "{\"spans\":[]}"}], "role": "model"}));
    turns.push(json!({"parts": [{"text": "Fix the answer."}], "role": "user"}));
    let window = parse(&wrap("ad_detection", repair.clone())).unwrap();
    assert_eq!(window.outbound["contents"], repair["contents"]);
}

#[test]
fn the_wrapper_is_closed() {
    let request = device_body();
    let mut extra = wrap("ad_detection", request.clone());
    extra["model"] = json!("x");
    assert_eq!(invalid(&extra), InvalidReason::Wrapper);
    let mut missing = wrap("ad_detection", request.clone());
    missing.as_object_mut().unwrap().remove("window_index");
    assert_eq!(invalid(&missing), InvalidReason::Wrapper);
    assert_eq!(
        invalid(&wrap("transcription", request.clone())),
        InvalidReason::Feature
    );
    for run_id in [
        json!(""),
        json!("a/b"),
        json!("x".repeat(65)),
        json!(7),
        json!("run id"),
    ] {
        let mut body = wrap("ad_detection", request.clone());
        body["run_id"] = run_id;
        assert_eq!(invalid(&body), InvalidReason::RunId);
    }
    for index in [json!(1024), json!(-1), json!(1.5), json!("0")] {
        let mut body = wrap("ad_detection", request.clone());
        body["window_index"] = index;
        assert_eq!(invalid(&body), InvalidReason::WindowIndex);
    }
    let mut body = wrap("ad_detection", request.clone());
    body["request"] = json!(serde_json::to_string(&request).unwrap());
    assert_eq!(
        invalid(&body),
        InvalidReason::RequestKeys,
        "request must be an object, not a string"
    );
    assert!(matches!(
        parse_window(b"[]", embedded().unwrap(), CAP),
        Err(RequestError::Invalid(InvalidReason::Wrapper))
    ));
    assert!(matches!(
        parse_window(b"{", embedded().unwrap(), CAP),
        Err(RequestError::Invalid(InvalidReason::Json))
    ));
}

#[test]
fn size_and_depth_are_bounded() {
    let body = serde_json::to_vec(&wrap("ad_detection", device_body())).unwrap();
    assert!(matches!(
        parse_window(&body, embedded().unwrap(), body.len() - 1),
        Err(RequestError::TooLarge)
    ));
    assert!(parse_window(&body, embedded().unwrap(), body.len()).is_ok());
    let deep = format!("{}{}", "[".repeat(200), "]".repeat(200));
    let nested = format!(
        r#"{{"feature":"ad_detection","run_id":"r","window_index":0,"request":{{"contents":{deep}}}}}"#
    );
    assert!(matches!(
        parse_window(nested.as_bytes(), embedded().unwrap(), CAP),
        Err(RequestError::Invalid(InvalidReason::Json))
    ));
}

#[test]
fn a_key_header_or_any_query_is_refused_before_anything_else() {
    assert!(refused_unlogged(true, false));
    // Any query at all, not only a `key` parameter: the URL reaches logs.
    assert!(refused_unlogged(false, true));
    assert!(!refused_unlogged(false, false));
}

use opencast_ad_analysis_worker::{
    policy as ad_policy, promo_v3, prompt as ad_prompt, v3_windowing, validation as ad_validation,
};
use opencast_model_gateway_worker::{
    analysis_policy::{
        self, bundle_json_bytes, canonical_utc_timestamp_seconds, check_bundle, generate,
        parse_bundle, sign_policy_bytes, valid_model_id, verify_policy_bytes, AnalysisPolicyBundle,
        GenerationInputs, Notice, PINNED_PUBLIC_KEY_HEX, SIGNATURE_KEY_ID,
    },
    manifest_signature::{public_key_hex_from_signing_key_hex, ManifestSignature},
    policy_schema,
    policy_swift::{
        baked_source, fixtures_source, test_fixtures, test_signing_seed_hex, TEST_KEY_ID,
    },
};
use opencast_transcript_analysis_worker::{
    coalescing, prompt as chapters_prompt, retry as chapters_retry, types as chapters_types,
    validation as chapters_validation,
};
use serde_json::{json, Value};
use std::{fs, path::PathBuf};

const CURRENT_VERSION: u32 = 3;

fn worker_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn package_dir() -> PathBuf {
    worker_dir().join("../../Packages/OpenCastAnalysis")
}

fn checked_in(version: u32) -> Vec<u8> {
    fs::read(
        worker_dir()
            .join("manifests/analysis-policy")
            .join(format!("v{version}.json")),
    )
    .expect("checked-in bundle")
}

fn checked_in_signature(version: u32) -> ManifestSignature {
    let bytes = fs::read(
        worker_dir()
            .join("manifests/analysis-policy")
            .join(format!("v{version}.json.sig")),
    )
    .expect("checked-in signature");
    serde_json::from_slice(&bytes).expect("signature envelope")
}

fn schema() -> Value {
    serde_json::from_slice(
        &fs::read(worker_dir().join("manifests/analysis-policy.schema.json")).expect("schema"),
    )
    .expect("schema JSON")
}

fn regenerate(bytes: &[u8]) -> Vec<u8> {
    let bundle = parse_bundle(bytes).expect("bundle parses");
    bundle_json_bytes(
        &generate(&GenerationInputs {
            bundle_version: bundle.bundle_version,
            generated_at: bundle.generated_at,
            min_app_build: bundle.min_app_build,
        })
        .expect("generates"),
    )
    .expect("serializes")
}

fn current_bundle() -> AnalysisPolicyBundle {
    parse_bundle(&checked_in(CURRENT_VERSION)).expect("current bundle parses")
}

#[test]
fn checked_in_bundle_equals_the_generator_output() {
    // A changed worker constant, prompt or schema fails here until the bundle
    // is regenerated under a new version.
    let bytes = checked_in(CURRENT_VERSION);
    assert!(
        regenerate(&bytes) == bytes,
        "v{CURRENT_VERSION}.json is stale; regenerate it with generate_policy"
    );
}

#[test]
fn checked_in_bundle_signature_verifies_with_the_pinned_key() {
    verify_policy_bytes(
        &checked_in(CURRENT_VERSION),
        &checked_in_signature(CURRENT_VERSION),
        PINNED_PUBLIC_KEY_HEX,
        SIGNATURE_KEY_ID,
    )
    .expect("production signature verifies");
}

#[test]
fn baked_swift_copy_equals_the_generator_output() {
    let bytes = checked_in(CURRENT_VERSION);
    let expected = baked_source(&bytes, CURRENT_VERSION).expect("baked source");
    let actual = fs::read_to_string(
        package_dir().join("Sources/OpenCastAnalysis/Policy/BakedAnalysisPolicy.swift"),
    )
    .expect("baked Swift source");
    assert!(
        actual == expected,
        "BakedAnalysisPolicy.swift differs from v{CURRENT_VERSION}.json"
    );
}

#[test]
fn swift_test_fixtures_equal_the_generator_output() {
    let expected =
        fixtures_source(&test_fixtures(&current_bundle()).expect("fixtures")).expect("source");
    let actual = fs::read_to_string(
        package_dir().join("Tests/OpenCastAnalysisTests/Policy/AnalysisPolicyTestFixtures.swift"),
    )
    .expect("fixture Swift source");
    assert!(
        actual == expected,
        "AnalysisPolicyTestFixtures.swift is stale"
    );
}

#[test]
fn test_fixtures_are_signed_with_the_test_key_only() {
    let test_public = public_key_hex_from_signing_key_hex(&test_signing_seed_hex()).unwrap();
    assert_ne!(test_public, PINNED_PUBLIC_KEY_HEX);
    for fixture in test_fixtures(&current_bundle()).unwrap() {
        let envelope: ManifestSignature = serde_json::from_slice(&fixture.signature).unwrap();
        assert_eq!(envelope.key_id, TEST_KEY_ID);
        let verdict = verify_policy_bytes(&fixture.bundle, &envelope, &test_public, TEST_KEY_ID);
        assert_eq!(
            verdict.is_ok(),
            fixture.name != "badSignature",
            "{}",
            fixture.name
        );
        assert!(
            verify_policy_bytes(
                &fixture.bundle,
                &envelope,
                PINNED_PUBLIC_KEY_HEX,
                TEST_KEY_ID
            )
            .is_err(),
            "{} must not verify with the production key",
            fixture.name
        );
    }
}

#[test]
fn signature_round_trip_with_a_test_seed_rejects_any_changed_byte() {
    let seed = test_signing_seed_hex();
    let public = public_key_hex_from_signing_key_hex(&seed).unwrap();
    let bytes = checked_in(CURRENT_VERSION);
    let signature = sign_policy_bytes(&bytes, TEST_KEY_ID, &seed).unwrap();
    verify_policy_bytes(&bytes, &signature, &public, TEST_KEY_ID).unwrap();

    let mut tampered = bytes.clone();
    let index = tampered.iter().position(|byte| *byte == b'8').unwrap();
    tampered[index] = b'9';
    assert!(verify_policy_bytes(&tampered, &signature, &public, TEST_KEY_ID).is_err());
    assert!(verify_policy_bytes(&bytes, &signature, &public, "other-key").is_err());
}

#[test]
fn generated_values_come_from_the_worker_constants() {
    let bundle = current_bundle();
    let ad = &bundle.features.ad_detection;
    assert_eq!(
        ad.prompt.as_bytes(),
        include_bytes!("../../AdAnalysisWorker/src/promo_v3_prompt.txt")
    );
    assert_eq!(ad.response_schema, promo_v3::schema());
    assert_eq!(ad.policy, promo_v3::POLICY);
    assert_eq!(ad.revision, ad_policy::V3_REVISION);
    assert_eq!(ad.window.segments, v3_windowing::WINDOW_SEGMENTS);
    assert_eq!(ad.window.overlap, v3_windowing::OVERLAP_SEGMENTS);
    assert_eq!(ad.window.max_in_flight, v3_windowing::CONCURRENT_WINDOWS);
    assert_eq!(ad.limits.spans_per_window, promo_v3::MAX_BREAKS_PER_WINDOW);
    assert_eq!(ad.limits.max_break_seconds, promo_v3::MAX_BREAK_SECONDS);
    assert_eq!(
        ad.limits.budget_fraction,
        ad_validation::AD_BUDGET_EPISODE_FRACTION
    );
    assert_eq!(
        ad.limits.budget_floor_seconds,
        ad_validation::AD_BUDGET_FLOOR_SECONDS
    );
    assert_eq!(ad.limits.evidence_words, promo_v3::MAX_EVIDENCE_WORDS);
    assert_eq!(ad.repair.attempts, ad_policy::V3_REPAIR_ATTEMPTS);
    assert_eq!(
        ad.repair.feedback_bytes,
        promo_v3::MAX_REPAIR_FEEDBACK_BYTES
    );

    let providers: Vec<_> = ad
        .qualified_models
        .iter()
        .map(|m| m.provider.as_str())
        .collect();
    assert_eq!(providers, ["google", "openai"]);
    for entry in &ad.qualified_models {
        assert_eq!(entry.thinking, "medium");
        assert_eq!(entry.max_output_tokens, ad_prompt::GEMINI_MAX_OUTPUT_TOKENS);
        assert_eq!(
            entry.per_call_timeout_seconds,
            ad_policy::V3_MAX_CALL_SECONDS
        );
        assert_eq!(entry.run_budget_seconds, ad_policy::V3_EXECUTION_SECONDS);
    }
    assert_eq!(ad.qualified_models[0].model_id, ad_policy::V3_MODEL);
    assert_eq!(ad.qualified_models[1].model_id, "gpt-6.1-sol");
    assert_eq!(bundle.trial.model, ad_policy::V3_MODEL);
    assert_eq!(bundle.trial.lifetime_units, 5);
    assert_eq!(bundle.trial.starts_at, "2027-01-01T00:00:00Z");
    // The notice starts with the first bundle that carried it and stays put.
    assert_eq!(analysis_policy::NOTICE_STARTS_AT, "2026-10-25T01:10:00Z");
    assert_eq!(
        bundle
            .notice
            .as_ref()
            .map(|notice| notice.starts_at.as_str()),
        Some(analysis_policy::NOTICE_STARTS_AT)
    );
    let later = generate(&GenerationInputs {
        bundle_version: bundle.bundle_version + 1,
        generated_at: "2027-03-01T00:00:00Z".to_string(),
        min_app_build: bundle.min_app_build,
    })
    .expect("a later bundle generates");
    assert_eq!(later.notice, bundle.notice);
    assert!(
        canonical_utc_timestamp_seconds(analysis_policy::NOTICE_STARTS_AT)
            <= canonical_utc_timestamp_seconds(&bundle.generated_at),
        "the notice cannot start after the bundle that announces it"
    );
    let key_url = |provider: &str| bundle.providers[provider].key_url.as_deref();
    assert_eq!(key_url("google"), Some(analysis_policy::GOOGLE_KEY_URL));
    assert_eq!(key_url("openai"), Some(analysis_policy::OPENAI_KEY_URL));

    let chapters = &bundle.features.chapters_summary;
    // The two golden models, qualified for Chapters & Summary with the
    // Chapters worker's own output cap, first-call timeout and run budget.
    let expected: Vec<(&str, &str)> = vec![
        ("google", analysis_policy::CHAPTERS_GOOGLE_MODEL),
        ("openai", analysis_policy::OPENAI_GOLDEN_MODEL),
    ];
    assert_eq!(
        chapters
            .allowed_models
            .iter()
            .map(|entry| (entry.provider.as_str(), entry.model_id.as_str()))
            .collect::<Vec<_>>(),
        expected
    );
    for entry in &chapters.allowed_models {
        assert_eq!(entry.thinking, analysis_policy::CHAPTERS_THINKING);
        assert_eq!(
            entry.max_output_tokens,
            chapters_prompt::GEMINI_MAX_OUTPUT_TOKENS
        );
        assert_eq!(
            entry.per_call_timeout_seconds,
            chapters_retry::GEMINI_CALL_TIMEOUT_MEDIUM_SECONDS
        );
        assert_eq!(
            entry.run_budget_seconds,
            chapters_retry::ANALYSIS_RUN_BUDGET_SECONDS
        );
    }
    assert_eq!(
        chapters.response_schema,
        serde_json::from_str::<Value>(chapters_prompt::RESPONSE_SCHEMA).unwrap()
    );
    assert_eq!(
        chapters.coalescing.above_segments,
        coalescing::COALESCING_TRIGGER_SEGMENT_COUNT
    );
    assert_eq!(
        chapters.coalescing.unit_seconds,
        coalescing::MIN_UNIT_SPAN_BEFORE_CLOSE
    );
    assert_eq!(
        chapters.coalescing.unit_chars,
        coalescing::UNIT_JOIN_CHAR_LIMIT
    );
    assert_eq!(
        chapters.coalescing.gap_seconds,
        coalescing::GAP_BREAK_SECONDS
    );
    assert_eq!(
        chapters.coalescing.max_units,
        chapters_types::MAX_MODEL_UNITS
    );
    assert_eq!(
        chapters.chapter_cap.min,
        chapters_validation::MIN_CHAPTERS_FLOOR
    );
    assert_eq!(
        chapters.chapter_cap.seconds_per_chapter,
        chapters_validation::CHAPTER_SECONDS_PER_CHAPTER
    );
}

#[test]
fn chapters_prompt_is_the_rules_text_the_worker_renders_first() {
    let bundle = current_bundle();
    let rules = &bundle.features.chapters_summary.prompt;
    let request: chapters_types::TranscriptAnalysisRequest = serde_json::from_value(json!({
        "schema_version": 1, "request_id": "x", "episode_id": "ep", "podcast_id": "pod",
        "episode_title": "Title", "podcast_title": "Show",
        "transcript": {"language_code": "en", "audio_duration": 61.5, "fingerprint": "fp",
            "updated_at": "2026-10-01T00:00:00Z", "state": "complete", "segment_count": 1},
        "segments": [{"id": 4, "start": 0.0, "end": 1.25, "text": "hello"}]
    }))
    .unwrap();
    let rendered = chapters_prompt::build_prompt(&request);
    assert!(rendered.starts_with(&format!("{rules}\n\nPolicy: transcript_analysis_v2\n")));
    assert!(rules.starts_with("You are analyzing one complete podcast episode transcript"));
    assert!(rules.ends_with("never put timestamps or seconds in id fields."));
}

#[test]
fn current_bundle_satisfies_the_schema_and_relational_rules() {
    let instance: Value = serde_json::from_slice(&checked_in(CURRENT_VERSION)).unwrap();
    policy_schema::validate(&schema(), &instance).unwrap();
    check_bundle(&current_bundle()).unwrap();
}

/// The schema's numeric bounds are the app's hard bounds; each maximum must
/// be exactly the limit the workers were qualified with.
#[test]
fn schema_maxima_equal_the_qualified_worker_limits() {
    let schema = schema();
    let defs = &schema["$defs"];
    let ad = &defs["ad_detection"]["properties"];
    let max = |value: &Value| value["maximum"].as_f64().unwrap();
    let eq = |value: &Value, expected: f64, name: &str| {
        assert_eq!(max(value), expected, "{name} maximum");
    };
    eq(
        &ad["window"]["properties"]["segments"],
        v3_windowing::WINDOW_SEGMENTS as f64,
        "segments",
    );
    eq(
        &ad["window"]["properties"]["overlap"],
        v3_windowing::OVERLAP_SEGMENTS as f64,
        "overlap",
    );
    eq(
        &ad["window"]["properties"]["max_in_flight"],
        v3_windowing::CONCURRENT_WINDOWS as f64,
        "in flight",
    );
    let limits = &ad["limits"]["properties"];
    eq(
        &limits["spans_per_window"],
        promo_v3::MAX_BREAKS_PER_WINDOW as f64,
        "spans",
    );
    eq(
        &limits["max_break_seconds"],
        promo_v3::MAX_BREAK_SECONDS,
        "break",
    );
    eq(
        &limits["budget_fraction"],
        ad_validation::AD_BUDGET_EPISODE_FRACTION,
        "fraction",
    );
    eq(
        &limits["budget_floor_seconds"],
        ad_validation::AD_BUDGET_FLOOR_SECONDS,
        "floor",
    );
    eq(
        &limits["evidence_words"],
        promo_v3::MAX_EVIDENCE_WORDS as f64,
        "evidence",
    );
    let repair = &ad["repair"]["properties"];
    eq(
        &repair["attempts"],
        ad_policy::V3_REPAIR_ATTEMPTS as f64,
        "repair attempts",
    );
    eq(
        &repair["feedback_bytes"],
        promo_v3::MAX_REPAIR_FEEDBACK_BYTES as f64,
        "feedback",
    );
    eq(
        &defs["ad_model_entry"]["properties"]["max_output_tokens"],
        f64::from(ad_prompt::GEMINI_MAX_OUTPUT_TOKENS),
        "ad output",
    );
    eq(
        &defs["chapters_model_entry"]["properties"]["max_output_tokens"],
        f64::from(chapters_prompt::GEMINI_MAX_OUTPUT_TOKENS),
        "chapters output",
    );
    let coalescing_props = &defs["chapters_summary"]["properties"]["coalescing"]["properties"];
    let pinned = |value: &Value, expected: f64, name: &str| {
        assert_eq!(
            value["minimum"].as_f64().unwrap(),
            expected,
            "{name} minimum"
        );
        assert_eq!(max(value), expected, "{name} maximum");
    };
    pinned(
        &coalescing_props["above_segments"],
        coalescing::COALESCING_TRIGGER_SEGMENT_COUNT as f64,
        "above",
    );
    pinned(
        &coalescing_props["unit_seconds"],
        coalescing::MIN_UNIT_SPAN_BEFORE_CLOSE,
        "unit seconds",
    );
    pinned(
        &coalescing_props["unit_chars"],
        coalescing::UNIT_JOIN_CHAR_LIMIT as f64,
        "unit chars",
    );
    pinned(
        &coalescing_props["gap_seconds"],
        coalescing::GAP_BREAK_SECONDS,
        "gap",
    );
    eq(
        &coalescing_props["max_units"],
        chapters_types::MAX_MODEL_UNITS as f64,
        "max units",
    );
    let cap = &defs["chapters_summary"]["properties"]["chapter_cap"]["properties"];
    eq(
        &cap["min"],
        chapters_validation::MIN_CHAPTERS_FLOOR as f64,
        "chapter floor",
    );
    assert_eq!(
        cap["seconds_per_chapter"]["minimum"].as_f64().unwrap(),
        chapters_validation::CHAPTER_SECONDS_PER_CHAPTER,
        "a looser chapter cap would widen the qualified one"
    );
}

#[test]
fn schema_rejects_a_widened_limit_and_unknown_fields() {
    let schema = schema();
    let base: Value = serde_json::from_slice(&checked_in(CURRENT_VERSION)).unwrap();
    let rejected = |mutate: &dyn Fn(&mut Value)| {
        let mut value = base.clone();
        mutate(&mut value);
        policy_schema::validate(&schema, &value).is_err()
    };
    assert!(rejected(
        &|v| v["features"]["ad_detection"]["window"]["segments"] = json!(801)
    ));
    assert!(rejected(
        &|v| v["features"]["ad_detection"]["window"]["segments"] = json!(199)
    ));
    assert!(rejected(
        &|v| v["features"]["ad_detection"]["limits"]["budget_fraction"] = json!(0.41)
    ));
    assert!(rejected(&|v| v["features"]["ad_detection"]
        ["qualified_models"][0]["max_output_tokens"] =
        json!(16385)));
    assert!(rejected(&|v| v["features"]["chapters_summary"]
        ["coalescing"]["above_segments"] =
        json!(1400)));
    assert!(rejected(&|v| v["schema_version"] = json!(2)));
    assert!(rejected(&|v| v["surprise"] = json!(true)));
    assert!(rejected(&|v| {
        v["features"]["ad_detection"]["window"]
            .as_object_mut()
            .unwrap()
            .remove("overlap");
    }));
    assert!(rejected(&|v| v["trial"]["lifetime_units"] = json!(6)));
    assert!(!rejected(
        &|v| v["features"]["ad_detection"]["window"]["segments"] = json!(600)
    ));
    assert!(!rejected(
        &|v| v["notice"] = json!({"starts_at": "2026-11-15T00:00:00Z"})
    ));
    assert!(!rejected(&|v| {
        v.as_object_mut().unwrap().remove("notice");
    }));
    assert!(rejected(&|v| v["providers"]["google"]["key_url"] = json!(7)));
    assert!(rejected(
        &|v| v["providers"]["openai"]["key_url"] = json!("https:/x")
    ));
    assert!(rejected(
        &|v| v["providers"]["openai"]["key_page"] = json!("https://platform.openai.com/")
    ));
    assert!(!rejected(&|v| {
        v["providers"]["google"]
            .as_object_mut()
            .unwrap()
            .remove("key_url");
    }));
}

#[test]
fn schema_checker_refuses_keywords_it_does_not_implement() {
    let schema =
        json!({"type": "object", "properties": {"a": {"type": "string", "pattern": "^x$"}}});
    let errors = policy_schema::validate(&schema, &json!({})).unwrap_err();
    assert!(
        errors[0].contains("unsupported schema keyword pattern"),
        "{errors:?}"
    );
}

#[test]
fn relational_rules_reject_what_the_schema_cannot_express() {
    let base = current_bundle();
    let rejected = |mutate: &dyn Fn(&mut AnalysisPolicyBundle)| {
        let mut bundle = base.clone();
        mutate(&mut bundle);
        check_bundle(&bundle).is_err()
    };
    assert!(rejected(&|b| {
        b.features.ad_detection.window.segments = 200;
        b.features.ad_detection.window.overlap = 100;
    }));
    assert!(rejected(&|b| {
        let duplicate = b.features.ad_detection.qualified_models[1].clone();
        b.features.ad_detection.qualified_models[0] = duplicate;
    }));
    assert!(rejected(&|b| b.trial.model = "gpt-6.1-sol".to_string()));
    assert!(rejected(&|b| {
        b.providers.get_mut("openai").unwrap().base_url = "https://example.com/v1".to_string();
    }));
    assert!(rejected(&|b| {
        b.providers.get_mut("google").unwrap().base_url =
            "http://generativelanguage.googleapis.com/v1beta".to_string();
    }));
    assert!(rejected(&|b| {
        b.providers.get_mut("google").unwrap().generate_path = "/../models".to_string();
    }));
    assert!(rejected(&|b| {
        b.features.ad_detection.qualified_models[1].model_id = "gpt/../x".to_string();
    }));
    assert!(rejected(&|b| {
        b.features.ad_detection.qualified_models[0].run_budget_seconds = 60;
    }));
    assert!(rejected(
        &|b| b.trial.endpoint = b.trial.endpoint.replacen("https", "http", 1)
    ));
    assert!(rejected(
        &|b| b.trial.endpoint = "https://trial.example.com".to_string()
    ));
    assert!(!rejected(&|b| b
        .features
        .ad_detection
        .qualified_models
        .truncate(1)));
    assert!(!rejected(&|b| {
        b.providers.get_mut("openai").unwrap().key_url = None;
    }));
}

/// The generator and the app check a key page on its raw text with the same
/// grammar; both read these cases.
#[test]
fn key_pages_follow_the_shared_cases() {
    #[derive(serde::Deserialize)]
    struct Cases {
        accepted: Vec<String>,
        rejected: Vec<String>,
    }
    let cases: Cases = serde_json::from_slice(
        &fs::read(worker_dir().join("tests/fixtures/analysis-policy-key-pages.json"))
            .expect("key page cases"),
    )
    .expect("key page cases parse");
    assert!(!cases.accepted.is_empty() && !cases.rejected.is_empty());
    let base = current_bundle();
    let check = |page: &str| {
        let mut bundle = base.clone();
        bundle.providers.get_mut("google").unwrap().key_url = Some(page.to_string());
        check_bundle(&bundle)
    };
    for page in &cases.accepted {
        assert!(check(page).is_ok(), "{page:?} should pass");
    }
    for page in &cases.rejected {
        assert!(check(page).is_err(), "{page:?} should be refused");
    }
}

#[test]
fn model_ids_are_path_safe() {
    assert!(valid_model_id("gemini-3.8-flash"));
    assert!(valid_model_id("gpt-6.1-sol"));
    for bad in ["", "a/b", "a?b", "a b", "a%2Fb", &"x".repeat(129)] {
        assert!(!valid_model_id(bad), "{bad}");
    }
}

/// The rules the app's clamp enforces beyond the schema, mirrored so the
/// publishing gate never approves a bundle the app would reject.
#[test]
fn relational_rules_mirror_the_app_provider_and_size_rules() {
    let base = current_bundle();
    let rejected = |mutate: &dyn Fn(&mut AnalysisPolicyBundle)| {
        let mut bundle = base.clone();
        mutate(&mut bundle);
        check_bundle(&bundle).is_err()
    };
    assert!(rejected(&|b| {
        b.features.ad_detection.qualified_models[0].thinking = "none".to_string();
    }));
    assert!(!rejected(&|b| {
        b.features.ad_detection.qualified_models[1].thinking = "none".to_string();
    }));
    assert!(rejected(&|b| {
        b.providers.get_mut("google").unwrap().auth = "bearer".to_string();
    }));
    assert!(rejected(&|b| {
        b.providers.get_mut("openai").unwrap().auth = "x-goog-api-key".to_string();
    }));
    for name in ["Authorization", "x-goog-api-key", "Cookie", "bad name"] {
        assert!(
            rejected(&|b| {
                b.providers
                    .get_mut("openai")
                    .unwrap()
                    .version_headers
                    .insert(name.to_string(), "x".to_string());
            }),
            "{name}"
        );
    }
    assert!(!rejected(&|b| {
        b.providers
            .get_mut("openai")
            .unwrap()
            .version_headers
            .insert("openai-beta".to_string(), "x".to_string());
    }));
    // 40,000 two-byte characters: under the schema's character limit, over
    // the byte limit.
    assert!(rejected(&|b| {
        b.features.chapters_summary.prompt = "\u{e9}".repeat(40_000);
    }));
    assert!(rejected(&|b| {
        b.features.ad_detection.response_schema =
            json!({"type": "object", "description": "x".repeat(70_000)});
    }));
    assert!(rejected(
        &|b| b.features.ad_detection.response_schema = json!("{}")
    ));
}

/// The envelope names the exact bytes it signs, so a client that fetches the
/// version it names can never pair it with another generation's bundle.
#[test]
fn a_policy_signature_names_and_verifies_only_its_own_bundle() {
    let seed = test_signing_seed_hex();
    let public = public_key_hex_from_signing_key_hex(&seed).unwrap();
    let fixtures = test_fixtures(&current_bundle()).unwrap();
    let find = |name: &str| {
        fixtures
            .iter()
            .find(|fixture| fixture.name == name)
            .unwrap()
    };
    let (good, next) = (find("good"), find("next"));
    let good_signature: ManifestSignature = serde_json::from_slice(&good.signature).unwrap();
    let next_signature: ManifestSignature = serde_json::from_slice(&next.signature).unwrap();
    assert_eq!(good_signature.bundle_version, Some(CURRENT_VERSION + 1));
    assert_eq!(next_signature.bundle_version, Some(CURRENT_VERSION + 2));

    // Old signature with the new body, and the reverse: neither verifies.
    assert!(verify_policy_bytes(&next.bundle, &good_signature, &public, TEST_KEY_ID).is_err());
    assert!(verify_policy_bytes(&good.bundle, &next_signature, &public, TEST_KEY_ID).is_err());
    // Relabelling the envelope cannot move a signature to another body.
    let mut relabelled = good_signature.clone();
    relabelled.bundle_version = next_signature.bundle_version;
    relabelled.sha256.clone_from(&next_signature.sha256);
    assert!(verify_policy_bytes(&next.bundle, &relabelled, &public, TEST_KEY_ID).is_err());
    // An envelope that names no bundle is refused even with a valid signature.
    let mut unbound = good_signature.clone();
    unbound.bundle_version = None;
    unbound.sha256 = None;
    assert_eq!(
        verify_policy_bytes(&good.bundle, &unbound, &public, TEST_KEY_ID),
        Err("signature does not name its bundle".to_string())
    );
    let mut wrong_version = good_signature;
    wrong_version.bundle_version = Some(7);
    assert!(verify_policy_bytes(&good.bundle, &wrong_version, &public, TEST_KEY_ID).is_err());

    // The checked-in production envelope names its version and digest.
    let production = checked_in_signature(CURRENT_VERSION);
    assert_eq!(production.bundle_version, Some(CURRENT_VERSION));
    assert_eq!(production.sha256.as_deref(), Some(baked_digest().as_str()));
}

fn baked_digest() -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(checked_in(CURRENT_VERSION)))
}

#[derive(serde::Deserialize)]
struct TimestampCases {
    valid: Vec<ValidTimestamp>,
    invalid: Vec<String>,
}

#[derive(serde::Deserialize)]
struct ValidTimestamp {
    value: String,
    unix_seconds: i64,
}

fn timestamp_cases() -> TimestampCases {
    serde_json::from_slice(
        &fs::read(worker_dir().join("tests/fixtures/analysis-policy-timestamps.json"))
            .expect("timestamp cases"),
    )
    .expect("timestamp cases JSON")
}

/// The same cases the app's decoder is tested against: a bundle that passes
/// generation and publication always decodes in the app.
#[test]
fn timestamps_follow_the_shared_canonical_utc_cases() {
    let cases = timestamp_cases();
    assert!(!cases.valid.is_empty() && !cases.invalid.is_empty());
    for case in &cases.valid {
        assert_eq!(
            canonical_utc_timestamp_seconds(&case.value),
            Some(case.unix_seconds),
            "{}",
            case.value
        );
    }
    for value in &cases.invalid {
        assert_eq!(canonical_utc_timestamp_seconds(value), None, "{value:?}");
    }
}

#[test]
fn every_bundle_timestamp_is_checked() {
    let base = current_bundle();
    for value in timestamp_cases().invalid {
        let mut generated = base.clone();
        generated.generated_at.clone_from(&value);
        assert!(check_bundle(&generated).is_err(), "generated_at {value:?}");
        let mut trial = base.clone();
        trial.trial.starts_at.clone_from(&value);
        assert!(check_bundle(&trial).is_err(), "trial.starts_at {value:?}");
        let mut notice = base.clone();
        notice.notice = Some(Notice {
            starts_at: value.clone(),
        });
        assert!(check_bundle(&notice).is_err(), "notice.starts_at {value:?}");
    }
    let mut notice = base.clone();
    notice.notice = Some(Notice {
        starts_at: "2026-11-15T00:00:00Z".to_string(),
    });
    check_bundle(&notice).unwrap();
    // The generator refuses a malformed --generated-at before anything is written.
    assert!(generate(&GenerationInputs {
        bundle_version: 9,
        generated_at: "xxxxxxxxxxxxxxxxxxxx".to_string(),
        min_app_build: 301,
    })
    .is_err());
}

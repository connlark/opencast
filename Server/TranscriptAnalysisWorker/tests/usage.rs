use opencast_transcript_analysis_worker::counters;
use opencast_transcript_analysis_worker::job::JobSubmitRequest;
use opencast_transcript_analysis_worker::usage::{
    global_usage_object_name, release_counter_deltas, usage_limiter_route, usage_object_name,
    AcquiredAdmissions, AdmissionScope, ScopeReleaseOutcome, UsageLimitProfile, UsageLimiterRoute,
    UsageObjectNames, UsageReleaseRequest,
};
use opencast_transcript_analysis_worker::validation::{DailyUsage, UsageLimits};

#[test]
fn limiter_routes_admit_and_release_only() {
    assert_eq!(
        usage_limiter_route("/admit"),
        Some(UsageLimiterRoute::Admit)
    );
    assert_eq!(
        usage_limiter_route("/release"),
        Some(UsageLimiterRoute::Release)
    );
    for unknown in ["/", "", "/admit/", "/release/extra", "/refund", "/ADMIT"] {
        assert_eq!(usage_limiter_route(unknown), None, "{unknown:?}");
    }
}

#[test]
fn release_gives_back_one_request_and_its_tokens() {
    let usage = DailyUsage {
        request_count: 3,
        estimated_input_tokens: 9_000,
    };
    assert_eq!(
        usage.releasing(4_000),
        DailyUsage {
            request_count: 2,
            estimated_input_tokens: 5_000,
        }
    );
}

#[test]
fn release_saturates_at_zero() {
    let empty = DailyUsage::default();
    assert_eq!(empty.releasing(1), DailyUsage::default());
    let one = DailyUsage {
        request_count: 1,
        estimated_input_tokens: 10,
    };
    // Releasing more tokens than were ever admitted clamps instead of
    // wrapping, so a replayed or mismatched release can never mint credit.
    assert_eq!(one.releasing(u64::MAX), DailyUsage::default());
}

#[test]
fn admit_then_release_restores_the_prior_usage() {
    let before = DailyUsage {
        request_count: 11,
        estimated_input_tokens: 1_400_000,
    };
    let admitted = before
        .admitting_with_limits(50_000, UsageLimits::APP_ATTEST_KEY)
        .expect("twelfth request fits");
    assert_eq!(admitted.releasing(50_000), before);
    // At the cap after the admit — and back under it after the release.
    assert!(admitted
        .admitting_with_limits(1, UsageLimits::APP_ATTEST_KEY)
        .is_err());
    assert!(admitted
        .releasing(50_000)
        .admitting_with_limits(1, UsageLimits::APP_ATTEST_KEY)
        .is_ok());
}

#[test]
fn object_names_share_one_day_across_midnight() {
    let subject = "app-attest-key:abc";
    let before_midnight = 20_729;
    let names = UsageObjectNames::for_day(subject, before_midnight);
    assert_eq!(names.caller, usage_object_name(subject, before_midnight));
    assert_eq!(names.global, global_usage_object_name(before_midnight));
    // The pair is minted once; the global name never drifts to the next day
    // even if the clock does before the attempt releases.
    let after_midnight = before_midnight + 1;
    assert_ne!(names.global, global_usage_object_name(after_midnight));
    let (caller, global) = names.scopes(UsageLimitProfile::AppAttestKey, 777);
    assert_eq!(caller.object_name, names.caller);
    assert_eq!(caller.profile, UsageLimitProfile::AppAttestKey);
    assert_eq!(global.object_name, names.global);
    assert_eq!(global.profile, UsageLimitProfile::Global);
    assert_eq!(
        (caller.estimated_input_tokens, global.estimated_input_tokens),
        (777, 777)
    );
}

#[test]
fn acquired_admissions_hold_scopes_in_acquisition_order_and_release_once() {
    let caller = AdmissionScope {
        object_name: "caller".to_string(),
        profile: UsageLimitProfile::Bearer,
        estimated_input_tokens: 5,
    };
    let global = AdmissionScope {
        object_name: "global".to_string(),
        profile: UsageLimitProfile::Global,
        estimated_input_tokens: 5,
    };
    let mut acquired = AcquiredAdmissions::first(caller.clone());
    assert_eq!(acquired.scopes(), std::slice::from_ref(&caller));
    acquired.push(global.clone());
    assert_eq!(acquired.scopes(), &[caller.clone(), global.clone()]);
    // Release consumes the set: the scopes come out exactly once and the
    // value is gone, so no second cleanup path can address them.
    let released = acquired.into_scopes();
    assert_eq!(released, vec![caller, global]);
}

#[test]
fn release_counters_distinguish_full_from_partial_cleanup() {
    use ScopeReleaseOutcome::{Failed, Released};
    assert_eq!(release_counter_deltas(&[]), vec![]);
    assert_eq!(
        release_counter_deltas(&[Released]),
        vec![(counters::ADMISSION_RELEASES, 1)]
    );
    assert_eq!(
        release_counter_deltas(&[Released, Released]),
        vec![(counters::ADMISSION_RELEASES, 1)]
    );
    // Partial cleanup is not a success: no release credit, one failure per
    // scope left charged, whichever scope it was.
    assert_eq!(
        release_counter_deltas(&[Failed, Released]),
        vec![(counters::ADMISSION_RELEASE_FAILURES, 1)]
    );
    assert_eq!(
        release_counter_deltas(&[Released, Failed]),
        vec![(counters::ADMISSION_RELEASE_FAILURES, 1)]
    );
    assert_eq!(
        release_counter_deltas(&[Failed, Failed]),
        vec![(counters::ADMISSION_RELEASE_FAILURES, 2)]
    );
}

#[test]
fn release_request_serializes_like_admit() {
    let request = UsageReleaseRequest {
        estimated_input_tokens: 1234,
        profile: UsageLimitProfile::AppAttestKey,
    };
    let json = serde_json::to_string(&request).unwrap();
    assert_eq!(
        json,
        r#"{"estimated_input_tokens":1234,"profile":"app_attest_key"}"#
    );
    assert_eq!(
        serde_json::from_str::<UsageReleaseRequest>(&json).unwrap(),
        request
    );
}

#[test]
fn submit_request_without_global_object_name_still_parses() {
    // Deploy skew: a submit serialized by the previous worker version
    // carries no global object name; the DO falls back to the current day.
    let legacy = serde_json::json!({
        "usage_object_name": "transcript-analysis:v1:usage:20729:bearer:abc",
        "usage_profile": "bearer",
        "estimated_input_tokens": 10,
        "request": {
            "schema_version": 1,
            "request_id": "r",
            "episode_id": "e",
            "podcast_id": "p",
            "transcript": {
                "language_code": "en",
                "audio_duration": 1.0,
                "fingerprint": "f",
                "updated_at": "2026-01-01T00:00:00Z",
                "state": "completed",
                "segment_count": 0
            },
            "segments": []
        }
    });
    let parsed: JobSubmitRequest = serde_json::from_value(legacy).unwrap();
    assert_eq!(parsed.global_usage_object_name, None);
    let round_trip: JobSubmitRequest =
        serde_json::from_str(&serde_json::to_string(&parsed).unwrap()).unwrap();
    assert_eq!(round_trip, parsed);
}

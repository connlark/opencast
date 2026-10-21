use opencast_ad_analysis_worker::{policy::*, types::MAX_SEGMENTS, v3_windowing::*};

#[test]
fn medium_calls_use_available_budget_without_extending_the_job_deadline() {
    assert_eq!(V3_THINKING, "medium");
    assert_eq!(AnalysisPolicy::V3.call_timeout_seconds(762), 120);
    assert_eq!(AnalysisPolicy::V3.call_timeout_seconds(1566), 120);
    assert_eq!(AnalysisPolicy::V3.call_timeout_seconds(2840), 120);
    assert_eq!(AnalysisPolicy::V3.call_timeout_seconds(2841), 91);
    assert_eq!(AnalysisPolicy::V3.call_timeout_seconds(5560), 91);
    assert_eq!(AnalysisPolicy::V3.call_timeout_seconds(5561), 60);
    assert_eq!(AnalysisPolicy::V3.call_timeout_seconds(MAX_SEGMENTS), 60);
    for count in 1..=MAX_SEGMENTS {
        let timeout = AnalysisPolicy::V3.call_timeout_seconds(count);
        let waves = window_count(count).div_ceil(CONCURRENT_WINDOWS) as u64;
        let window_seconds = timeout * (V3_INITIAL_ATTEMPTS + V3_REPAIR_ATTEMPTS) as u64
            + V3_MAX_BACKOFF_SECONDS * (V3_INITIAL_ATTEMPTS - 1) as u64;
        assert!((60..=120).contains(&timeout));
        assert!(waves * window_seconds <= V3_EXECUTION_SECONDS);
        assert_eq!(AnalysisPolicy::V2.call_timeout_seconds(count), 60);
    }
    const { assert!(V3_EXECUTION_SECONDS + 30 <= 600) };
}

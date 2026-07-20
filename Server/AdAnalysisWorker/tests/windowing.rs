use opencast_ad_analysis_worker::types::{
    AdAnalysisRequest, TranscriptMetadata, TranscriptSegment, MAX_SEGMENTS, SCHEMA_VERSION,
};
use opencast_ad_analysis_worker::windowing::{
    analysis_windows, window_count, FALLBACK_WINDOW_OVERLAP, FALLBACK_WINDOW_SEGMENTS,
    SINGLE_WINDOW_MAX_SEGMENTS,
};

#[test]
fn constants_match_the_step4_contract() {
    assert_eq!(SINGLE_WINDOW_MAX_SEGMENTS, 2_000);
    assert_eq!(FALLBACK_WINDOW_SEGMENTS, 2_000);
    assert_eq!(FALLBACK_WINDOW_OVERLAP, 200);
}

#[test]
fn normal_episodes_are_single_shot() {
    // 240-segment windowing manufactured the island bug; anything that fits
    // 2000 segments goes to Gemini in one call with the original request_id.
    for segment_count in [10, 1_160, 1_999, 2_000] {
        let request = sample_request(segment_count);
        let windows = analysis_windows(&request);
        assert_eq!(windows.len(), 1, "{segment_count} segments");
        assert_eq!(windows[0], request);
        assert_eq!(window_count(segment_count), 1);
    }
}

#[test]
fn oversized_requests_split_into_overlapping_fallback_windows() {
    let request = sample_request(2_001);
    let windows = analysis_windows(&request);

    assert_eq!(windows.len(), 2);
    assert_eq!(window_count(2_001), 2);
    assert_eq!(windows[0].request_id, "request-1-w000");
    assert_eq!(windows[1].request_id, "request-1-w001");
    assert_eq!(windows[0].segments.len(), FALLBACK_WINDOW_SEGMENTS);
    assert_eq!(
        windows[0].transcript.segment_count,
        FALLBACK_WINDOW_SEGMENTS
    );
    assert_eq!(
        windows[1].segments.first().map(|segment| segment.id),
        Some((FALLBACK_WINDOW_SEGMENTS - FALLBACK_WINDOW_OVERLAP) as i64)
    );
    assert_eq!(
        windows[1].segments.last().map(|segment| segment.id),
        Some(2_000)
    );
}

#[test]
fn max_segment_requests_use_at_most_four_windows() {
    let request = sample_request(MAX_SEGMENTS);
    let windows = analysis_windows(&request);

    assert_eq!(windows.len(), 4);
    assert_eq!(window_count(MAX_SEGMENTS), 4);
    // Stride 1800: starts at 0, 1800, 3600, 5400.
    assert_eq!(windows[0].segments.first().map(|s| s.id), Some(0));
    assert_eq!(windows[1].segments.first().map(|s| s.id), Some(1_800));
    assert_eq!(windows[2].segments.first().map(|s| s.id), Some(3_600));
    assert_eq!(windows[3].segments.first().map(|s| s.id), Some(5_400));
    assert_eq!(
        windows[3].segments.last().map(|s| s.id),
        Some((MAX_SEGMENTS - 1) as i64)
    );
}

fn sample_request(segment_count: usize) -> AdAnalysisRequest {
    AdAnalysisRequest {
        schema_version: SCHEMA_VERSION,
        async_supported: false,
        request_id: "request-1".to_string(),
        episode_id: "episode-1".to_string(),
        podcast_id: "podcast-1".to_string(),
        episode_title: Some("Episode".to_string()),
        podcast_title: Some("Podcast".to_string()),
        transcript: TranscriptMetadata {
            language_code: "en".to_string(),
            audio_duration: segment_count as f64,
            model_identifier: Some("large-v3".to_string()),
            model_version: Some("v1".to_string()),
            model_tree_sha256: Some("abc".to_string()),
            fingerprint: "fingerprint".to_string(),
            updated_at: "2026-07-01T00:00:00Z".to_string(),
            state: "completed".to_string(),
            segment_count,
        },
        segments: (0..segment_count)
            .map(|index| TranscriptSegment {
                id: index as i64,
                start: index as f64,
                end: index as f64 + 0.9,
                text: format!("Segment {index} sponsor text."),
            })
            .collect(),
    }
}

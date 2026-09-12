//! Local-attention windows for v3, independent of the frozen v2 control.
use crate::types::AdAnalysisRequest;

pub const WINDOW_SEGMENTS: usize = 800;
pub const OVERLAP_SEGMENTS: usize = 120;
pub const CONCURRENT_WINDOWS: usize = 4;

pub fn window_count(count: usize) -> usize {
    1 + count
        .saturating_sub(WINDOW_SEGMENTS)
        .div_ceil(WINDOW_SEGMENTS - OVERLAP_SEGMENTS)
}

pub fn analysis_windows(request: &AdAnalysisRequest) -> Vec<AdAnalysisRequest> {
    (0..window_count(request.segments.len()))
        .map(|index| {
            let start = index * (WINDOW_SEGMENTS - OVERLAP_SEGMENTS);
            let end = (start + WINDOW_SEGMENTS).min(request.segments.len());
            let mut window = request.clone();
            window.segments = request.segments[start..end].to_vec();
            window.transcript.segment_count = window.segments.len();
            window
        })
        .collect()
}

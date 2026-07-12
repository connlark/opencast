use crate::types::AdAnalysisRequest;

/// Single-shot analysis is the whole fix for the island bug: 240-segment
/// windows drove hallucinated spans and MAX_TOKENS degeneration (step-4
/// research §3/§4b). One Gemini call for anything <= 2000 segments; a coarse
/// fallback split above that (`MAX_SEGMENTS` 6000 => at most 4 windows).
pub const SINGLE_WINDOW_MAX_SEGMENTS: usize = 2_000;
pub const FALLBACK_WINDOW_SEGMENTS: usize = 2_000;
pub const FALLBACK_WINDOW_OVERLAP: usize = 200;

pub fn analysis_windows(request: &AdAnalysisRequest) -> Vec<AdAnalysisRequest> {
    if request.segments.len() <= SINGLE_WINDOW_MAX_SEGMENTS {
        return vec![request.clone()];
    }

    let stride = FALLBACK_WINDOW_SEGMENTS - FALLBACK_WINDOW_OVERLAP;
    let mut windows = Vec::new();
    let mut start = 0usize;
    let mut index = 0usize;
    while start < request.segments.len() {
        let end = request
            .segments
            .len()
            .min(start.saturating_add(FALLBACK_WINDOW_SEGMENTS));
        let mut window = request.clone();
        window.request_id = format!("{}-w{index:03}", request.request_id);
        window.segments = request.segments[start..end].to_vec();
        window.transcript.segment_count = window.segments.len();
        windows.push(window);

        if end == request.segments.len() {
            break;
        }
        start = start.saturating_add(stride);
        index = index.saturating_add(1);
    }

    windows
}

/// Window count for a given segment total (used by validation's
/// degenerate-span-count cap without materializing windows).
pub fn window_count(segment_count: usize) -> usize {
    if segment_count <= SINGLE_WINDOW_MAX_SEGMENTS {
        return 1;
    }
    let stride = FALLBACK_WINDOW_SEGMENTS - FALLBACK_WINDOW_OVERLAP;
    let mut count = 1usize;
    let mut start = 0usize;
    while start.saturating_add(FALLBACK_WINDOW_SEGMENTS) < segment_count {
        start = start.saturating_add(stride);
        count = count.saturating_add(1);
    }
    count
}

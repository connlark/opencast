//! The thinking-level guard, in its own module so host tests reach it
//! (`analysis.rs` is wasm-only — it holds worker Fetch types).

/// Serving policy keyed to model-facing id count, not tokens. Evaluation found
/// id-discipline drift at 873 and 1,399 ids, so medium is not claimed to be
/// deterministically clean below this threshold; every invalid response gets
/// high-on-retry protection. Counts above it start at high.
pub const THINKING_ESCALATION_SEGMENT_COUNT: usize = 1_399;

pub fn thinking_level_for_segment_count(segment_count: usize) -> &'static str {
    if segment_count > THINKING_ESCALATION_SEGMENT_COUNT {
        "high"
    } else {
        "medium"
    }
}

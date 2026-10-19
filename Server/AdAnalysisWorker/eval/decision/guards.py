"""Structural guards ported from the Rust validator (read-only sources).

`test_guards.py` regex-extracts every constant below from `src/promo_v3.rs`
and `src/validation.rs` and fails on drift. A violation fails the whole
episode closed, like v3: `complete = false, spans = []` with a `decision_*`
warning. A span over 600 s is treated as evidence of bridging, never split.
"""

from __future__ import annotations

import math

# src/promo_v3.rs
MAX_BREAK_SECONDS = 600.0
MAX_MIXED_BOUNDARY_SECONDS = 10.0
CONFIDENCE_TIER = 0.8  # tier split in merging, and the covers-request literal
COVERS_REQUEST_FRACTION = 0.8  # `request.segments.len() as f64 * 0.8`
# src/validation.rs
MAX_SPAN_REQUEST_COVERAGE = 0.8
AD_BUDGET_EPISODE_FRACTION = 0.40
AD_BUDGET_FLOOR_SECONDS = 600.0
DECLARED_DURATION_MIN_FRACTION = 0.5


def episode_ad_budget_seconds(transcript):
    """Port of `validation::episode_ad_budget_seconds`."""
    audio = float(transcript.get("audio_duration") or 0.0)
    declared = transcript.get("declared_duration")

    def base(runtime):
        return max(AD_BUDGET_EPISODE_FRACTION * runtime, AD_BUDGET_FLOOR_SECONDS)

    if (
        isinstance(declared, (int, float))
        and math.isfinite(declared)
        and math.isfinite(audio)
        and declared < audio
        and declared >= DECLARED_DURATION_MIN_FRACTION * audio
    ):
        return base(declared) + (audio - declared)
    return base(audio)


def covered_seconds(spans):
    """Each second once, both confidence tiers (v3's budget fold)."""
    total, covered_end = 0.0, float("-inf")
    for span in sorted(spans, key=lambda s: (s["start_time"], s["end_time"])):
        total += max(0.0, span["end_time"] - max(span["start_time"], covered_end))
        covered_end = max(covered_end, span["end_time"])
    return total


def check(request, spans, positions):
    """Return `{ok, warnings, budget_s, covered_s, ...}`.

    `positions` maps segment id -> array index (the harness's own mapping).
    """
    count = len(request["segments"])
    warnings = []
    for span in spans:
        tag = f"{span['start_segment_id']}-{span['end_segment_id']}"
        if span["end_time"] - span["start_time"] > MAX_BREAK_SECONDS:
            warnings.append(f"decision_break_duration:{tag}")
        width = positions[span["end_segment_id"]] - positions[span["start_segment_id"]] + 1
        if width > count * COVERS_REQUEST_FRACTION:
            warnings.append(f"decision_covers_request:{tag}")
    budget = episode_ad_budget_seconds(request.get("transcript") or {})
    covered = covered_seconds(spans)
    if covered > budget:
        warnings.append("decision_ad_budget_exceeded")
    return {
        "ok": not warnings,
        "warnings": warnings,
        "budget_s": round(budget, 3),
        "covered_s": round(covered, 3),
        "max_break_s": MAX_BREAK_SECONDS,
        "covers_request_fraction": COVERS_REQUEST_FRACTION,
    }

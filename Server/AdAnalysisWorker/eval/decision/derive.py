"""Span derivation: pure functions from probabilities to v3-shaped spans.

Input is a `probabilities.json` document (chunk p's, and for the two-stage
design the per-segment refinement p's and the per-span confirmation p's);
`rederive.py` replays the same functions with other `DeriveParams` and no
inference. Nothing here does id arithmetic: runs, regions and boundaries are
array indices, translated to ids only when a span is emitted.

Rules (`DeriveParams()` is the FROZEN set, fixed before the first paid wave
from the E0 oracle sweep: pre-registered values except `min_run_s` 15 -> 5
(the 6.8 s carousel promo; v3 counts short genuine promos, 5 s keeps a floor
against one-segment noise) and `refine_threshold` 0.50 -> 0.51 (a tie-break
against the oracle's 0.5 optional segments, which otherwise pull inter-segment
silence into zones; it also zeroes sn1094's FP). `DeriveParams.sha256()` is
recorded in every `fixture.json`; `PREREGISTERED` keeps the original set for
rederive comparisons.

* Schmitt trigger over chunk order: enter at `p_ad >= t_on` with
  `p_content <= content_enter_max`; stay while `p_ad >= t_off` and
  `p_content <= content_stay_max` (the content facet's second threshold: a
  chunk the model calls more likely program than not ends the run).
* Bridge at most `max_bridge_chunks` CONSECUTIVE chunks with
  `bridge_min_p <= p_ad < t_off` (content facet not objecting) when the next
  chunk stays; never two. Bridged chunks are excluded from the confidence.
* Single-chunk runs install only at `p_ad >= single_chunk_min_p`; runs whose
  chunk extent is shorter than `min_run_s` are dropped.
* Confidence = min over the run's non-bridged chunks (v3: confidence that the
  WHOLE interval is promotional, so one doubtful chunk drags the span under
  the 0.8 install floor). Mean and p10 are archived, never installed.
* Two-stage (d): per-segment p over the first and last chunk +/- 1 of each
  run, a `median_window` median filter (edge-replicated), boundary = first /
  last segment with filtered p >= `refine_threshold` (raw p when the filter
  erases every segment of a region and `median_fallback_raw`), v3's mixed
  boundary rule (a boundary segment with raw p < t_on is "mixed": included
  when <= `mixed_boundary_max_s`, else trimmed one segment inward), then one
  confirmation question per span: installed only at p >= `confirm_min_p`.
  Confidence = min(confirm p, the run's non-bridged INTERIOR chunks: wholly
  inside the refined span and outside both refine regions), because the edge
  chunks' chunk-level p is superseded by the segment evidence and by the
  whole-passage confirmation (`refined_confidence_scope`; "inside" keeps
  every chunk wholly inside, which E0 shows drags an optional tail chunk at
  0.5 under the install floor).
* Two-stage over the choice localiser (`d_c`): (c)'s chunk P(ad) and
  P(content) find the runs, then exactly (d)'s refinement, confirmation and
  confidence rule (the content facet of b' is not asked).
* Chunk-choice (c): P(ad) = promotional mass + transition mass only when the
  chunk or a neighbour is promotional (never max-class: mass splits across
  the promotional options); p_content = P(content); kind by majority.
* Overlapping or adjacent spans merge within a confidence tier (v3), then the
  structural guards run; any violation fails the episode closed.
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass, fields, replace

from . import guards
from .chunking import region
from .common import sha256_json
from .questions import KIND_OF_CHOICE, PROMOTIONAL_CHOICES

DESIGNS = ("b_prime", "c", "d", "d_c", "a", "h1", "h1_c")
TWO_STAGE = ("d", "d_c")
HYBRID = ("h1", "h1_c")
# The chunk design whose derivation localises (or IS the spans of) each design.
LOCALISER = {"a": "b_prime", "h1": "b_prime", "h1_c": "c"}


def chunk_design(design):
    """The chunk-stage design whose answers a design's probabilities hold."""
    return "c" if design in ("c", "d_c", "h1_c") else "b_prime"


def two_stage(design):
    return design in TWO_STAGE


@dataclass(frozen=True)
class DeriveParams:
    t_on: float = 0.80
    t_off: float = 0.50
    content_enter_max: float = 0.30
    content_stay_max: float = 0.50
    max_bridge_chunks: int = 1
    bridge_min_p: float = 0.25
    single_chunk_min_p: float = 0.90
    min_run_s: float = 5.0
    mixed_boundary_max_s: float = guards.MAX_MIXED_BOUNDARY_SECONDS
    refine_threshold: float = 0.51
    median_window: int = 3
    median_fallback_raw: bool = True
    confirm_min_p: float = 0.80
    confidence: str = "min_non_bridged"
    # (d) only: which run chunks join the confirmation p in the min.
    # "interior" = non-bridged chunks wholly inside the refined span and
    # outside both refine regions (edge chunks are superseded by segment
    # evidence and the confirmation); "inside" = every non-bridged chunk
    # wholly inside the refined span.
    refined_confidence_scope: str = "interior"

    def __post_init__(self):
        # JSON overrides arrive as int 5 or float 5.0; coerce to the declared
        # type so the same values always give the same sha256.
        for f in fields(self):
            value = getattr(self, f.name)
            if f.type == "float" and isinstance(value, int) and not isinstance(value, bool):
                object.__setattr__(self, f.name, float(value))
            elif f.type == "int" and isinstance(value, float) and value.is_integer():
                object.__setattr__(self, f.name, int(value))

    def as_dict(self):
        return asdict(self)

    def sha256(self):
        return sha256_json(self.as_dict())

    def with_(self, **changes):
        return replace(self, **changes)

    @classmethod
    def from_dict(cls, doc):
        return cls(**{k: v for k, v in doc.items() if k != "sha256"})


# The brief's pre-registered values, kept for rederive comparisons.
PREREGISTERED = DeriveParams(min_run_s=15.0, refine_threshold=0.50)


# --- chunk probabilities -------------------------------------------------


def chunk_probabilities(chunk_answers, design, params):
    """[(p_ad, p_content or None, kind or None)] per chunk, in chunk order."""
    if design != "c":
        return [(c["p_ad"], c.get("p_content"), None) for c in chunk_answers]
    promo = [sum(c["choice"].get(k, 0.0) for k in PROMOTIONAL_CHOICES) for c in chunk_answers]
    out = []
    for k, c in enumerate(chunk_answers):
        near = any(
            0 <= m < len(promo) and promo[m] >= params.t_off for m in (k - 1, k, k + 1)
        )
        transition = c["choice"].get("transition", 0.0)
        kind = max(PROMOTIONAL_CHOICES, key=lambda key: c["choice"].get(key, 0.0))
        out.append((promo[k] + (transition if near else 0.0), c["choice"].get("content", 0.0), kind))
    return out


# --- runs ----------------------------------------------------------------


def _ok_content(p_content, limit):
    return p_content is None or p_content <= limit


def find_runs(probs, params):
    """Schmitt trigger with single-chunk bridging over chunk order."""
    n = len(probs)

    def enters(k):
        return probs[k][0] >= params.t_on and _ok_content(probs[k][1], params.content_enter_max)

    def stays(k):
        return probs[k][0] >= params.t_off and _ok_content(probs[k][1], params.content_stay_max)

    def bridgeable(k):
        return params.bridge_min_p <= probs[k][0] < params.t_off and _ok_content(
            probs[k][1], params.content_stay_max
        )

    runs, k = [], 0
    while k < n:
        if not enters(k):
            k += 1
            continue
        first = last = k
        bridged = []
        j = k + 1
        while j < n:
            if stays(j):
                last, j = j, j + 1
                continue
            m = j
            while m < n and m - j < params.max_bridge_chunks and bridgeable(m):
                m += 1
            if m > j and m < n and stays(m):
                bridged.extend(range(j, m))
                last, j = m, m + 1
                continue
            break
        runs.append({"first": first, "last": last, "bridged": bridged})
        k = last + 1
    return runs


def filter_runs(runs, chunks, probs, params):
    """Split runs into (kept, dropped-with-reason)."""
    kept, dropped = [], []
    for run in runs:
        duration = chunks[run["last"]].end - chunks[run["first"]].start
        if run["first"] == run["last"] and probs[run["first"]][0] < params.single_chunk_min_p:
            dropped.append({**run, "reason": "single_chunk_below_min_p"})
        elif duration < params.min_run_s:
            dropped.append({**run, "reason": "shorter_than_min_run"})
        else:
            kept.append(run)
    return kept, dropped


def run_key(run):
    return f"{run['first']}-{run['last']}"


# --- refinement (two-stage design) ---------------------------------------


def refine_regions(run, chunks):
    """[(lo, hi)] array-index regions for one run: start and end chunk +/- 1,
    one region when they overlap or touch."""
    s = region(chunks, run["first"] - 1, run["first"] + 1)
    e = region(chunks, run["last"] - 1, run["last"] + 1)
    if s[1] + 1 >= e[0]:
        return [(s[0], max(s[1], e[1]))]
    return [s, e]


def median_filter(values, window):
    if window <= 1:
        return list(values)
    half = window // 2
    out = []
    for i in range(len(values)):
        neighbourhood = [values[min(len(values) - 1, max(0, j))] for j in range(i - half, i + half + 1)]
        out.append(sorted(neighbourhood)[half])
    return out


def _passing(lo, hi, p_seg, params):
    raw = [p_seg[i] for i in range(lo, hi + 1)]
    filtered = median_filter(raw, params.median_window)
    hits = [lo + n for n, p in enumerate(filtered) if p >= params.refine_threshold]
    if not hits and params.median_fallback_raw:
        hits = [lo + n for n, p in enumerate(raw) if p >= params.refine_threshold]
        return hits, bool(hits)
    return hits, False


def refine_run(run, chunks, segments, p_seg, params):
    """Segment-level (start, end, notes) for one run, or (None, None, notes).

    `p_seg` maps array index -> p for every index of the run's regions;
    a missing index means no inference for this run (rederive): the chunk
    boundary on that side is kept and the span is marked `refine_missing`.
    """
    notes = []
    regions = refine_regions(run, chunks)
    chunk_start, chunk_end = chunks[run["first"]].first, chunks[run["last"]].last
    available = [all(i in p_seg for i in range(lo, hi + 1)) for lo, hi in regions]

    def search(index, pick):
        lo, hi = regions[index]
        if not available[index]:
            notes.append("refine_missing")
            return None
        hits, fallback = _passing(lo, hi, p_seg, params)
        if fallback:
            notes.append("median_fallback_raw")
        return pick(hits) if hits else None

    if len(regions) == 1:
        start = search(0, min)
        end = start if start is None else (chunk_end if not available[0] else search(0, max))
        if not available[0]:
            start, end = chunk_start, chunk_end
        elif start is None:
            notes.append("refine_rejected")
            return None, None, notes
    else:
        start = search(0, min)
        end = search(1, max)
        if start is None:
            if available[0]:
                notes.append("refine_start_none")
                start = regions[0][1] + 1
            else:
                start = chunk_start
        if end is None:
            if available[1]:
                notes.append("refine_end_none")
                end = regions[1][0] - 1
            else:
                end = chunk_end
    if start > end:
        notes.append("refine_rejected")
        return None, None, notes
    # v3's mixed-boundary rule, one segment at most, never across segments.
    for side in ("start", "end"):
        index = start if side == "start" else end
        p = p_seg.get(index)
        if p is None or p >= params.t_on:
            continue
        duration = segments[index]["end"] - segments[index]["start"]
        if math.isfinite(duration) and 0 < duration <= params.mixed_boundary_max_s:
            notes.append(f"short_mixed_{side}_included")
        elif side == "start":
            start += 1
            notes.append("mixed_start_trimmed")
        else:
            end -= 1
            notes.append("mixed_end_trimmed")
    if start > end:
        notes.append("mixed_boundary_unresolvable")
        return None, None, notes
    return start, end, notes


# --- spans ---------------------------------------------------------------


def _p10(values):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.1 * len(ordered)) - 1)] if ordered else None


def _span(segments, chunks, probs, run, start, end, design, extra, params):
    ids = [segments[start]["id"], segments[end]["id"]]
    core = [k for k in range(run["first"], run["last"] + 1) if k not in run["bridged"]]
    if two_stage(design):
        inside = [k for k in core if chunks[k].first >= start and chunks[k].last <= end]
        if params.refined_confidence_scope == "interior":
            edges = set(range(run["first"] - 1, run["first"] + 2)) | set(range(run["last"] - 1, run["last"] + 2))
            inside = [k for k in inside if k not in edges]
        elif params.refined_confidence_scope != "inside":
            raise ValueError("Unknown refined_confidence_scope")
        values = [probs[k][0] for k in inside]
        confirm = extra.get("confirm_p")
        confidence = None if confirm is None else min([confirm, *values])
    else:
        values = [probs[k][0] for k in core]
        confidence = min(values)
    kinds = [probs[k][2] for k in core if probs[k][2]]
    kind = KIND_OF_CHOICE[max(set(kinds), key=kinds.count)] if kinds else None
    all_core = [probs[k][0] for k in core]
    return {
        "kind": kind,
        "label": f"decision break {chunks[run['first']].label}-{chunks[run['last']].label}",
        "start_segment_id": ids[0],
        "end_segment_id": ids[1],
        "start_time": segments[start]["start"],
        "end_time": segments[end]["end"],
        "confidence": None if confidence is None else round(confidence, 6),
        "evidence_quote": "",
        "start_boundary": None,
        "end_boundary": None,
        "decision": {
            "design": design,
            "run_chunks": [run["first"], run["last"]],
            "bridged_chunks": list(run["bridged"]),
            "chunks": [
                {
                    "label": chunks[k].label,
                    "p_ad": round(probs[k][0], 6),
                    "p_content": None if probs[k][1] is None else round(probs[k][1], 6),
                    "bridged": k in run["bridged"],
                }
                for k in range(run["first"], run["last"] + 1)
            ],
            "segments": [start, end],
            "confidence_rule": f"min(confirm, non-bridged {params.refined_confidence_scope} chunks)" if two_stage(design) else "min non-bridged chunks",
            "confidence_min_all": round(min(all_core), 6),
            "confidence_mean": round(sum(all_core) / len(all_core), 6),
            "confidence_p10": round(_p10(all_core), 6),
            **extra,
        },
    }


def merge_spans(spans, positions):
    """v3's tier merge: overlapping or truly adjacent spans, same tier only."""
    tiers = {True: [], False: []}
    for span in sorted(spans, key=lambda s: (s["start_time"], s["end_time"])):
        tier = tiers[span["confidence"] >= guards.CONFIDENCE_TIER]
        if tier:
            last = tier[-1]
            adjacent = (
                positions[span["start_segment_id"]] <= positions[last["end_segment_id"]] + 1
                and span["start_time"] - last["end_time"] <= 1.0
            )
            if adjacent:
                if span["end_time"] > last["end_time"]:
                    last["end_time"] = span["end_time"]
                    last["end_segment_id"] = span["end_segment_id"]
                last["confidence"] = min(last["confidence"], span["confidence"])
                last["decision"].setdefault("merged", []).append(span["decision"])
                continue
        tier.append(span)
    return sorted(tiers[True] + tiers[False], key=lambda s: (s["start_time"], s["end_time"]))


def confirm_key(start, end):
    return f"{start}-{end}"


def derive(request, chunks, doc, design, params):
    """The whole derivation from a probabilities document. Pure."""
    segments = request["segments"]
    positions = {s["id"]: i for i, s in enumerate(segments)}
    probs = chunk_probabilities(doc["chunks"], chunk_design(design), params)
    runs = find_runs(probs, params)
    kept, dropped = filter_runs(runs, chunks, probs, params)
    p_seg = {int(k): v for k, v in (doc.get("refine") or {}).items()}
    confirms = doc.get("confirm") or {}
    spans, rejected, notices = [], [], []
    for run in kept:
        if two_stage(design):
            start, end, notes = refine_run(run, chunks, segments, p_seg, params)
            if start is None:
                rejected.append({**run, "reason": ",".join(notes)})
                continue
            confirm = confirms.get(confirm_key(start, end))
            if confirm is None:
                notes.append("confirm_missing")
            elif confirm < params.confirm_min_p:
                rejected.append({**run, "segments": [start, end], "reason": "confirm_below_min_p", "confirm_p": confirm})
                continue
            extra = {"refine_notes": notes, "confirm_p": confirm}
            notices += [f"decision_{n}:{run_key(run)}" for n in notes]
        else:
            start, end = chunks[run["first"]].first, chunks[run["last"]].last
            extra = {}
        span = _span(segments, chunks, probs, run, start, end, design, extra, params)
        if span["confidence"] is None:
            rejected.append({**run, "segments": [start, end], "reason": "no_confidence"})
            continue
        spans.append(span)
    fallback = [
        s["decision"]["run_chunks"] for s in spans if "median_fallback_raw" in (s["decision"].get("refine_notes") or [])
    ] + [[r["first"], r["last"]] for r in rejected if "median_fallback_raw" in str(r.get("reason", ""))]
    merged = merge_spans(spans, positions)
    checked = guards.check(request, merged, positions)
    complete = checked["ok"]
    return {
        "design": design,
        "derive_params": {**params.as_dict(), "sha256": params.sha256()},
        "chunk_probabilities": [
            {"label": chunks[k].label, "p_ad": p[0], "p_content": p[1], "kind": p[2]}
            for k, p in enumerate(probs)
        ],
        "runs": runs,
        "dropped_runs": dropped,
        "rejected_runs": rejected,
        "raw_spans": spans,
        "median_fallback_raw_fired": fallback,
        "confidence_definitions": {
            "installed": "min(confirm, non-bridged interior chunks)" if two_stage(design) else "min non-bridged chunks",
            "archived": ["confidence_min_all (every non-bridged chunk incl. boundary chunks)", "confidence_mean", "confidence_p10"],
        },
        "guards": checked,
        "validation": {
            "complete": complete,
            "spans": merged if complete else [],
            "warnings": checked["warnings"],
            "notices": notices,
        },
    }


def plan_refinement(request, chunks, doc, design, params):
    """Runs that need segment p's, and their regions (the live pipeline asks
    exactly these before calling `derive`)."""
    probs = chunk_probabilities(doc["chunks"], chunk_design(design), params)
    kept, _ = filter_runs(find_runs(probs, params), chunks, probs, params)
    return [{"run": run, "regions": refine_regions(run, chunks)} for run in kept]


def plan_confirmation(request, chunks, doc, params, design="d"):
    """(start, end) array ranges that need a confirmation p (two-stage designs)."""
    segments = request["segments"]
    probs = chunk_probabilities(doc["chunks"], chunk_design(design), params)
    kept, _ = filter_runs(find_runs(probs, params), chunks, probs, params)
    p_seg = {int(k): v for k, v in (doc.get("refine") or {}).items()}
    out = []
    for run in kept:
        start, end, _ = refine_run(run, chunks, segments, p_seg, params)
        if start is not None:
            out.append({"run": run, "segments": (start, end)})
    return out

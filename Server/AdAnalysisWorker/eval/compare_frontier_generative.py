#!/usr/bin/env python3
"""Frontier comparison for the 2026-10 generative ad-analysis bakeoff.

Reads `run.py` run trees (`<tag>/<fixture>-<repeat>/summary.json` plus the
archived `window-*/` and `repair-*/` documents) and, as read-only references,
`replay.py` revalidation trees (`<fixture>-<repeat>.json`, kind
`offline_revalidation_not_new_model_trial`, whose `source` summary supplies
the archived calls). Every run is re-scored with `run.measure` against the
frozen manifest's ground truth (the archived `metrics` are checked against
the re-score, never trusted blindly), then aggregated per candidate.

Nothing here is a gate. The hard-disqualification classes are ported from
the 2026-09 Gemini 3.8 Flash bakeoff judge (`compare_flash38_bakeoff.py`,
not imported: it drags in the July harness) and reported as columns:

  * non-STOP finish: a call whose finish reason is not the provider's normal
    completion (`STOP`, `completed`, `end_turn`, `stop`).
  * malformed output: a call with an unparseable answer, or a validation
    (initial, repair or final) carrying a malformed-answer code.
  * negative hit: a run whose installed zones overlap labelled negatives by
    more than 1 s.
  * junk zone: an installed zone overlapping pods and optional regions by at
    most 0.5 s (the July `junk_zones` rule).
  * HTTP 400: an archived error body carrying a 400 / invalid-request shape.
  * schema key leak: an archived answer with a span (or top-level) key outside
    the v3 schema.

Run classes: `complete` (validation complete), `incomplete` (the v3 validator
refused after the repair turn; the serving path installs nothing),
`transport` (HTTP, timeout, context exceeded: the serving path would fall
back) and `aborted` (a harness or ledger refusal such as a cap reopen; not a
model result, excluded from every rate and listed). Pod coverage, whole-pod
misses and jitter are read from complete runs only; an incomplete run is
counted in `complete %` instead of as a miss on every pod.

Cost: `$/episode` is the mean `cost_usd` over the real-recording fixtures
(`EPISODE_FIXTURES`; the Fortinet excerpt, the derived long window and the
synthetics are excluded), measured and no-cache (repeats minutes apart hit
the vendors' implicit prompt caches, which one production analysis per
episode would not, so every cached token is also priced at the input rate);
`$/day` multiplies the no-cache mean by `--episodes-per-day` (50), and `$/day from 2027-01-01` doubles every Gemini 3.x row (promotional
prices expire 2026-12-31; other vendors unchanged). Latency is the
provider-call wall time only (`latency_ms`, no countTokens round trip),
nearest-rank p95 over every call.

Outputs: `--out-md` (COMPARISON.md: a summary, the disqualifier columns and
one section per candidate), `--out-json` (the sidecar with every number) and
`--frontier-md` (FRONTIER-generative.md: the pre-registered frontier columns,
first candidate first). Stdlib only.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import re
import statistics
import sys
from pathlib import Path

EVAL = Path(__file__).resolve().parent
if str(EVAL) not in sys.path:
    sys.path.insert(0, str(EVAL))

import budget  # noqa: E402
import run as harness  # noqa: E402

EPISODE_FIXTURES = (
    "bugged-tiny",
    "bugged-txt",
    "sn1085",
    "audio-illusion",
    "sn1094",
    "blunderbuss-exact",
    "upfirst-economic-warfare",
    "searchengine-the-chosen-one",
    "serial-s01e01-the-alibi",
)
NEGATIVE_FIXTURE = "sn1085-fortinet-negative"
COST_MAX_FIXTURE = "sn1094"
JITTER_FIXTURE = "bugged-tiny"
DOPPEL_POD = [989, 1036]
FINAL_BREAK_POD = [1198, 1290]
NORMAL_FINISH = frozenset({"STOP", "completed", "end_turn", "stop"})
MALFORMED_CODES = frozenset(
    {"v3_malformed_model_json", "v3_malformed_response", "v3_invalid_answer_text"}
)
V3_SPAN_KEYS = frozenset(
    {
        "kind",
        "label",
        "start_segment_id",
        "end_segment_id",
        "confidence",
        "evidence_quote",
        "start_quote",
        "end_quote",
    }
)
V3_TOP_KEYS = frozenset({"spans"})
WHOLE_POD_MISS = 0.5
NEGATIVE_HIT_S = 1.0
JUNK_OVERLAP_S = 0.5
PARTIAL_POD = 0.95
FP_NOTE_S = 10.0
JITTER_NOTE_S = 1.0
FRONTIER_CLAUSES = 4
HTTP_400 = re.compile(
    r'"code"\s*:\s*400\b|INVALID_ARGUMENT|invalid_request_error|HTTP Error 400|\b400 Bad Request'
)
ABORT_MARKERS = (
    "Reopen the ledger",
    "exceeding remaining budget",
    "exceeded its reservation",
    "Run exists",
    "Eval binary changed",
    "binary is missing or stale",
    "Ledger cap or prices changed",
    "Provider exceeded reservation",
)


def read_json(path):
    return json.loads(Path(path).read_text())


def percentile(values, fraction):
    """Nearest-rank percentile (for n <= 20 the p95 is the maximum)."""
    values = [v for v in values if v is not None]
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(1, math.ceil(fraction * len(ordered))) - 1]


def code_of(issue):
    return str(issue).split(":", 1)[0].strip()


def overlap(a, b):
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


# --- inputs -----------------------------------------------------------------


def load_manifest(path):
    path = Path(path)
    manifest = read_json(path)
    fixtures = {}
    for entry in manifest["fixtures"]:
        request_path = path.parent / entry["request"]
        request = read_json(request_path)
        segments = request["segments"]
        fixtures[entry["name"]] = {
            "entry": entry,
            "request": request,
            "request_sha256": hashlib.sha256(request_path.read_bytes()).hexdigest(),
            "audio_s": float(
                (request.get("transcript") or {}).get("audio_duration")
                or segments[-1]["end"]
            ),
        }
    return {
        "path": str(path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "fixtures": fixtures,
    }


def split_run_name(name, fixtures):
    stem, _, repeat = name.rpartition("-")
    if stem in fixtures and repeat.isdigit():
        return stem, int(repeat)
    return None, None


def discover(directory, manifest):
    """Run records of one directory: a run.py tree or a replay.py tree."""
    directory = Path(directory)
    fixtures = manifest["fixtures"]
    records = []
    for child in sorted(directory.iterdir()):
        if child.is_dir() and (child / "summary.json").exists():
            name, repeat = split_run_name(child.name, fixtures)
            summary = read_json(child / "summary.json")
            fixture_doc = (
                read_json(child / "fixture.json")
                if (child / "fixture.json").exists()
                else {}
            )
            name = (fixture_doc.get("fixture") or {}).get("name") or name
            if name not in fixtures:
                continue
            records.append(
                {
                    "dir": child,
                    "source": str(child),
                    "fixture": name,
                    "repeat": repeat,
                    "summary": summary,
                    "fixture_doc": fixture_doc,
                    "replay": False,
                }
            )
        elif child.suffix == ".json" and child.is_file():
            name, repeat = split_run_name(child.stem, fixtures)
            if name is None:
                continue
            doc = read_json(child)
            if doc.get("kind") != "offline_revalidation_not_new_model_trial":
                continue
            source = resolve_source(child, doc.get("source", ""))
            original = read_json(source) if source and source.exists() else {}
            summary = {
                **original,
                "validation": doc["validation"],
                "metrics": doc["metrics"],
            }
            fixture_doc = (
                read_json(source.parent / "fixture.json")
                if source and (source.parent / "fixture.json").exists()
                else {}
            )
            records.append(
                {
                    "dir": source.parent if source else None,
                    "source": str(child),
                    "fixture": name,
                    "repeat": repeat,
                    "summary": summary,
                    "fixture_doc": fixture_doc,
                    "replay": True,
                    "replay_binary_sha256": doc.get("eval_binary_sha256"),
                    "source_found": bool(original),
                }
            )
    return records


def resolve_source(replay_file, source):
    """A replay's `source` is relative to the Worker directory of the checkout
    that wrote it (`../../<archive path>`): drop the leading `..` parts and
    find the first ancestor of the replay file that holds the rest."""
    if not source:
        return None
    parts = Path(source).parts
    while parts and parts[0] in ("..", "."):
        parts = parts[1:]
    if not parts:
        return None
    rest = Path(*parts)
    for parent in replay_file.resolve().parents:
        if (parent / rest).exists():
            return parent / rest
    return (replay_file.parent / source).resolve()


# --- per run ----------------------------------------------------------------


def classify(summary):
    error = summary.get("error")
    complete = bool((summary.get("validation") or {}).get("complete"))
    if complete and not error:
        return "complete"
    if error and any(marker in error for marker in ABORT_MARKERS):
        return "aborted"
    if error and error.startswith("ad_analysis_incomplete:"):
        detail = error.split(":", 1)[1]
        if "context_exceeded" in detail or detail.strip().startswith("pcc_"):
            return "transport"
        return "incomplete"
    if error and error.startswith(("Incomplete model output", "v3_")):
        return "incomplete"
    if error:
        return "transport"
    return "incomplete"


def archived_documents(run_dir, pattern):
    if run_dir is None:
        return []
    return sorted(Path(run_dir).glob(pattern))


def schema_leaks(model, run_dir):
    leaks = []
    for path in archived_documents(run_dir, "*-*/response.json"):
        if not path.parent.name.startswith(("window-", "repair-")):
            continue
        try:
            answer = harness.answer_of(model, read_json(path))
        except Exception:  # noqa: BLE001 - unparseable answers are 'malformed', not leaks
            continue
        if not isinstance(answer, dict):
            continue
        extra_top = sorted(set(answer) - V3_TOP_KEYS)
        if extra_top:
            leaks.append(f"{path.parent.name}: top-level {extra_top}")
        for span in answer.get("spans") or []:
            if isinstance(span, dict):
                extra = sorted(set(span) - V3_SPAN_KEYS)
                if extra:
                    leaks.append(f"{path.parent.name}: span {extra}")
    return leaks


def error_texts(summary, run_dir):
    texts = [summary.get("error") or ""]
    for path in archived_documents(run_dir, "*-*/error.json"):
        try:
            texts.append(str(read_json(path).get("error", "")))
        except (ValueError, OSError):
            continue
    return [t for t in texts if t]


def validations(run_dir):
    """(stage, document) for every archived initial/repair validation."""
    found = []
    for path in archived_documents(run_dir, "window-*/initial-validation.json"):
        found.append(("initial", read_json(path)))
    for path in archived_documents(run_dir, "repair-*/validation.json"):
        found.append(("repair", read_json(path)))
    return found


def pod_intervals(request, truth, key):
    by_id = {s["id"]: s for s in request["segments"]}
    return [
        (ids, (by_id[ids[0]]["start"], by_id[ids[1]]["end"]))
        for ids in truth.get(key, [])
    ]


def judge_run(record, manifest):
    fixture = manifest["fixtures"][record["fixture"]]
    request, truth = fixture["request"], fixture["entry"]["ground_truth"]
    summary = record["summary"]
    model = summary.get("model", "")
    validation = summary.get("validation") or {}
    status = classify(summary)
    installed = validation.get("spans", []) if status == "complete" else []
    metrics = harness.measure(request, installed, truth)
    archived = summary.get("metrics")
    metrics_match = archived is None or json.loads(json.dumps(archived)) == json.loads(
        json.dumps(metrics)
    )
    allowed = [iv for _, iv in pod_intervals(request, truth, "pods")] + [
        iv for _, iv in pod_intervals(request, truth, "optional")
    ]
    zones = metrics["zones"]
    junk = [
        z for z in zones if sum(overlap(z, region) for region in allowed) <= JUNK_OVERLAP_S
    ]
    pods = []
    for (ids, interval), scored in zip(pod_intervals(request, truth, "pods"), metrics["pods"]):
        touching = [z for z in zones if overlap(z, interval) > 0]
        pods.append(
            {
                "ids": ids,
                "coverage": round(scored["coverage"], 4),
                "zones": scored["zones"],
                "start_overshoot_s": round(max(0.0, interval[0] - min(z[0] for z in touching)), 3)
                if touching
                else None,
                "end_overshoot_s": round(max(0.0, max(z[1] for z in touching) - interval[1]), 3)
                if touching
                else None,
            }
        )
    calls = summary.get("calls") or []
    finishes = [c.get("finish_reason") for c in calls]
    non_stop = sorted({str(f) for f in finishes if f is not None and f not in NORMAL_FINISH})
    stage_validations = validations(record["dir"])
    issue_codes = {}
    for stage, doc in stage_validations:
        for warning in doc.get("warnings") or []:
            issue_codes.setdefault(f"{stage}:{code_of(warning)}", 0)
            issue_codes[f"{stage}:{code_of(warning)}"] += 1
    for warning in validation.get("warnings") or []:
        # A refused run's final warning is the runner's error string; count
        # the validator codes inside it, not the wrapper.
        inner = (
            warning.split(":", 1)[1].split(",")
            if str(warning).startswith("ad_analysis_incomplete:")
            else [warning]
        )
        for part in inner:
            if part.strip():
                key = f"final:{code_of(part)}"
                issue_codes[key] = issue_codes.get(key, 0) + 1
    for notice in validation.get("notices") or []:
        key = f"notice:{code_of(notice)}"
        issue_codes[key] = issue_codes.get(key, 0) + 1
    malformed = any(c.get("answer_error") for c in calls) or any(
        code.split(":", 1)[1] in MALFORMED_CODES for code in issue_codes
    )
    http400 = any(HTTP_400.search(text) for text in error_texts(summary, record["dir"]))
    leaks = schema_leaks(model, record["dir"])
    latencies = [
        (c["latency_ms"] / 1000) if c.get("latency_ms") is not None else c.get("elapsed_s")
        for c in calls
        if c.get("usage")
    ]
    usage_totals = {
        k: sum((c.get("usage") or {}).get(k, 0) or 0 for c in calls)
        for k in ("input", "cached", "output", "reasoning")
    }
    cost = summary.get("cost_usd")
    if cost is None:
        try:
            cost = sum(
                budget.cost_usd(model, c["usage"]) for c in calls if c.get("usage")
            )
        except (KeyError, ValueError):
            cost = None
    try:
        # Repeats of one episode minutes apart hit the vendors' implicit
        # prompt caches; production analyses an episode once, so the frontier
        # prices every cached token at the full input rate as well.
        cost_uncached = sum(
            budget.cost_usd(model, {**c["usage"], "cached": 0})
            for c in calls
            if c.get("usage")
        )
    except (KeyError, ValueError):
        cost_uncached = None
    request_sha = record["fixture_doc"].get("request_sha256")
    boundaries = sorted(
        (float(s["start_time"]), float(s["end_time"]))
        for s in installed
        if isinstance(s, dict) and "start_time" in s
    )
    return {
        "source": record["source"],
        "fixture": record["fixture"],
        "repeat": record["repeat"],
        "replay": record["replay"],
        "status": status,
        "error": summary.get("error"),
        "model": model,
        "thinking": summary.get("thinking"),
        "complete": status == "complete",
        "metrics": metrics,
        "metrics_match_archive": metrics_match,
        "pods": pods,
        "min_pod_coverage": min((p["coverage"] for p in pods), default=None),
        "whole_pod_misses": [p["ids"] for p in pods if p["coverage"] < WHOLE_POD_MISS]
        if status == "complete"
        else [],
        "false_skip_s": metrics["false_skip_s"],
        "negative_overlap_s": metrics["negative_overlap_s"],
        "junk_zones": junk,
        "zones_per_pod_max": max((p["zones"] for p in pods), default=0),
        "start_overshoot_s": max(
            (p["start_overshoot_s"] for p in pods if p["start_overshoot_s"] is not None),
            default=None,
        ),
        "end_overshoot_s": max(
            (p["end_overshoot_s"] for p in pods if p["end_overshoot_s"] is not None),
            default=None,
        ),
        "issue_codes": dict(sorted(issue_codes.items())),
        "repairs": len(archived_documents(record["dir"], "repair-*")),
        "windows_called": len(archived_documents(record["dir"], "window-*/response.json")),
        "requests": len(calls),
        "latencies_s": latencies,
        "generation_s": round(sum(v for v in latencies if v is not None), 3),
        "usage": usage_totals,
        "cost_usd": cost,
        "cost_uncached_usd": cost_uncached,
        "finish_reasons": finishes,
        "disqualifiers": {
            "non_stop_finish": non_stop,
            "malformed_output": bool(malformed),
            "negative_hit": metrics["negative_overlap_s"] > NEGATIVE_HIT_S,
            "junk_zone": bool(junk),
            "http_400": bool(http400),
            "schema_key_leak": leaks,
        },
        "boundaries": boundaries,
        "request_sha256": request_sha,
        "request_sha256_match": request_sha is None
        or request_sha == fixture["request_sha256"],
        "provider": summary.get("provider"),
        "vendor_model": summary.get("vendor_model"),
        "provider_thinking": summary.get("provider_thinking"),
        "schema_enforcement": summary.get("schema_enforcement"),
        "eval_binary_sha256": record["fixture_doc"].get("eval_binary_sha256")
        or record.get("replay_binary_sha256"),
        "replay_binary_sha256": record.get("replay_binary_sha256"),
        "audio_s": fixture["audio_s"],
    }


# --- per candidate ----------------------------------------------------------


def jitter(runs):
    """Max boundary drift versus the first complete run (the July rule)."""
    complete = [r for r in runs if r["complete"]]
    if len(complete) < 2:
        return {"runs": len(complete), "same_span_count": True, "max_jitter_s": None}
    reference = complete[0]["boundaries"]
    counts = [len(r["boundaries"]) for r in complete]
    same = len(set(counts)) == 1
    worst = 0.0
    if same:
        for other in complete[1:]:
            for (a0, a1), (b0, b1) in zip(reference, other["boundaries"]):
                worst = max(worst, abs(a0 - b0), abs(a1 - b1))
    return {
        "runs": len(complete),
        "same_span_count": same,
        "span_counts": counts,
        "max_jitter_s": round(worst, 3) if same else None,
    }


def mean(values):
    values = [v for v in values if v is not None]
    return statistics.fmean(values) if values else None


def gemini3(model):
    return "gemini-3." in (model or "")


def planned_windows(all_runs):
    """Windows the bridge plans per fixture: the window count of any complete
    run (windowing is provider-independent; the bridge renders it)."""
    planned = {}
    for r in all_runs:
        if r["complete"] and r["windows_called"]:
            planned[r["fixture"]] = max(planned.get(r["fixture"], 0), r["windows_called"])
    return planned


def projected_cost(run, planned):
    """No-cache cost of a run as if it had finished every planned window: a
    refused run's spend scaled by planned / called windows (an estimate; a
    run refused before its first billed window cannot be projected)."""
    cost = run["cost_uncached_usd"]
    if run["complete"] or cost is None:
        return cost
    total = planned.get(run["fixture"])
    if not total or not run["windows_called"] or not cost:
        return None
    return cost * max(1.0, total / run["windows_called"])


def aggregate(label, runs, reference=False, episodes_per_day=50, planned=None):
    scored = [r for r in runs if r["status"] != "aborted"]
    aborted = [r for r in runs if r["status"] == "aborted"]
    complete = [r for r in scored if r["complete"]]
    episodes = [r for r in scored if r["fixture"] in EPISODE_FIXTURES]
    models = sorted({r["model"] for r in runs})
    model = models[0] if models else ""
    by_fixture = {}
    for r in scored:
        by_fixture.setdefault(r["fixture"], []).append(r)
    cost_mean = mean([r["cost_usd"] for r in episodes])
    uncached_mean = mean([r["cost_uncached_usd"] for r in episodes])
    # A refused run stops at the failing window, so the all-run mean
    # understates what a candidate costs when it does finish an episode.
    complete_episodes = [r for r in episodes if r["complete"]]
    complete_uncached_mean = mean([r["cost_uncached_usd"] for r in complete_episodes])
    planned = planned or {}
    projected = [projected_cost(r, planned) for r in episodes]
    projected_mean = mean(projected)
    unpriced = sorted(
        {r["fixture"] for r, p in zip(episodes, projected) if p is None}
    )
    no_complete = sorted(
        {r["fixture"] for r in episodes} - {r["fixture"] for r in complete_episodes}
    )
    sn_costs = [r["cost_usd"] for r in scored if r["fixture"] == COST_MAX_FIXTURE]
    audio_h = sum(r["audio_s"] for r in episodes if r["cost_usd"] is not None) / 3600
    cost_sum = sum(r["cost_usd"] for r in episodes if r["cost_usd"] is not None)
    latencies = [v for r in scored for v in r["latencies_s"]]
    misses = [
        {"fixture": r["fixture"], "repeat": r["repeat"], "ids": ids}
        for r in complete
        for ids in r["whole_pod_misses"]
    ]
    dq = {
        "non_stop_finish": sum(bool(r["disqualifiers"]["non_stop_finish"]) for r in scored),
        "malformed_output": sum(r["disqualifiers"]["malformed_output"] for r in scored),
        "negative_hit": sum(r["disqualifiers"]["negative_hit"] for r in scored),
        "junk_zone": sum(r["disqualifiers"]["junk_zone"] for r in scored),
        "http_400": sum(r["disqualifiers"]["http_400"] for r in scored),
        "schema_key_leak": sum(bool(r["disqualifiers"]["schema_key_leak"]) for r in scored),
    }
    tiny = jitter(by_fixture.get(JITTER_FIXTURE, []))
    multiplier_2027 = 2.0 if gemini3(model) else 1.0
    row = {
        "label": label,
        "reference": reference,
        "model": model,
        "models": models,
        "thinking": sorted({str(r["thinking"]) for r in runs}),
        "provider_thinking": next(
            (r["provider_thinking"] for r in runs if r["provider_thinking"]), None
        ),
        "vendor_model": next((r["vendor_model"] for r in runs if r["vendor_model"]), None),
        "schema_enforcement": next(
            (r["schema_enforcement"] for r in runs if r["schema_enforcement"]), None
        ),
        "runs": len(scored),
        "aborted": [r["source"] for r in aborted],
        "status_counts": {
            s: sum(r["status"] == s for r in scored)
            for s in ("complete", "incomplete", "transport")
        },
        "complete_pct": round(100 * len(complete) / len(scored), 1) if scored else None,
        "min_pod_coverage": min(
            (r["min_pod_coverage"] for r in complete if r["min_pod_coverage"] is not None),
            default=None,
        ),
        "whole_pod_misses": len(misses),
        "whole_pod_miss_list": misses,
        "fp_s_max": max((r["false_skip_s"] for r in scored), default=None),
        "negative_overlap_s_max": max((r["negative_overlap_s"] for r in scored), default=None),
        "negative_fixture_overlap_s_max": max(
            (r["negative_overlap_s"] for r in scored if r["fixture"] == NEGATIVE_FIXTURE),
            default=None,
        ),
        "negative_hits": dq["negative_hit"],
        "junk_zones": sum(len(r["junk_zones"]) for r in scored),
        "zones_per_pod_max": max((r["zones_per_pod_max"] for r in complete), default=None),
        "start_overshoot_s_max": max(
            (r["start_overshoot_s"] for r in complete if r["start_overshoot_s"] is not None),
            default=None,
        ),
        "end_overshoot_s_max": max(
            (r["end_overshoot_s"] for r in complete if r["end_overshoot_s"] is not None),
            default=None,
        ),
        "p95_call_s": percentile(latencies, 0.95),
        "max_call_s": max(latencies, default=None),
        "p95_call_s_sn": percentile(
            [v for r in scored if r["fixture"] in ("sn1085", "sn1094") for v in r["latencies_s"]],
            0.95,
        ),
        "requests_per_episode": mean([r["requests"] for r in episodes]),
        "requests_per_episode_max": max((r["requests"] for r in episodes), default=None),
        "repairs": sum(r["repairs"] for r in scored),
        "cost_per_episode_mean": cost_mean,
        "cost_per_episode_uncached": uncached_mean,
        "cost_per_episode_complete_uncached": complete_uncached_mean,
        "cost_per_episode_projected_uncached": projected_mean,
        "projection_unpriced_fixtures": unpriced,
        "episode_fixtures_without_complete_run": no_complete,
        "episode_runs": len(episodes),
        "episode_runs_complete": len(complete_episodes),
        "cached_input_share": (
            sum(r["usage"]["cached"] for r in episodes) / sum(r["usage"]["input"] for r in episodes)
            if sum(r["usage"]["input"] for r in episodes)
            else None
        ),
        "cost_sn1094_max": max((c for c in sn_costs if c is not None), default=None),
        "cost_sn1094_uncached_max": max(
            (
                r["cost_uncached_usd"]
                for r in scored
                if r["fixture"] == COST_MAX_FIXTURE and r["cost_uncached_usd"] is not None
            ),
            default=None,
        ),
        "cost_per_audio_hour": cost_sum / audio_h if audio_h else None,
        "cost_total": sum(r["cost_usd"] for r in scored if r["cost_usd"] is not None),
        # $/day prices the uncached mean: one analysis per episode in production.
        "usd_per_day_today": uncached_mean * episodes_per_day
        if uncached_mean is not None
        else None,
        "usd_per_day_2027": uncached_mean * episodes_per_day * multiplier_2027
        if uncached_mean is not None
        else None,
        "price_multiplier_2027": multiplier_2027,
        "tokens_mean": {
            k: mean([r["usage"][k] for r in episodes]) for k in ("input", "output", "reasoning")
        },
        "bugged_tiny_jitter": tiny,
        "disqualifiers": dq,
        "metrics_mismatches": [r["source"] for r in runs if not r["metrics_match_archive"]],
        "request_sha_mismatches": [r["source"] for r in runs if not r["request_sha256_match"]],
        "eval_binaries": sorted({r["eval_binary_sha256"] for r in runs if r["eval_binary_sha256"]}),
        "incidents": incidents(by_fixture),
        "fixtures": {name: fixture_row(rs) for name, rs in sorted(by_fixture.items())},
    }
    clauses = got_wrong(row, by_fixture)
    row["what_it_got_wrong_clauses"] = clauses
    row["what_it_got_wrong"] = "; ".join(clauses)
    shown = clauses[:FRONTIER_CLAUSES]
    more = len(clauses) - len(shown)
    row["what_it_got_wrong_short"] = "; ".join(shown) + (
        f"; +{more} more in COMPARISON.md" if more else ""
    )
    return row


def pod_of(run, ids):
    return next((p for p in run["pods"] if p["ids"] == ids), None)


def incidents(by_fixture):
    out = {}
    sn = by_fixture.get("sn1094", [])
    if sn:
        out["sn1094"] = [
            {
                "repeat": r["repeat"],
                "status": r["status"],
                "doppel_989_1036": pod_of(r, DOPPEL_POD),
                "final_break_1198_1290": pod_of(r, FINAL_BREAK_POD),
                "negative_overlap_s": r["negative_overlap_s"],
            }
            for r in sn
        ]
    blunder = by_fixture.get("blunderbuss-exact", [])
    if blunder:
        out["blunderbuss-exact"] = [
            {
                "repeat": r["repeat"],
                "status": r["status"],
                "negative_overlap_s": r["negative_overlap_s"],
                "min_pod_coverage": r["min_pod_coverage"],
            }
            for r in blunder
        ]
    return out


def fixture_row(runs):
    complete = [r for r in runs if r["complete"]]
    return {
        "runs": len(runs),
        "complete": len(complete),
        "statuses": [r["status"] for r in runs],
        "min_pod_coverage": min(
            (r["min_pod_coverage"] for r in complete if r["min_pod_coverage"] is not None),
            default=None,
        ),
        "pod_coverages": [[p["coverage"] for p in r["pods"]] for r in runs],
        "whole_pod_misses": sorted(
            {tuple(ids) for r in complete for ids in r["whole_pod_misses"]}
        ),
        "whole_pod_miss_runs": sum(bool(r["whole_pod_misses"]) for r in complete),
        "fp_s_max": max(r["false_skip_s"] for r in runs),
        "negative_overlap_s_max": max(r["negative_overlap_s"] for r in runs),
        "junk_zones": sum(len(r["junk_zones"]) for r in runs),
        "zone_counts": [len(r["metrics"]["zones"]) for r in runs],
        "zones_per_pod_max": max((r["zones_per_pod_max"] for r in complete), default=None),
        "start_overshoot_s_max": max(
            (r["start_overshoot_s"] for r in complete if r["start_overshoot_s"] is not None),
            default=None,
        ),
        "end_overshoot_s_max": max(
            (r["end_overshoot_s"] for r in complete if r["end_overshoot_s"] is not None),
            default=None,
        ),
        "requests": [r["requests"] for r in runs],
        "repairs": [r["repairs"] for r in runs],
        "cost_mean": mean([r["cost_usd"] for r in runs]),
        "p95_call_s": percentile([v for r in runs for v in r["latencies_s"]], 0.95),
        "generation_s_max": max((r["generation_s"] for r in runs), default=None),
        "tokens_mean": {
            k: mean([r["usage"][k] for r in runs]) for k in ("input", "output", "reasoning")
        },
        "issue_codes": merge_codes(runs),
        "errors": sorted({str(r["error"])[:160] for r in runs if r["error"]}),
        "non_stop_finish": sorted(
            {f for r in runs for f in r["disqualifiers"]["non_stop_finish"]}
        ),
    }


def merge_codes(runs):
    codes = {}
    for r in runs:
        for code, count in r["issue_codes"].items():
            codes[code] = codes.get(code, 0) + count
    return dict(sorted(codes.items()))


def ids_text(ids):
    return f"{ids[0]}-{ids[1]}"


def got_wrong(row, by_fixture):
    """Plain-English clauses, one per class, the worst classes first and the
    worst fixture first inside each (the frontier shows the first
    FRONTIER_CLAUSES, COMPARISON.md all of them)."""
    clauses = []
    hits = []
    for name, runs in by_fixture.items():
        hit = [r for r in runs if r["disqualifiers"]["negative_hit"]]
        if hit:
            worst = max(r["negative_overlap_s"] for r in hit)
            hits.append((worst, f"{name} {worst:.1f} s ({len(hit)}/{len(runs)})"))
    if hits:
        clauses.append(
            "skipped labelled editorial: " + ", ".join(t for _, t in sorted(hits, reverse=True))
        )
    junk = [
        (sum(len(r["junk_zones"]) for r in runs), name) for name, runs in by_fixture.items()
    ]
    junk = [(count, name) for count, name in junk if count]
    if junk:
        clauses.append(
            "junk zones: " + ", ".join(f"{name} x{count}" for count, name in sorted(junk, reverse=True))
        )
    misses = {}
    for name, runs in sorted(by_fixture.items()):
        complete = [r for r in runs if r["complete"]]
        for r in complete:
            for ids in r["whole_pod_misses"]:
                misses.setdefault((name, tuple(ids)), [0, len(complete)])[0] += 1
    if misses:
        ordered = sorted(misses.items(), key=lambda item: (-item[1][0], item[0]))
        clauses.append(
            "missed whole pods: "
            + ", ".join(
                f"{name} {ids_text(ids)} ({count}/{total})" for (name, ids), (count, total) in ordered
            )
        )
    bad_total, scored, parts, codes = 0, 0, [], set()
    for name, runs in by_fixture.items():
        scored += len(runs)
        bad = [r for r in runs if r["status"] in ("incomplete", "transport")]
        if not bad:
            continue
        bad_total += len(bad)
        kinds = sorted({r["status"] for r in bad})
        parts.append((len(bad), f"{name} {len(bad)}/{len(runs)}" + ("" if kinds == ["incomplete"] else f" {','.join(kinds)}")))
        for r in bad:
            detail = (r["error"] or "").split(":", 1)[-1] if r["status"] == "incomplete" else ""
            codes.update(code_of(w) for w in detail.split(",") if w.strip())
            if r["status"] == "transport":
                codes.add("transport")
    if parts:
        clauses.append(
            f"no result on {bad_total}/{scored} runs: "
            + ", ".join(t for _, t in sorted(parts, key=lambda item: (-item[0], item[1])))
            + (f" ({', '.join(sorted(codes))})" if codes else "")
        )
    fps = [(max(r["false_skip_s"] for r in runs), name) for name, runs in by_fixture.items()]
    fps = [(fp, name) for fp, name in fps if fp > FP_NOTE_S]
    if fps:
        clauses.append(
            f"FP > {FP_NOTE_S:g} s: " + ", ".join(f"{name} {fp:.1f} s" for fp, name in sorted(fps, reverse=True))
        )
    partials = []
    for name, runs in by_fixture.items():
        partial = [
            p
            for r in runs
            if r["complete"]
            for p in r["pods"]
            if WHOLE_POD_MISS <= p["coverage"] < PARTIAL_POD
        ]
        if partial:
            worst = min(partial, key=lambda pod: pod["coverage"])
            partials.append((worst["coverage"], f"{name} {ids_text(worst['ids'])} {worst['coverage']:.2f}"))
    if partials:
        clauses.append(
            f"partial pods (< {PARTIAL_POD:g}): " + ", ".join(t for _, t in sorted(partials))
        )
    tiny = row["bugged_tiny_jitter"]
    if tiny["runs"] >= 2 and not tiny["same_span_count"]:
        clauses.append(f"bugged-tiny span count varies {tiny['span_counts']}")
    elif tiny["max_jitter_s"] is not None and tiny["max_jitter_s"] > JITTER_NOTE_S:
        clauses.append(f"bugged-tiny boundaries jitter {tiny['max_jitter_s']:.1f} s")
    if not clauses:
        return ["nothing measured: every pod >= 0.95, FP <= 10 s, no negative hit or junk"]
    return clauses


# --- rendering --------------------------------------------------------------


def fmt(value, digits=2, dash="-"):
    if value is None:
        return dash
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def usd(value, digits=4):
    return "-" if value is None else f"${value:.{digits}f}"


def jitter_text(tiny):
    if tiny["runs"] < 2:
        return "n/a (<2 complete)"
    if not tiny["same_span_count"]:
        return f"span count varies {tiny['span_counts']}"
    return f"{tiny['max_jitter_s']:.2f}"


def dq_text(dq):
    names = {
        "non_stop_finish": "non-STOP",
        "malformed_output": "malformed",
        "negative_hit": "neg>1s",
        "junk_zone": "junk",
        "http_400": "HTTP400",
        "schema_key_leak": "key leak",
    }
    hit = [f"{names[k]} x{v}" for k, v in dq.items() if v]
    return ", ".join(hit) if hit else "none"


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    lines += ["| " + " | ".join(str(c).replace("|", "/") for c in row) + " |" for row in rows]
    return "\n".join(lines)


def row_name(row):
    return row["label"] + (" (reference)" if row["reference"] else "")


def render_comparison(rows, manifest, generated_at, inputs):
    out = [
        "# Generative ad-analysis bakeoff: comparison (generated)",
        "",
        f"Generated {generated_at} by `eval/compare_frontier_generative.py`; "
        f"manifest `{manifest['path']}` sha256 `{manifest['sha256']}`. "
        "Every run is re-scored with `run.measure` against the frozen manifest. "
        "Disqualification classes are columns, never a gate. "
        "`$/episode` = mean over the real-recording fixtures "
        f"({', '.join(EPISODE_FIXTURES)}). Coverage, misses and jitter read complete runs only.",
        "",
        "## Summary",
        "",
        table(
            [
                "candidate",
                "model",
                "thinking",
                "runs",
                "complete %",
                "min pod cov",
                "whole-pod misses",
                "FP s max",
                "neg hits >1 s",
                "junk zones",
                "zones/pod max",
                "start/end overshoot s max",
                "$/episode measured / no-cache",
                "$/audio h",
                "req/ep",
                "p95 call s",
                "bugged-tiny jitter s",
            ],
            [
                [
                    row_name(r),
                    r["model"],
                    ",".join(r["thinking"]),
                    r["runs"],
                    fmt(r["complete_pct"], 1),
                    fmt(r["min_pod_coverage"], 3),
                    r["whole_pod_misses"],
                    fmt(r["fp_s_max"], 1),
                    r["negative_hits"],
                    r["junk_zones"],
                    fmt(r["zones_per_pod_max"]),
                    f"{fmt(r['start_overshoot_s_max'], 1)} / {fmt(r['end_overshoot_s_max'], 1)}",
                    f"{usd(r['cost_per_episode_mean'])} / {usd(r['cost_per_episode_uncached'])}",
                    usd(r["cost_per_audio_hour"]),
                    fmt(r["requests_per_episode"], 1),
                    fmt(r["p95_call_s"], 1),
                    jitter_text(r["bugged_tiny_jitter"]),
                ]
                for r in rows
            ],
        ),
        "",
        "## Hard-disqualification classes (runs hit; reported, never gated)",
        "",
        table(
            [
                "candidate",
                "runs",
                "non-STOP finish",
                "malformed output",
                "negative hit > 1 s",
                "junk zone",
                "HTTP 400",
                "schema key leak",
            ],
            [
                [
                    row_name(r),
                    r["runs"],
                    *[
                        r["disqualifiers"][k]
                        for k in (
                            "non_stop_finish",
                            "malformed_output",
                            "negative_hit",
                            "junk_zone",
                            "http_400",
                            "schema_key_leak",
                        )
                    ],
                ]
                for r in rows
            ],
        ),
        "",
    ]
    for r in rows:
        out += render_candidate(r, inputs.get(r["label"], []))
    return "\n".join(out) + "\n"


def render_candidate(r, sources):
    lines = [
        f"## {row_name(r)}",
        "",
        f"- model `{r['model']}` (vendor `{r['vendor_model']}`), thinking "
        f"`{','.join(r['thinking'])}`, provider thinking `{json.dumps(r['provider_thinking'])}`, "
        f"schema `{r['schema_enforcement']}`",
        f"- inputs: {', '.join(f'`{s}`' for s in sources)}",
        f"- runs {r['runs']} ({', '.join(f'{k} {v}' for k, v in r['status_counts'].items())}); "
        f"aborted (excluded) {len(r['aborted'])}"
        + (f": {', '.join(r['aborted'])}" if r["aborted"] else ""),
        f"- cost: total {usd(r['cost_total'])}, per episode measured {usd(r['cost_per_episode_mean'])} "
        f"/ no-cache {usd(r['cost_per_episode_uncached'])} / complete runs only "
        f"{complete_cost_cell(r)} (cached share of input "
        f"{fmt(None if r['cached_input_share'] is None else 100 * r['cached_input_share'], 1)} %; "
        f"sn1094 max measured {usd(r['cost_sn1094_max'])} / no-cache {usd(r['cost_sn1094_uncached_max'])}), "
        f"per audio hour {usd(r['cost_per_audio_hour'])}; "
        f"$/day at 50 episodes (no-cache) {usd(r['usd_per_day_today'], 2)}, from 2027-01-01 "
        f"{usd(r['usd_per_day_2027'], 2)} (x{r['price_multiplier_2027']:g})",
        f"- tokens per episode (mean): input {fmt(r['tokens_mean']['input'], 0)}, output "
        f"{fmt(r['tokens_mean']['output'], 0)}, reasoning {fmt(r['tokens_mean']['reasoning'], 0)}; "
        f"requests per episode {fmt(r['requests_per_episode'], 1)} (max {fmt(r['requests_per_episode_max'])}), "
        f"repair turns {r['repairs']}",
        f"- latency (provider call only): p95 {fmt(r['p95_call_s'], 1)} s, max {fmt(r['max_call_s'], 1)} s, "
        f"sn1085+sn1094 p95 {fmt(r['p95_call_s_sn'], 1)} s",
        f"- disqualifiers: {dq_text(r['disqualifiers'])}",
        f"- what it got wrong: {r['what_it_got_wrong']}",
        f"- eval binaries: {', '.join(b[:12] for b in r['eval_binaries']) or '-'}; "
        f"archived-metrics mismatches {len(r['metrics_mismatches'])}; request sha mismatches "
        f"{len(r['request_sha_mismatches'])}",
        "",
        table(
            [
                "fixture",
                "runs",
                "complete",
                "pod coverage per run",
                "whole-pod misses",
                "FP s max",
                "neg overlap s max",
                "junk",
                "zones",
                "zones/pod max",
                "overshoot s start/end",
                "req",
                "repairs",
                "$ mean",
                "p95 s",
                "tokens in/out/think",
                "issue codes",
            ],
            [
                [
                    name,
                    f["runs"],
                    f["complete"],
                    " ; ".join(",".join(f"{c:.2f}" for c in run) or "-" for run in f["pod_coverages"]),
                    ", ".join(ids_text(ids) for ids in f["whole_pod_misses"]) or "-",
                    fmt(f["fp_s_max"], 1),
                    fmt(f["negative_overlap_s_max"], 1),
                    f["junk_zones"],
                    ",".join(str(z) for z in f["zone_counts"]),
                    fmt(f["zones_per_pod_max"]),
                    f"{fmt(f['start_overshoot_s_max'], 1)} / {fmt(f['end_overshoot_s_max'], 1)}",
                    ",".join(str(x) for x in f["requests"]),
                    ",".join(str(x) for x in f["repairs"]),
                    usd(f["cost_mean"]),
                    fmt(f["p95_call_s"], 1),
                    "/".join(fmt(f["tokens_mean"][k], 0) for k in ("input", "output", "reasoning")),
                    ", ".join(f"{k} x{v}" for k, v in f["issue_codes"].items()) or "-",
                ]
                for name, f in r["fixtures"].items()
            ],
        ),
        "",
    ]
    errors = {name: f["errors"] for name, f in r["fixtures"].items() if f["errors"]}
    if errors:
        lines += ["Errors (first 160 chars):", ""]
        lines += [f"- {name}: {' | '.join(e)}" for name, e in errors.items()]
        lines.append("")
    sn = r["incidents"].get("sn1094")
    if sn:
        lines += [
            "Incidents, sn1094 (Doppel pod 989-1036, final break 1198-1290):",
            "",
            table(
                ["repeat", "status", "Doppel cov/zones", "final break cov/zones", "neg overlap s"],
                [
                    [
                        i["repeat"],
                        i["status"],
                        pod_cell(i["doppel_989_1036"]),
                        pod_cell(i["final_break_1198_1290"]),
                        fmt(i["negative_overlap_s"], 1),
                    ]
                    for i in sn
                ],
            ),
            "",
        ]
    return lines


def pod_cell(pod):
    if not pod:
        return "-"
    return f"{pod['coverage']:.2f} / {pod['zones']}"


def complete_cost_cell(r):
    """Complete-run cost beside the mean, plus the full-pass projection when
    refused runs (which stop at their failing window) pull the mean down."""
    cell = (
        f"{usd(r['cost_per_episode_complete_uncached'])} "
        f"({r['episode_runs_complete']}/{r['episode_runs']})"
    )
    refused = r["episode_runs"] - r["episode_runs_complete"]
    if refused:
        cell += f"; {refused} refused run(s) stop early"
        projected, mean_cost = r["cost_per_episode_projected_uncached"], r["cost_per_episode_uncached"]
        if projected is not None and mean_cost:
            cell += (
                f", full-pass projection {usd(projected)} ({100 * (projected / mean_cost - 1):+.0f} % "
                "over the mean)"
            )
        if r["episode_fixtures_without_complete_run"]:
            cell += "; no complete run on " + ", ".join(r["episode_fixtures_without_complete_run"])
        if r["projection_unpriced_fixtures"]:
            cell += "; unprojectable " + ", ".join(r["projection_unpriced_fixtures"])
    return cell


def render_frontier(rows, generated_at, episodes_per_day):
    header = [
        "candidate",
        "$/episode mean (measured / no-cache)",
        "$/episode complete runs only (no-cache, runs)",
        "$/episode sn1094 max (measured / no-cache)",
        f"$/day today ({episodes_per_day}, no-cache)",
        "$/day from 2027-01-01 (no-cache)",
        "requests/episode",
        "p95 s",
        "complete %",
        "min pod coverage",
        "whole-pod misses",
        "FP s max",
        "negative hits",
        "junk zones",
        "repeatability (bugged-tiny jitter s)",
        "disqualifiers",
        "what it got wrong",
    ]
    body = [
        [
            row_name(r) + f" `{r['model']}` {','.join(r['thinking'])}",
            f"{usd(r['cost_per_episode_mean'])} / {usd(r['cost_per_episode_uncached'])}",
            complete_cost_cell(r),
            f"{usd(r['cost_sn1094_max'])} / {usd(r['cost_sn1094_uncached_max'])}",
            usd(r["usd_per_day_today"], 2),
            usd(r["usd_per_day_2027"], 2),
            fmt(r["requests_per_episode"], 1),
            fmt(r["p95_call_s"], 1),
            fmt(r["complete_pct"], 1),
            fmt(r["min_pod_coverage"], 3),
            r["whole_pod_misses"],
            fmt(r["fp_s_max"], 1),
            r["negative_hits"],
            r["junk_zones"],
            jitter_text(r["bugged_tiny_jitter"]),
            dq_text(r["disqualifiers"]),
            r["what_it_got_wrong_short"],
        ]
        for r in rows
    ]
    return (
        "\n".join(
            [
                "# Frontier rows: generative candidates (generated)",
                "",
                f"Generated {generated_at} by `eval/compare_frontier_generative.py` from the "
                "same runs as COMPARISON.md. Incumbent first. `$/episode` = mean over the "
                "real-recording fixtures, measured (`cost_usd`, including the implicit prompt-cache "
                "hits that repeats minutes apart get) and no-cache (every cached token at the full "
                "input rate: production analyses an episode once). Beside it: the no-cache mean of "
                "complete runs only (skewed toward the fixtures a candidate finishes, often the short "
                "ones) and a full-pass projection (a refused run stops at its failing window, so its "
                "spend is scaled by planned / called windows; windows planned = a complete run's "
                "count on that fixture). `$/day` = all-run no-cache mean x"
                f"{episodes_per_day} episodes; from 2027-01-01 Gemini 3.x prices double, others "
                "unchanged. p95 = provider-call wall time, nearest rank over every call. "
                "Coverage, whole-pod misses (< 0.5) and jitter count complete runs only; "
                "negative hits = runs with > 1 s on labelled negatives.",
                "",
                table(header, body),
            ]
        )
        + "\n"
    )


def parse_spec(spec):
    label, sep, dirs = spec.partition("=")
    if not sep or not label or not dirs:
        raise argparse.ArgumentTypeError("expected LABEL=DIR[,DIR...]")
    return label, [Path(d) for d in dirs.split(",") if d]


def build(candidates, references, manifest_path, episodes_per_day=50):
    manifest = load_manifest(manifest_path)
    rows, runs_by_label, inputs, kinds = [], {}, {}, {}
    for specs, is_reference in ((candidates, False), (references, True)):
        for label, dirs in specs:
            records = [rec for d in dirs for rec in discover(d, manifest)]
            runs_by_label[label] = [judge_run(rec, manifest) for rec in records]
            inputs[label] = [str(d) for d in dirs]
            kinds[label] = is_reference
    planned = planned_windows([r for runs in runs_by_label.values() for r in runs])
    for label, judged in runs_by_label.items():
        rows.append(
            aggregate(
                label,
                judged,
                reference=kinds[label],
                episodes_per_day=episodes_per_day,
                planned=planned,
            )
        )
    # Incumbent (first candidate) first, references next, then the rest.
    ordered = rows[:1] + [r for r in rows if r["reference"]] + [
        r for r in rows[1:] if not r["reference"]
    ]
    return manifest, ordered, runs_by_label, inputs


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--candidate",
        type=parse_spec,
        action="append",
        default=[],
        help="LABEL=DIR[,DIR...]; the first is the incumbent",
    )
    parser.add_argument(
        "--reference",
        type=parse_spec,
        action="append",
        default=[],
        help="LABEL=DIR[,DIR...] read-only reference (e.g. a replay.py tree)",
    )
    parser.add_argument("--out-md", type=Path, required=True)
    parser.add_argument("--out-json", type=Path, required=True)
    parser.add_argument("--frontier-md", type=Path)
    parser.add_argument("--episodes-per-day", type=int, default=50)
    args = parser.parse_args(argv)
    if not args.candidate:
        parser.error("at least one --candidate")
    manifest, rows, runs_by_label, inputs = build(
        args.candidate, args.reference, args.manifest, args.episodes_per_day
    )
    generated_at = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    args.out_md.parent.mkdir(parents=True, exist_ok=True)
    args.out_md.write_text(render_comparison(rows, manifest, generated_at, inputs))
    sidecar = {
        "generated_at": generated_at,
        "manifest": {"path": manifest["path"], "sha256": manifest["sha256"]},
        "episode_fixtures": list(EPISODE_FIXTURES),
        "episodes_per_day": args.episodes_per_day,
        "inputs": inputs,
        "candidates": rows,
        "runs": {
            label: [{k: v for k, v in r.items() if k != "boundaries"} for r in runs]
            for label, runs in runs_by_label.items()
        },
    }
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    args.out_json.write_text(json.dumps(sidecar, indent=2, default=list) + "\n")
    if args.frontier_md:
        args.frontier_md.write_text(render_frontier(rows, generated_at, args.episodes_per_day))
    for r in rows:
        print(
            json.dumps(
                {
                    "label": r["label"],
                    "runs": r["runs"],
                    "complete_pct": r["complete_pct"],
                    "min_pod_coverage": r["min_pod_coverage"],
                    "whole_pod_misses": r["whole_pod_misses"],
                    "fp_s_max": r["fp_s_max"],
                    "negative_hits": r["negative_hits"],
                    "junk_zones": r["junk_zones"],
                    "cost_per_episode_mean": r["cost_per_episode_mean"],
                    "aborted": len(r["aborted"]),
                    "metrics_mismatches": len(r["metrics_mismatches"]),
                }
            )
        )


if __name__ == "__main__":
    main()

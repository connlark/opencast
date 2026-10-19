#!/usr/bin/env python3
"""Frontier table: one row per configuration (a tag dir of runs). No inference.

Columns: $/episode (actual mean and 60-minute normalised), the same cost if
every question were its own request (pplx-decider-flash's documented default;
estimated from each call's input tokens minus ~95 tokens per extra question),
requests/episode, call p95, per-episode serial elapsed (wall time of the
run, every page in order) and the per-episode sum of call latencies (vendor
time only), min pod coverage, raw
and calibrated FP seconds, negative hits (> 1 s), whole-pod misses
(coverage < 0.5), junk zones, editorial runs (> 60 s), pods below the 0.8
floor, repeatability (jitter.json in the tag dir: max |delta p| on pod chunks,
boundary drift), fallback rate (incomplete runs) and complete %, $/day at 50
episodes (the actual $/episode mean x 50) and the same from 2027-01-01, when
Gemini 3.x list prices double (every `gemini-3.` call's cost counted twice);
for hybrids the localiser and generative $/episode, neighbourhoods per
episode, the neighbourhoods' share of the audio and the final whole-request
validate pass rate; and a `disqualifiers`
column copied from compare_pcc_eval's `comparison.json` when given (else the
local equivalents from `oracle.evaluate`). Reported, never gated.
"""

from __future__ import annotations

import argparse
import statistics
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "decision"  # noqa: A001

from .common import load_manifest, percentile, read, write  # noqa: E402
from .oracle import evaluate  # noqa: E402

# Billed tokens per added question with this question set (criteria included):
# 2026-10-18 pplx-flash bugged-tiny, 1-question requests 19,986 vs 32-question
# pages 22,917-22,969 (31 extra questions). Step 0's 39 had no criteria.
TOKENS_PER_EXTRA_QUESTION = 95
EPISODES_PER_DAY = 50
GEMINI_3_PREFIXES = ("gemini-3.", "cf/google/gemini-3.")


def per_question_cost(calls):
    total = 0.0
    for call in calls:
        tokens, q = call["usage"]["input"], max(1, call.get("questions", 1))
        if not tokens:
            continue
        price = (call.get("cost_usd") or 0.0) / tokens
        state = max(0, tokens - TOKENS_PER_EXTRA_QUESTION * (q - 1))
        total += q * state * price
    return total


def row(label, directory, manifest, comparison=None):
    runs = []
    for path in sorted(directory.glob("*/summary.json")):
        summary = read(path)
        name = path.parent.name.rpartition("-")[0]
        if name not in manifest:
            continue
        fixture, request, _ = manifest[name]
        judged = evaluate(name, request, fixture["ground_truth"], summary["validation"], summary["metrics"])
        runs.append((path.parent.name, name, summary, judged))
    if not runs:
        return None
    hours = [max(1e-9, (s.get("audio_duration_s") or 3600) / 3600) for _, _, s, _ in runs]
    costs = [s.get("cost_usd") or 0.0 for _, _, s, _ in runs]
    alt = [per_question_cost(s["calls"]) for _, _, s, _ in runs]
    elapsed = [c.get("elapsed_s") for _, _, s, _ in runs for c in s["calls"] if c.get("elapsed_s") is not None]
    coverages = [p["coverage"] for _, _, s, _ in runs for p in s["metrics"]["pods"]]
    jitter_path = directory / "jitter.json"
    jitter = read(jitter_path) if jitter_path.exists() else {}
    dq = []
    if comparison and label in comparison.get("configurations", {}):
        for r in comparison["configurations"][label]["runs"]:
            dq += [f"{r['run']}: {d}" for d in r["disqualifiers"]]
        calibrated = [r["calibrated_false_skip_s"] for r in comparison["configurations"][label]["runs"] if r["complete"]]
    else:
        dq = [f"{run}: {d}" for run, _, _, j in runs for d in j["disqualifiers"]]
        calibrated = None
    first = runs[0][2]
    summaries = [s for _, _, s, _ in runs]

    def stage_cost(s, stage):
        return sum(c.get("cost_usd") or 0.0 for c in s["calls"] if c.get("stage") == stage)

    gemini3 = [sum(c.get("cost_usd") or 0.0 for c in s["calls"] if str(c.get("model", "")).startswith(GEMINI_3_PREFIXES)) for s in summaries]
    hybrid = [s["hybrid"] for s in summaries if s.get("hybrid")]
    fallback = sum(not s["validation"]["complete"] or bool(s["error"]) for s in summaries) / len(summaries)
    return {
        "configuration": label,
        "model": first["model"],
        "design": first["design"],
        "chunking": first["chunking"].get("id"),
        "derive_params_sha256": first["derive_params"]["sha256"],
        "runs": len(runs),
        "usd_per_episode": round(statistics.mean(costs), 6),
        "usd_per_60min": round(statistics.mean(c / h for c, h in zip(costs, hours)), 6),
        "usd_per_60min_one_question_per_request": round(statistics.mean(a / h for a, h in zip(alt, hours)), 6),
        "usd_per_day_50": round(statistics.mean(costs) * EPISODES_PER_DAY, 4),
        "usd_per_day_50_2027": round(statistics.mean(c + g for c, g in zip(costs, gemini3)) * EPISODES_PER_DAY, 4),
        "localiser": first.get("localiser"),
        "localiser_usd_per_episode": round(statistics.mean(stage_cost(s, "decision") for s in summaries), 6) if hybrid else None,
        "generative_usd_per_episode": round(statistics.mean(stage_cost(s, "generative") for s in summaries), 6) if hybrid else None,
        "neighbourhoods_per_episode": round(statistics.mean(h.get("neighbourhood_count", len(h["neighbourhoods"])) for h in hybrid), 2) if hybrid else None,
        "neighbourhood_share": round(statistics.mean(h["neighbourhood_seconds"] / h["audio_seconds"] for h in hybrid if h.get("audio_seconds")), 3) if hybrid and all(h.get("audio_seconds") for h in hybrid) else None,
        "final_validate_pass": f"{sum(bool(h.get('final_validate_complete')) for h in hybrid)}/{len(summaries)}" if hybrid else None,
        "requests_per_episode": round(statistics.mean(s["requests_total"] for _, _, s, _ in runs), 2),
        "call_p95_s": percentile(elapsed, 0.95),
        "serial_elapsed_s_mean": round(statistics.mean(s["elapsed_s"] for _, _, s, _ in runs), 3),
        "serial_elapsed_s_max": max(s["elapsed_s"] for _, _, s, _ in runs),
        "call_s_sum_per_episode": round(
            statistics.mean(sum(c.get("elapsed_s") or 0.0 for c in s["calls"]) for _, _, s, _ in runs), 3
        ),
        "min_pod_coverage": round(min(coverages), 4) if coverages else None,
        "raw_fp_s_max": max(s["metrics"]["false_skip_s"] for _, _, s, _ in runs),
        "calibrated_fp_s_max": max(calibrated) if calibrated else None,
        "negative_hits": sum(len(j["negative_hits"]) for _, _, _, j in runs),
        "whole_pod_misses": sum(p["coverage"] < 0.5 for p in (p for _, _, s, _ in runs for p in s["metrics"]["pods"])),
        "junk_zones": sum(d.startswith("junk zone") for _, _, _, j in runs for d in j["disqualifiers"]),
        "editorial_runs": sum(d.startswith("editorial run") for _, _, _, j in runs for d in j["disqualifiers"]),
        "pods_below_floor": sum(j["pods_below_floor"] for _, _, _, j in runs),
        "max_pod_jitter": max((v["max_abs_delta_p_pod"] for v in jitter.values()), default=None),
        "boundary_drift_s": max((v["boundary_drift_s"] for v in jitter.values()), default=None),
        "fallback_rate": round(fallback, 3),
        "complete_pct": round(100 * (1 - fallback), 1),
        "gates_passed": f"{sum(j['passed'] for _, _, _, j in runs)}/{len(runs)}",
        "disqualifiers": dq,
    }


COLUMNS = [
    ("configuration", "config"), ("design", "design"), ("chunking", "chunks"), ("usd_per_60min", "$/60min"),
    ("usd_per_episode", "$/ep"), ("usd_per_day_50", "$/day@50"), ("usd_per_day_50_2027", "$/day@50 2027"),
    ("usd_per_60min_one_question_per_request", "$/60min 1q/req"),
    ("requests_per_episode", "req/ep"), ("call_p95_s", "call p95 s"), ("serial_elapsed_s_max", "serial s max"), ("call_s_sum_per_episode", "call s/ep"),
    ("min_pod_coverage", "min pod cov"), ("raw_fp_s_max", "raw FP s"), ("calibrated_fp_s_max", "cal FP s"),
    ("negative_hits", "neg hits"), ("whole_pod_misses", "whole misses"), ("junk_zones", "junk"),
    ("editorial_runs", "editorial"), ("pods_below_floor", "<0.8 pods"), ("max_pod_jitter", "pod jitter"),
    ("boundary_drift_s", "drift s"), ("complete_pct", "complete %"), ("gates_passed", "gates"),
    ("localiser_usd_per_episode", "loc $/ep"), ("generative_usd_per_episode", "gen $/ep"),
    ("neighbourhoods_per_episode", "hoods/ep"), ("neighbourhood_share", "hood share"), ("final_validate_pass", "final validate"),
]


def render(rows):
    lines = ["# Decision-pipeline frontier (generated by eval/decision/frontier.py)", ""]
    lines.append("| " + " | ".join(h for _, h in COLUMNS) + " | disqualifiers |")
    lines.append("| " + " | ".join("---" for _ in COLUMNS) + " | --- |")
    for r in rows:
        cells = ["-" if r[k] is None else str(r[k]) for k, _ in COLUMNS]
        dq = "; ".join(r["disqualifiers"][:4]) + (f" (+{len(r['disqualifiers']) - 4})" if len(r["disqualifiers"]) > 4 else "")
        lines.append("| " + " | ".join(cells) + f" | {dq or 'none'} |")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runs", action="append", required=True, help="LABEL=DIR (a tag directory)")
    parser.add_argument("--comparison", type=Path, help="compare_pcc_eval comparison.json")
    parser.add_argument("--out", type=Path, required=True, help="markdown path; JSON sidecar beside it")
    args = parser.parse_args(argv)
    manifest = load_manifest(args.manifest)
    comparison = read(args.comparison) if args.comparison else None
    rows = []
    for item in args.runs:
        label, _, directory = item.partition("=")
        r = row(label, Path(directory), manifest, comparison)
        if r:
            rows.append(r)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render(rows))
    write(args.out.with_suffix(".json"), rows)
    print(render(rows))


if __name__ == "__main__":
    main()

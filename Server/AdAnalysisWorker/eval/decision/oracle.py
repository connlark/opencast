#!/usr/bin/env python3
"""E0: the ground-truth oracle through chunking + derivation + `run.measure()`.

Ground-truth probabilities (1.0 in pods, 0.5 in optional, 0.0 elsewhere) are
fed through exactly the pipeline a paid run uses (`run_decision.analyse`,
`OracleAsker` in place of the vendor). Chunk answers are duration-weighted
means of the segment truth (the calibrated reading of "is chunk Ck part of an
advertising break"); the confirmation answer is one minus the passage's share
of program seconds. The result is the ceiling a granularity can reach: a
granularity whose oracle fails a fixture's gates cannot pass with any model.

Gates per fixture (raw frozen labels; calibrated overlays only add sanctioned
regions, so passing raw implies passing calibrated):

* strict (bugged-tiny, bugged-txt, audio-illusion): every pod coverage >= 0.999
  in one zone, unsanctioned start/end overshoot (slack) <= 6 s, FP <= 10 s.
  (the earlier golden-fixture gates had no slack gate on audio-illusion; this
  suite applies 6 s.)
* regression (sn1085, sn1094, long-window): pods >= 0.95 in one zone,
  FP <= 90 s, zero overlap with the named editorial negative.
* negatives-only (fortinet): no zone at all touches the negative.
* judge (the rest): compare_pcc_eval's per-run pass with an empty incumbent
  envelope: pods >= 0.95 in one zone, FP <= 10 s, pod confidence >= 0.8.
* Every profile: compare_pcc_eval's disqualifiers (whole-pod miss < 0.5, junk
  zone, editorial run > 60 s outside sanctioned regions, negative overlap
  > 0.05 s) and the golden-fixture negative hits (> 1 s per negative).

Archive: `<out>/<config>/<fixture>-1/` with run_decision's summary.json shape
(`model: oracle:ground-truth`, `cost_usd: 0`), plus `<out>/E0.md` and
`<out>/e0.json`.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "decision"  # noqa: A001

from . import chunking  # noqa: E402
from .common import WAVE1, WAVE2, load_manifest, sha256_file, write  # noqa: E402
from .derive import DeriveParams  # noqa: E402
from .run_decision import OracleAsker, run_fixture  # noqa: E402

ORACLE_MODEL = "oracle:ground-truth"
WHOLE_MISS = 0.5
EDITORIAL_RUN_S = 60.0
NEGATIVE_TOLERANCE_S = 0.05
NEGATIVE_HIT_S = 1.0

GATES = {
    "bugged-tiny": {"mode": "strict", "fp_max": 10.0, "slack": 6.0},
    "bugged-txt": {"mode": "strict", "fp_max": 10.0, "slack": 6.0},
    "audio-illusion": {"mode": "strict", "fp_max": 10.0, "slack": 6.0},
    "sn1085": {"mode": "regression", "fp_max": 90.0, "coverage_min": 0.95, "zero_overlap_negative": [1118, 1313]},
    "sn1094": {"mode": "regression", "fp_max": 90.0, "coverage_min": 0.95, "zero_overlap_negative": [1044, 1195]},
    "sn1085-long-window-derived": {"mode": "regression", "fp_max": 90.0, "coverage_min": 0.95, "zero_overlap_negative": [1878, 2160]},
    "sn1085-fortinet-negative": {"mode": "negatives-only"},
}
JUDGE = {"mode": "judge", "fp_max": 10.0, "coverage_min": 0.95}

CONFIGS = {
    "seg10-chunk": ("b_prime", "seg10"),
    "seg10-refine": ("d", "seg10"),
    "sec30-chunk": ("b_prime", "sec30"),
    "sec30-refine": ("d", "sec30"),
    "sec30-chunk-c": ("c", "sec30"),
    "sec30-refine-c": ("d_c", "sec30"),
}


def _overlap(a, b):
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def evaluate(name, request, truth, validation, metrics):
    """Gate checks + disqualifiers for one run (pure)."""
    gates = GATES.get(name, JUDGE)
    by_id = {s["id"]: s for s in request["segments"]}
    interval = lambda ids: (by_id[ids[0]]["start"], by_id[ids[1]]["end"])  # noqa: E731
    pods = [interval(p) for p in truth.get("pods", [])]
    sanctioned = pods + [interval(o) for o in truth.get("optional", [])]
    negatives = [(n, interval(n)) for n in truth.get("negatives", [])]
    zones = [tuple(z) for z in metrics["zones"]]
    checks, dqs = [], []

    def check(label, ok, detail):
        checks.append({"name": label, "passed": bool(ok), "detail": detail})

    def unsanctioned(a, b):
        return max(0.0, (b - a) - sum(_overlap((a, b), r) for r in sanctioned)) if b > a else 0.0

    slacks = []
    for ids, pod, report in zip(truth.get("pods", []), pods, metrics["pods"]):
        tag = f"pod {ids[0]}-{ids[1]}"
        touching = [z for z in zones if _overlap(z, pod) > 0]
        if report["coverage"] < WHOLE_MISS:
            dqs.append(f"whole-pod miss {ids[0]}-{ids[1]} (coverage {report['coverage']:.3f})")
        if gates["mode"] == "negatives-only":
            continue
        floor = 0.999 if gates["mode"] == "strict" else gates["coverage_min"]
        check(f"{tag} coverage >= {floor}", report["coverage"] >= floor, f"{report['coverage']:.4f}")
        check(f"{tag} single zone", len(touching) == 1, f"zones={len(touching)}")
        if touching:
            start = unsanctioned(min(z[0] for z in touching), pod[0])
            end = unsanctioned(pod[1], max(z[1] for z in touching))
            slacks.append(max(start, end))
            if gates.get("slack") is not None:
                check(f"{tag} slack <= {gates['slack']}s", max(start, end) <= gates["slack"], f"start={start:.2f} end={end:.2f}")
    if gates["mode"] != "negatives-only":
        check(f"FP <= {gates['fp_max']}s", metrics["false_skip_s"] <= gates["fp_max"] + 1e-6, f"{metrics['false_skip_s']}")
    hits = []
    for ids, negative in negatives:
        seconds = sum(_overlap(z, negative) for z in zones)
        if seconds > NEGATIVE_HIT_S:
            hits.append({"ids": ids, "overlap_s": round(seconds, 2)})
        if gates.get("zero_overlap_negative") == list(ids):
            check(f"zero overlap {ids[0]}-{ids[1]}", seconds == 0.0, f"{seconds:.2f}s")
    check("no negative hits", not hits, json.dumps(hits))
    if metrics["negative_overlap_s"] > NEGATIVE_TOLERANCE_S:
        dqs.append(f"negative overlap {metrics['negative_overlap_s']:.2f}s")
    junk = [z for z in zones if not any(_overlap(z, r) > 0 for r in sanctioned)]
    dqs += [f"junk zone {z[0]:.1f}-{z[1]:.1f}s" for z in junk]
    outside = [(z, unsanctioned(*z)) for z in zones]
    dqs += [f"editorial run {z[0]:.1f}-{z[1]:.1f}s ({o:.1f}s outside)" for z, o in outside if o > EDITORIAL_RUN_S]
    pod_conf = [
        s["confidence"]
        for s in validation["spans"]
        if any(_overlap((s["start_time"], s["end_time"]), p) > 0 for p in pods)
    ]
    below = [c for c in pod_conf if c < 0.8]
    if gates["mode"] == "judge":
        check("pod span confidence >= 0.8", not below, f"min={min(pod_conf) if pod_conf else None}")
    check("complete", validation["complete"], ",".join(validation.get("warnings", [])))
    return {
        "profile": gates,
        "passed": all(c["passed"] for c in checks) and not dqs,
        "checks": checks,
        "failed": [f"{c['name']} ({c['detail']})" for c in checks if not c["passed"]],
        "disqualifiers": dqs,
        "min_pod_coverage": min((p["coverage"] for p in metrics["pods"]), default=None),
        "max_slack_s": round(max(slacks), 2) if slacks else None,
        "false_skip_s": metrics["false_skip_s"],
        "negative_hits": hits,
        "zones": len(zones),
        "pods_below_floor": len(below),
    }


def run_config(manifest, manifest_sha, names, out, config, design, chunk_id, params):
    spec = chunking.parse_spec(chunk_id)
    results = {}
    for name in names:
        fixture, request, request_path = manifest[name]
        summary = run_fixture(
            fixture=fixture, request=request, request_path=request_path, manifest_sha=manifest_sha,
            design=design, spec=spec, params=params, wording="w1",
            asker=OracleAsker(request, fixture["ground_truth"]), limits={"context_tokens": 10**9, "max_questions": 10**6},
            run_dir=out / config / f"{name}-1", model_label=ORACLE_MODEL, model_key=ORACLE_MODEL,
            repeat=1, tag=f"e0-oracle-{config}",
        )
        if summary["error"]:
            raise RuntimeError(f"{config}/{name}: {summary['error']}")
        results[name] = evaluate(name, request, fixture["ground_truth"], summary["validation"], summary["metrics"])
    return results


def cell(result):
    if result["passed"]:
        return f"PASS cov {result['min_pod_coverage'] if result['min_pod_coverage'] is None else round(result['min_pod_coverage'], 3)} fp {result['false_skip_s']} slack {result['max_slack_s']}"
    reasons = result["disqualifiers"][:2] + result["failed"][:2]
    return "FAIL " + "; ".join(reasons)


def render(table, configs, params_by_config):
    lines = ["# E0 oracle (ground truth through chunking + derivation + run.measure)", ""]
    lines.append("Rows: fixtures (wave 1 then wave 2). Cells: PASS with min pod coverage / FP s / max unsanctioned slack s, or FAIL with the first reasons.")
    lines.append("")
    lines.append("| fixture | wave | " + " | ".join(configs) + " |")
    lines.append("| --- | --- | " + " | ".join("---" for _ in configs) + " |")
    for name in [*WAVE1, *WAVE2]:
        if name not in table[configs[0]]:
            continue
        wave = "1" if name in WAVE1 else "2"
        lines.append(f"| {name} | {wave} | " + " | ".join(cell(table[c][name]) for c in configs) + " |")
    lines.append("")
    lines.append("| config | design | chunking | wave-1 passed | all passed | derive_params_sha256 |")
    lines.append("| --- | --- | --- | ---: | ---: | --- |")
    for config in configs:
        design, chunk_id, params = params_by_config[config]
        wave1 = [n for n in WAVE1 if n in table[config]]
        lines.append(
            f"| {config} | {design} | {chunk_id} | {sum(table[config][n]['passed'] for n in wave1)}/{len(wave1)} | "
            f"{sum(r['passed'] for r in table[config].values())}/{len(table[config])} | `{params.sha256()[:16]}` |"
        )
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True, help="ROOT/decision/e0-oracle")
    parser.add_argument("--fixtures", nargs="*")
    parser.add_argument("--configs", nargs="*", default=list(CONFIGS))
    parser.add_argument("--variant", action="append", default=[], help="LABEL=JSON DeriveParams overrides, run on every config")
    parser.add_argument("--replace", action="store_true", help="delete this tool's own earlier config dirs first (free, regenerable)")
    args = parser.parse_args(argv)
    manifest = load_manifest(args.manifest)
    manifest_sha = sha256_file(args.manifest)
    names = args.fixtures or [n for n in [*WAVE1, *WAVE2] if n in manifest]
    variants = {"": DeriveParams()}
    for item in args.variant:
        label, _, overrides = item.partition("=")
        variants[label] = DeriveParams().with_(**json.loads(overrides))
    table, params_by_config = {}, {}
    for base in args.configs:
        design, chunk_id = CONFIGS[base]
        for label, params in variants.items():
            config = f"{base}-{label}" if label else base
            target = args.out / config
            if target.exists():
                if not args.replace:
                    raise SystemExit(f"{target} exists; pass --replace to regenerate the oracle")
                shutil.rmtree(target)
            table[config] = run_config(manifest, manifest_sha, names, args.out, config, design, chunk_id, params)
            params_by_config[config] = (design, chunk_id, params)
    configs = list(table)
    write(args.out / "e0.json", {"model": ORACLE_MODEL, "manifest_sha256": manifest_sha, "configs": {
        c: {"design": params_by_config[c][0], "chunking": params_by_config[c][1],
            "derive_params": {**params_by_config[c][2].as_dict(), "sha256": params_by_config[c][2].sha256()},
            "fixtures": table[c]} for c in configs}})
    text = render(table, configs, params_by_config)
    (args.out / "E0.md").write_text(text)
    print(text)


if __name__ == "__main__":
    main()

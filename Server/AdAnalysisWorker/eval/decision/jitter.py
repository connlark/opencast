#!/usr/bin/env python3
"""Repeatability across repeats of one configuration (no inference).

Per fixture over runs `<fixture>-1..n` in one tag: max |delta p_ad| per chunk
(overall and on pod chunks, i.e. chunks overlapping a required pod), identical
installed zone sets, and boundary drift seconds (max |delta start| / |delta
end| between zones matched by overlap; an unmatched zone counts its whole
length). Saturated 0/1 answers are fine: only differences are taken, nothing
is divided. `median_of(docs)` builds the median-of-3 probabilities document,
which rederive treats as its own design.
"""

from __future__ import annotations

import argparse
import statistics
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "decision"  # noqa: A001

from .common import load_manifest, read, write  # noqa: E402

POD_JITTER_OK = 0.05
POD_JITTER_MEDIAN = 0.10
POD_JITTER_DROP = 0.15


def chunk_p(doc):
    out = []
    for c in doc["chunks"]:
        if "p_ad" in c:
            out.append(c["p_ad"])
        else:
            out.append(1.0 - c["choice"].get("content", 0.0))
    return out


def pod_chunks(doc, request, truth):
    by_id = {s["id"]: s for s in request["segments"]}
    pods = [(by_id[a]["start"], by_id[b]["end"]) for a, b in truth.get("pods", [])]
    return [
        c["index"]
        for c in doc["chunk_ranges"]
        if any(min(c["end"], b) - max(c["start"], a) > 0 for a, b in pods)
    ]


def drift(zones_a, zones_b):
    worst = 0.0
    for left, right in ((zones_a, zones_b), (zones_b, zones_a)):
        for z in left:
            match = [w for w in right if min(z[1], w[1]) - max(z[0], w[0]) > 0]
            if not match:
                worst = max(worst, z[1] - z[0])
            else:
                worst = max(worst, min(abs(z[0] - w[0]) for w in match), min(abs(z[1] - w[1]) for w in match))
    return round(worst, 3)


def compare(run_dirs, request, truth):
    docs = [read(d / "probabilities.json") for d in run_dirs]
    summaries = [read(d / "summary.json") for d in run_dirs]
    ps = [chunk_p(doc) for doc in docs]
    if len({len(p) for p in ps}) != 1:
        raise ValueError("Repeats chunked differently")
    delta = [max(p[k] for p in ps) - min(p[k] for p in ps) for k in range(len(ps[0]))]
    pod = pod_chunks(docs[0], request, truth)
    zones = [[tuple(z) for z in s["metrics"]["zones"]] for s in summaries]
    max_pod = max((delta[k] for k in pod), default=0.0)
    return {
        "runs": [str(d) for d in run_dirs],
        "max_abs_delta_p": round(max(delta, default=0.0), 6),
        "max_abs_delta_p_pod": round(max_pod, 6),
        "zone_sets_identical": all(z == zones[0] for z in zones),
        "boundary_drift_s": max((drift(zones[0], z) for z in zones[1:]), default=0.0),
        "repeat_rule": "1 more" if max_pod < POD_JITTER_OK else ("median-of-3" if max_pod > POD_JITTER_MEDIAN else "2"),
        "drop_vendor": max_pod > POD_JITTER_DROP,
    }


def median_of(docs):
    """Median-of-n probabilities document (chunk p's, refine and confirm p's
    present in every repeat)."""
    out = {**docs[0], "chunks": [], "refine": {}, "confirm": {}, "median_of": len(docs)}
    for k, first in enumerate(docs[0]["chunks"]):
        if "p_ad" in first:
            content = [d["chunks"][k].get("p_content") for d in docs]
            out["chunks"].append({
                "p_ad": statistics.median(d["chunks"][k]["p_ad"] for d in docs),
                "p_content": None if None in content else statistics.median(content),
            })
        else:
            keys = first["choice"]
            out["chunks"].append({"choice": {key: statistics.median(d["chunks"][k]["choice"][key] for d in docs) for key in keys}})
    for field in ("refine", "confirm"):
        common = set.intersection(*(set(d.get(field) or {}) for d in docs))
        out[field] = {key: statistics.median(d[field][key] for d in docs) for key in sorted(common)}
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runs", type=Path, required=True, help="tag dir with <fixture>-<n> runs")
    parser.add_argument("--out", type=Path, help="jitter.json (default <runs>/jitter.json)")
    args = parser.parse_args(argv)
    manifest = load_manifest(args.manifest)
    groups = {}
    for d in sorted(p.parent for p in args.runs.glob("*/probabilities.json")):
        stem, _, _ = d.name.rpartition("-")
        groups.setdefault(stem, []).append(d)
    report = {}
    for name, dirs in groups.items():
        if len(dirs) >= 2 and name in manifest:
            fixture, request, _ = manifest[name]
            report[name] = compare(dirs, request, fixture["ground_truth"])
    write(args.out or args.runs / "jitter.json", report)
    for name, row in report.items():
        print(name, row["max_abs_delta_p_pod"], row["zone_sets_identical"], row["boundary_drift_s"], row["repeat_rule"])


if __name__ == "__main__":
    main()

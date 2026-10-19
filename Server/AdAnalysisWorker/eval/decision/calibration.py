#!/usr/bin/env python3
"""Calibration picture of decision-model answers against ground truth (no inference).

For each configuration (`LABEL=DIR`, a tag directory of `<fixture>-<n>` runs)
every chunk of every run is classed by the manifest truth, by array index and
duration (pods win over optional, optional over negatives):

* `pod`: at least half the chunk's seconds lie in a required pod;
* `pod_edge`: some pod seconds, under half (a boundary chunk; any p is fair);
* `optional`: no pod seconds, some optional seconds (truth tolerates either);
* `negative`: no pod or optional seconds, some labelled-negative seconds
  (program the labellers flagged as ad-like: the false-positive risk);
* `content`: no labelled seconds at all (ordinary program).

Per class it reports n, a 10-bin histogram of the chunk P(ad) the derivation
sees (`derive.chunk_probabilities` under the frozen `DeriveParams`: b' p_ad;
c promotional mass plus transition next to a promotional chunk), the shares
of exact 0 and exact 1 answers (OpenAI Decisions saturates) and the mean; the
same for the content facet (b' p_content, c P(content)). Per configuration:
AUC of P(ad) for pod vs negative+content chunks (ties count half), the Brier
score against each chunk's pod-seconds share (optional chunks excluded), the
b' facet agreement (both facets >= 0.5, both < 0.5, mean |p_ad + p_content - 1|),
for c the mean option distribution per class, and for (d) runs a histogram of
the refinement p's per segment class. The worst content/negative chunks
(highest P(ad)) and the weakest pod chunks (lowest P(ad)) are listed so a
reader can open the archive.

Writes the markdown at `--out` and a JSON sidecar beside it. Reported, never
gated.
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
from .derive import DeriveParams, chunk_design, chunk_probabilities  # noqa: E402

CLASSES = ("pod", "pod_edge", "optional", "negative", "content")
SEGMENT_CLASSES = ("pod", "optional", "negative", "content")
BINS = 10
WORST = 8


def segment_labels(request, truth):
    """Per array index: 'pod' > 'optional' > 'negative' > 'content'."""
    positions = {s["id"]: i for i, s in enumerate(request["segments"])}
    labels = ["content"] * len(request["segments"])
    for key in ("negatives", "optional", "pods"):
        name = {"negatives": "negative", "optional": "optional", "pods": "pod"}[key]
        for a, b in truth.get(key, []):
            for i in range(positions[a], positions[b] + 1):
                labels[i] = name
    return labels


def chunk_class(request, labels, first, last):
    seconds = {name: 0.0 for name in SEGMENT_CLASSES}
    for i in range(first, last + 1):
        s = request["segments"][i]
        seconds[labels[i]] += max(1e-9, s["end"] - s["start"])
    total = sum(seconds.values())
    pod_share = seconds["pod"] / total
    if pod_share >= 0.5:
        name = "pod"
    elif pod_share > 0:
        name = "pod_edge"
    elif seconds["optional"] > 0:
        name = "optional"
    elif seconds["negative"] > 0:
        name = "negative"
    else:
        name = "content"
    return name, pod_share


def histogram(values):
    counts = [0] * BINS
    for p in values:
        counts[min(BINS - 1, int(p * BINS))] += 1
    return counts


def describe(values):
    if not values:
        return {"n": 0, "hist": [0] * BINS, "exact0": None, "exact1": None, "mean": None, "median": None}
    return {
        "n": len(values),
        "hist": histogram(values),
        "exact0": round(sum(p == 0.0 for p in values) / len(values), 4),
        "exact1": round(sum(p == 1.0 for p in values) / len(values), 4),
        "mean": round(statistics.mean(values), 4),
        "median": round(statistics.median(values), 4),
    }


def auc(positives, negatives):
    """P(random positive > random negative), ties half (rank form)."""
    if not positives or not negatives:
        return None
    pooled = sorted([(p, 1) for p in positives] + [(p, 0) for p in negatives])
    rank_sum, i = 0.0, 0
    while i < len(pooled):
        j = i
        while j < len(pooled) and pooled[j][0] == pooled[i][0]:
            j += 1
        mid = (i + 1 + j) / 2  # mean 1-based rank of the tie block
        rank_sum += mid * sum(flag for _, flag in pooled[i:j])
        i = j
    n_pos, n_neg = len(positives), len(negatives)
    return round((rank_sum - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg), 4)


def collect(directory, manifest, params, fixtures=None):
    """Chunk rows and refinement rows over every run in a tag directory
    (only the named fixtures when `fixtures` is given)."""
    chunks, refine, runs, designs = [], [], [], set()
    for path in sorted(Path(directory).glob("*/probabilities.json")):
        run = path.parent.name
        name = run.rpartition("-")[0]
        if name not in manifest or (fixtures and name not in fixtures):
            continue
        fixture, request, _ = manifest[name]
        doc = read(path)
        if doc["segment_ids"] != [s["id"] for s in request["segments"]]:
            raise ValueError(f"{path}: segment ids differ from the manifest request")
        design = doc["design"]
        designs.add(design)
        labels = segment_labels(request, fixture["ground_truth"])
        probs = chunk_probabilities(doc["chunks"], chunk_design(design), params)
        runs.append(run)
        for c, (p_ad, p_content, _), answer in zip(doc["chunk_ranges"], probs, doc["chunks"]):
            klass, share = chunk_class(request, labels, c["first"], c["last"])
            chunks.append({
                "run": run, "fixture": name, "chunk": c["label"], "start": c["start"], "end": c["end"],
                "class": klass, "pod_share": round(share, 4), "p_ad": p_ad, "p_content": p_content,
                "choice": answer.get("choice"),
            })
        for index, p in (doc.get("refine") or {}).items():
            refine.append({"run": run, "segment": int(index), "class": labels[int(index)], "p": p})
    return {"runs": runs, "designs": sorted(designs), "chunks": chunks, "refine": refine}


def summarise(label, data):
    rows = data["chunks"]
    by_class = {k: [r for r in rows if r["class"] == k] for k in CLASSES}
    out = {
        "configuration": label,
        "runs": len(data["runs"]),
        "designs": data["designs"],
        "chunks": len(rows),
        "p_ad": {k: describe([r["p_ad"] for r in v]) for k, v in by_class.items()},
        "p_content": {k: describe([r["p_content"] for r in v if r["p_content"] is not None]) for k, v in by_class.items()},
        "auc_pod_vs_program": auc(
            [r["p_ad"] for r in by_class["pod"]], [r["p_ad"] for r in by_class["negative"] + by_class["content"]]
        ),
        "auc_pod_vs_negative": auc([r["p_ad"] for r in by_class["pod"]], [r["p_ad"] for r in by_class["negative"]]),
    }
    scored = [r for r in rows if r["class"] != "optional"]
    out["brier_vs_pod_share"] = round(statistics.mean((r["p_ad"] - r["pod_share"]) ** 2 for r in scored), 4) if scored else None
    facet = [r for r in rows if r["p_content"] is not None and r["choice"] is None]
    if facet:
        out["facets"] = {
            "both_yes": sum(r["p_ad"] >= 0.5 and r["p_content"] >= 0.5 for r in facet),
            "both_no": sum(r["p_ad"] < 0.5 and r["p_content"] < 0.5 for r in facet),
            "mean_abs_sum_minus_1": round(statistics.mean(abs(r["p_ad"] + r["p_content"] - 1) for r in facet), 4),
        }
    choice = [r for r in rows if r["choice"]]
    if choice:
        options = list(choice[0]["choice"])
        out["choice_mean"] = {
            k: {o: round(statistics.mean(r["choice"][o] for r in v), 4) for o in options}
            for k, v in ((k, [r for r in choice if r["class"] == k]) for k in CLASSES)
            if v
        }
    if data["refine"]:
        out["refine_p"] = {k: describe([r["p"] for r in data["refine"] if r["class"] == k]) for k in SEGMENT_CLASSES}
    program = sorted(by_class["negative"] + by_class["content"], key=lambda r: -r["p_ad"])
    out["worst_program"] = [_brief(r) for r in program[:WORST]]
    out["weakest_pod"] = [_brief(r) for r in sorted(by_class["pod"], key=lambda r: r["p_ad"])[:WORST]]
    return out


def _brief(row):
    return {k: row[k] for k in ("run", "chunk", "class", "start", "end", "pod_share", "p_ad", "p_content")}


def _fmt(value):
    return "-" if value is None else (f"{value:.3f}" if isinstance(value, float) else str(value))


def _table(title, stats, classes):
    lines = [f"**{title}**", "", "| class | n | " + " | ".join(f"{b / BINS:.1f}" for b in range(BINS)) + " | =0 | =1 | mean | median |"]
    lines.append("|" + " --- |" * (BINS + 6))
    for k in classes:
        s = stats[k]
        if not s["n"]:
            continue
        lines.append(
            f"| {k} | {s['n']} | " + " | ".join(str(c) for c in s["hist"])
            + f" | {_fmt(s['exact0'])} | {_fmt(s['exact1'])} | {_fmt(s['mean'])} | {_fmt(s['median'])} |"
        )
    return lines + [""]


def render(reports):
    lines = [
        "# Decision-model calibration (generated by eval/decision/calibration.py)",
        "",
        "Chunk classes by truth seconds: `pod` >= 50 % pod seconds, `pod_edge` some but < 50 %, `optional` "
        "optional seconds and no pod, `negative` labelled-negative seconds and no pod/optional, `content` "
        "unlabelled program. Histogram bins are [0.0, 0.1) ... [0.9, 1.0]; `=0` / `=1` are the shares of "
        "exact 0 and exact 1 answers. P(ad) is what the derivation sees (b' `p_ad`; c promotional mass plus "
        "transition next to a promotional chunk).",
        "",
        "| config | runs | chunks | AUC pod vs program | AUC pod vs negative | Brier | pod mean | negative mean | content mean | exact 0/1 share | facets both-yes / both-no |",
        "|" + " --- |" * 11,
    ]
    for r in reports:
        sat = [s for s in r["p_ad"].values() if s["n"]]
        n = sum(s["n"] for s in sat)
        exact = sum((s["exact0"] + s["exact1"]) * s["n"] for s in sat) / n if n else None
        facets = r.get("facets")
        lines.append(
            f"| {r['configuration']} | {r['runs']} | {r['chunks']} | {_fmt(r['auc_pod_vs_program'])} | "
            f"{_fmt(r['auc_pod_vs_negative'])} | {_fmt(r['brier_vs_pod_share'])} | {_fmt(r['p_ad']['pod']['mean'])} | "
            f"{_fmt(r['p_ad']['negative']['mean'])} | {_fmt(r['p_ad']['content']['mean'])} | {_fmt(round(exact, 4) if exact is not None else None)} | "
            + (f"{facets['both_yes']} / {facets['both_no']} |" if facets else "- |")
        )
    lines.append("")
    for r in reports:
        lines += [f"## {r['configuration']}", "", f"Designs {', '.join(r['designs'])}; {r['runs']} runs, {r['chunks']} chunks.", ""]
        lines += _table("P(ad) per chunk class", r["p_ad"], CLASSES)
        if any(s["n"] for s in r["p_content"].values()):
            lines += _table("Content facet per chunk class", r["p_content"], CLASSES)
        if r.get("facets"):
            f = r["facets"]
            lines += [f"Facet agreement: both >= 0.5 on {f['both_yes']} chunks, both < 0.5 on {f['both_no']}, mean |p_ad + p_content - 1| {f['mean_abs_sum_minus_1']}.", ""]
        if r.get("choice_mean"):
            options = list(next(iter(r["choice_mean"].values())))
            lines += ["**Mean choice distribution per class**", "", "| class | " + " | ".join(options) + " |", "|" + " --- |" * (len(options) + 1)]
            lines += [f"| {k} | " + " | ".join(f"{v[o]:.3f}" for o in options) + " |" for k, v in r["choice_mean"].items()]
            lines.append("")
        if r.get("refine_p"):
            lines += _table("Refinement p per segment class", r["refine_p"], SEGMENT_CLASSES)
        for title, key in (("Highest P(ad) on program chunks", "worst_program"), ("Lowest P(ad) on pod chunks", "weakest_pod")):
            if r[key]:
                lines += [f"**{title}**", "", "| run | chunk | class | start-end s | pod share | P(ad) | content facet |", "|" + " --- |" * 7]
                lines += [
                    f"| {x['run']} | {x['chunk']} | {x['class']} | {x['start']:.1f}-{x['end']:.1f} | {x['pod_share']} | {x['p_ad']:.4f} | {_fmt(x['p_content'])} |"
                    for x in r[key]
                ]
                lines.append("")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runs", action="append", required=True, help="LABEL=DIR (a tag directory)")
    parser.add_argument("--out", type=Path, required=True, help="markdown path; JSON sidecar beside it")
    parser.add_argument("--fixtures", nargs="*", help="only these fixtures (same-fixture comparisons)")
    args = parser.parse_args(argv)
    manifest = load_manifest(args.manifest)
    params = DeriveParams()
    reports = []
    for item in args.runs:
        label, _, directory = item.partition("=")
        if not directory:
            parser.error("--runs takes LABEL=DIR")
        reports.append(summarise(label, collect(directory, manifest, params, set(args.fixtures or ()))))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render(reports))
    write(args.out.with_suffix(".json"), reports)
    print(render(reports).split("\n## ")[0])


if __name__ == "__main__":
    main()

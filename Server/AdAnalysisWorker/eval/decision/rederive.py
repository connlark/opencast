#!/usr/bin/env python3
"""Replay derivation with other `DeriveParams`, no inference.

Reads each run's archived `probabilities.json` (+ `fixture.json` for the
request, verified against the manifest hash) and writes a new tag whose
summary.json has `calls: []`, `cost_usd: 0` and `rederived_from`. Refinement
and confirmation p's exist only for the runs the original params produced: a
run the new params create without them keeps its chunk boundary on that side
(`refine_missing`) and, lacking a confirmation, is not installed
(`no_confidence`); both are counted in `rederive_gaps`.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "decision"  # noqa: A001

from .chunking import Chunk  # noqa: E402
from .common import load_manifest, read, write  # noqa: E402
from .derive import LOCALISER, DeriveParams, derive  # noqa: E402
from .run_decision import summarise  # noqa: E402


def rederive_run(run_dir, manifest, params):
    fixture_doc = read(run_dir / "fixture.json")
    name = fixture_doc["fixture"]["name"]
    fixture, request, _ = manifest[name]
    if fixture_doc["request_sha256"] != fixture["request_sha256"]:
        raise ValueError(f"{run_dir}: request hash differs from the manifest")
    doc = read(run_dir / "probabilities.json")
    original = read(run_dir / "summary.json")
    chunks = [Chunk(c["index"], c["first"], c["last"], c["start"], c["end"]) for c in doc["chunk_ranges"]]
    design = original["design"]
    started = time.monotonic()
    derivation = derive(request, chunks, doc, LOCALISER.get(design, design), params)
    gaps = sum(
        "refine_missing" in (s["decision"].get("refine_notes") or []) for s in derivation["raw_spans"]
    ) + sum(r["reason"] == "no_confidence" for r in derivation["rejected_runs"])
    spec = {k: v for k, v in original["chunking"].items() if k in ("kind", "size")}
    summary = summarise(
        model_label=original["model"], model_key=original.get("model_key", original["model"]), design=design,
        spec=spec, params=params, wording=original["question_set"]["wording"], request=request, fixture=fixture,
        derivation=derivation, calls=[], elapsed=time.monotonic() - started, error=None,
        extra={"rederived_from": str(run_dir), "rederive_gaps": gaps, "source_cost_usd": original.get("cost_usd")},
    )
    return derivation, summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runs", type=Path, required=True, help="a tag directory of decision runs")
    parser.add_argument("--out", type=Path, required=True, help="the new tag directory")
    parser.add_argument("--derive-params", default="{}", help="JSON overrides of DeriveParams")
    args = parser.parse_args(argv)
    manifest = load_manifest(args.manifest)
    params = DeriveParams().with_(**json.loads(args.derive_params))
    for run_dir in sorted(p.parent for p in args.runs.glob("*/probabilities.json")):
        target = args.out / run_dir.name
        if target.exists():
            raise SystemExit(f"{target} exists, refusing overwrite")
        derivation, summary = rederive_run(run_dir, manifest, params)
        write(target / "fixture.json", {**read(run_dir / "fixture.json"), "derive_params_sha256": params.sha256(), "rederived_from": str(run_dir)})
        write(target / "derivation.json", derivation)
        write(target / "summary.json", summary)
        print(json.dumps({"run": str(target), "complete": summary["validation"]["complete"],
                          "pods": [round(p["coverage"], 3) for p in summary["metrics"]["pods"]],
                          "false_skip_s": summary["metrics"]["false_skip_s"], "rederive_gaps": summary["rederive_gaps"]}))


if __name__ == "__main__":
    main()

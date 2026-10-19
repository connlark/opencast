#!/usr/bin/env python3
"""Offline cost estimate of a decision-model experiment (no network, no ledger).

Runs the real pipeline (`run_decision.analyse`: chunking, `plan_windows`,
question rendering, `--questions-per-request` grouping, (d)'s refinement and
confirmation planning) with ground-truth answers, and pages every ask exactly
as Lane A's adapter would (`providers.systemone.build_decision_request`: the
vendor's `max_questions` and context; every page re-sends the whole state).
For (d) the refinement and confirmation asks follow the ORACLE's runs, so
they are a typical count, not a bound: a real model that opens more runs asks
more. For (a) every segment is its own ask. H1's generative calls are not
estimated here (only its b' localiser).

Per page two token numbers:

* `expected`: Step 0's pplx billing model, state bytes / 3.8 plus each
  rendered question's bytes / 3.8 + 14 (the q1 vs q20 smoke: 2,286 vs 3,020
  tokens for 8,544 state bytes and ~95-byte questions). Refined from measured
  usage after the first batch (`--chars-per-token`, `--question-overhead`).
* `bound`: the adapter's own pessimistic `page_tokens` (bytes / 3 plus fixed
  allowances), the number the ledger reservation is built from
  (reservation = 2 x bound + 2,048 tokens, released on settlement).

`--vendor-max-questions N` prices a what-if paging (e.g. pplx-flash grouped)
through a copy of the adapter with that cap, in this process only; Lane A's
adapter is not changed.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "decision"  # noqa: A001

from . import chunking  # noqa: E402
from .common import WAVE1, adapter_override, lane_a, load_manifest  # noqa: E402
from .derive import DeriveParams  # noqa: E402
from .run_decision import OracleAsker, analyse, load_limits  # noqa: E402

CHARS_PER_TOKEN = 3.8
QUESTION_OVERHEAD = 14


class EstimatingAsker:
    """Oracle answers; records the vendor pages each ask would send."""

    def __init__(self, request, truth, model, chars_per_token, question_overhead):
        self.oracle = OracleAsker(request, truth)
        self.model = model
        self.cpt, self.overhead = chars_per_token, question_overhead
        self.pages = []
        self.asks = 0
        systemone = lane_a("providers.systemone")
        self.build = systemone.build_decision_request
        self.adapter_for = lane_a("providers").adapter_for

    def expected_tokens(self, state, rendered):
        state_tokens = len(state.encode()) / self.cpt
        question_tokens = sum(
            len(json.dumps(item, ensure_ascii=False).encode()) / self.cpt + self.overhead
            for item in (rendered.values() if isinstance(rendered, dict) else rendered)
        )
        return math.ceil(state_tokens + question_tokens)

    def __call__(self, stage, directory, state, question_list, context, hints):
        self.asks += 1
        adapter = self.adapter_for(self.model)
        for page in self.build(state, self.model, question_list):
            rendered = adapter.render_questions(page["questions"])
            self.pages.append({
                "stage": stage,
                "tag": Path(directory).name,
                "questions": len(page["questions"]),
                "expected": self.expected_tokens(state, rendered),
                "bound": adapter.page_tokens(page["body"], page["questions"]),
            })
        return self.oracle(stage, directory, state, question_list, context, hints)


def estimate_fixture(name, manifest, *, model, design, spec, params, wording, limits, qpr, cpt, overhead):
    fixture, request, _ = manifest[name]
    asker = EstimatingAsker(request, fixture["ground_truth"], model, cpt, overhead)
    analyse(request, design, spec, params, wording, asker, limits, Path("/nonexistent"), {}, [], qpr)
    price = lane_a("budget").PRICES[model][0]
    expected = sum(p["expected"] for p in asker.pages)
    bound = sum(p["bound"] for p in asker.pages)
    stages = {}
    for p in asker.pages:
        s = stages.setdefault(p["stage"], {"pages": 0, "questions": 0, "expected_tokens": 0})
        s["pages"] += 1
        s["questions"] += p["questions"]
        s["expected_tokens"] += p["expected"]
    return {
        "fixture": name,
        "audio_s": (request.get("transcript") or {}).get("audio_duration"),
        "asks": asker.asks,
        "pages": len(asker.pages),
        "questions": sum(p["questions"] for p in asker.pages),
        "expected_tokens": expected,
        "bound_tokens": bound,
        "expected_usd": round(expected * price / 1e6, 6),
        "bound_usd": round(bound * price / 1e6, 6),
        "stages": stages,
    }


def estimate(manifest, names, *, model, design, chunking_id, repeats, providers=None, wording="w1", qpr=None,
             vendor_max_questions=None, cpt=CHARS_PER_TOKEN, overhead=QUESTION_OVERHEAD):
    spec = {"kind": "segments", "size": 1} if design == "a" else chunking.parse_spec(chunking_id)
    params = DeriveParams()
    with adapter_override(model, vendor_max_questions):
        limits = load_limits(model, providers)
        rows = [
            estimate_fixture(n, manifest, model=model, design={"h1": "b_prime", "h1_c": "c"}.get(design, design), spec=spec,
                             params=params, wording=wording, limits=limits, qpr=qpr, cpt=cpt, overhead=overhead)
            for n in names
        ]
    per_repeat = {k: sum(r[k] for r in rows) for k in ("asks", "pages", "questions", "expected_tokens", "bound_tokens")}
    per_repeat["expected_usd"] = round(sum(r["expected_usd"] for r in rows), 6)
    per_repeat["bound_usd"] = round(sum(r["bound_usd"] for r in rows), 6)
    return {
        "model": model,
        "design": design,
        "chunking": chunking_id,
        "questions_per_request": qpr,
        "vendor_max_questions": vendor_max_questions,
        "repeats": repeats,
        "chars_per_token": cpt,
        "question_overhead": overhead,
        "fixtures": rows,
        "per_repeat": per_repeat,
        "total_expected_usd": round(per_repeat["expected_usd"] * repeats, 6),
        "total_bound_usd": round(per_repeat["bound_usd"] * repeats, 6),
        "total_pages": per_repeat["pages"] * repeats,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--providers", type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--design", choices=("b_prime", "c", "d", "d_c", "a", "h1", "h1_c"), required=True)
    parser.add_argument("--chunking", default="sec30")
    parser.add_argument("--wording", default="w1")
    parser.add_argument("--fixtures", nargs="*")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--questions-per-request", type=int)
    parser.add_argument("--vendor-max-questions", type=int, help="what-if adapter paging cap (this process only)")
    parser.add_argument("--chars-per-token", type=float, default=CHARS_PER_TOKEN)
    parser.add_argument("--question-overhead", type=float, default=QUESTION_OVERHEAD)
    parser.add_argument("--out", type=Path, help="write the JSON here too")
    args = parser.parse_args(argv)
    manifest = load_manifest(args.manifest)
    names = args.fixtures or list(WAVE1)
    result = estimate(
        manifest, names, model=args.model, design=args.design, chunking_id=args.chunking, repeats=args.repeats,
        providers=args.providers, wording=args.wording, qpr=args.questions_per_request,
        vendor_max_questions=args.vendor_max_questions, cpt=args.chars_per_token, overhead=args.question_overhead,
    )
    text = json.dumps(result, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n")
    for r in result["fixtures"]:
        print(f"{r['fixture']:40s} asks {r['asks']:4d} pages {r['pages']:5d} q {r['questions']:5d} "
              f"exp {r['expected_tokens']:9d} tok ${r['expected_usd']:.5f} bound ${r['bound_usd']:.5f}")
    print(json.dumps({k: result[k] for k in ("model", "design", "questions_per_request", "vendor_max_questions", "repeats",
                                             "total_pages", "total_expected_usd", "total_bound_usd")}))


if __name__ == "__main__":
    main()

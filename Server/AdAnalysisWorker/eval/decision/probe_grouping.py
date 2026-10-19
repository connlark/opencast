#!/usr/bin/env python3
"""One-request grouping probe: does a decision vendor take N questions in ONE request?

Lane A's adapter pages `pplx-decider-flash-latest` at one question per
request (the vendor's "one question per request by default" advice), so every
question re-bills the whole state. This probe sends Step 0's smoke passage
(`ROOT/smoke/snippet.txt`: sentences 1-5 a sponsor read, 6-10 editorial) with
four questions of known truth in a single request, through Lane A's own
`providers.systemone.ask` (reserve, call, archive, settle on the ONE ledger)
and a copy of the adapter whose `max_questions` is the question count, in this
process only (`common.adapter_override`); Lane A's adapter is not edited. It
refuses to run if the plan is not exactly one page, and refuses to create a
ledger.

Archive: `<out>/<tag>/` holds `ask`'s request.json, wire-request.json,
response.json and summary.json (budget --verify reconciles it) plus
`probe.json` (truth, answers, usage, and Step 0's single-question flash call
on the same passage: 396 input tokens, p 0.9956 for `sponsor_read`).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "decision"  # noqa: A001

from .common import adapter_override, lane_a, write  # noqa: E402

QUESTIONS = [
    ("sponsor_read", "Does the passage begin with a paid sponsor read?", True),
    ("s3_ad", "Is sentence [3] part of a paid sponsor read or advertisement?", True),
    ("s7_ad", "Is sentence [7] part of a paid sponsor read or advertisement?", False),
    ("s9_ad", "Is sentence [9] part of a paid sponsor read or advertisement?", False),
]
STEP0_SINGLE = {"input_tokens": 396, "sponsor_read": 0.9956387195413222, "state": "object {passage}"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="pplx-decider-flash-latest")
    parser.add_argument("--snippet", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--max-spend", type=float, required=True, help="the ledger's current cap")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args(argv)
    if not args.ledger.exists():
        parser.error("The shared ledger must already exist; this probe never creates one")
    out_dir = args.out / args.tag
    if out_dir.exists():
        parser.error(f"{out_dir} exists, refusing overwrite")
    state = args.snippet.read_text()
    questions = [{"id": qid, "type": "noul", "instructions": text} for qid, text, _ in QUESTIONS]
    systemone = lane_a("providers.systemone")
    with adapter_override(args.model, len(questions)):
        pages = systemone.build_decision_request(state, args.model, questions)
        if len(pages) != 1:
            raise SystemExit(f"Planned {len(pages)} pages, not one; nothing sent")
        ledger = lane_a("budget").Ledger(args.ledger, args.max_spend)
        result = systemone.ask(
            args.model, state, questions, args.key_file.read_text().strip(), ledger, out_dir,
            {"stage": "probe", "tag": args.tag, "probe": "grouping"},
        )
    report = {
        "model": args.model,
        "questions_in_one_request": len(questions),
        "pages": result["pages"],
        "usage": result["usage"],
        "cost_usd": result["cost_usd"],
        "latency_ms": result["latency_ms"],
        "errors": result["errors"],
        "answers": [
            {"id": qid, "truth": truth, "p": result["answers"].get(qid)} for qid, _, truth in QUESTIONS
        ],
        "step0_single_question": STEP0_SINGLE,
    }
    write(out_dir / "probe.json", report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

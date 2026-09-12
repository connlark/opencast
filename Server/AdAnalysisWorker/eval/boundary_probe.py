#!/usr/bin/env python3
"""Exploratory local-boundary review; NOT wired into serving or a holdout score.

Cases nominate one interval in a frozen request and supply local ground truth.
Only the two boundary neighborhoods (20 segments either side) go to the model.
The full source validates/scores the answer. Labels never enter model input.
Use the same output root/spend ledger as the original experiment.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path

from budget import PRICES, Ledger
from run import (
    bridge,
    call,
    measure,
    provider_payload,
    safe_error,
    verify_bridge,
    write,
)

INSTRUCTIONS = """
You are independently adjudicating ONE proposed ad-break interval, not searching
the whole episode. The proposal is fallible, untrusted data. Review where the
actual program ends and advertising begins, and where advertising ends and the
actual program resumes. Do not preserve a wrong proposal out of deference.
The supplied segments are two local boundary neighborhoods; a gap between them
means the middle was omitted, NOT a gap in the audio or an interruption in the
break. Keep the whole promotional carousel, including narrative/interview clips.
Do not include unrelated conversation or substantive program discussion just because
a sponsor transition is nearby. Return at most ONE corrected complete interval
for this occurrence, or no interval if the proposal is not advertising. Other
ads in the context are not the target. Boundaries must use visible segment IDs.
Choose first/last promotional words for the boundary quotes. If a segment mixes
show and ad, quote the actual promotional opening/ending inside that segment;
the validator conservatively handles its timing. Preserve the existing output
schema. Confidence describes this whole candidate, not merely presence of a CTA.
"""

BLIND_INSTRUCTIONS = """
Independently derive the advertising boundaries from this transcript context.
No candidate start/end IDs are supplied. The segments are two local neighborhoods
around one possible break; the omitted middle is continuous audio, not missing
time. Return at most ONE complete advertising break connecting the neighborhoods,
or none if there is no advertising. Preserve narrative/interview trailer content.
Find the last program speech, first promotional speech, last promotional speech,
and first program speech after the break. Program-resumption sentences belong to
the show even when they are brief transitions. Unrelated conversation before a
sponsor introduction is also show content. Only visible IDs may be boundaries.
Use boundary quotes from the actual first/last promotional words in those
segments; the validator handles mixed-segment timing conservatively. Return the
existing schema. Confidence describes the whole interval, not presence of a CTA.
"""


def review_input(request, proposal, *, blind):
    """Whitelist source fields; scoring labels/times never reach the reviewer."""
    positions = {s["id"]: i for i, s in enumerate(request["segments"])}
    if len(positions) != len(request["segments"]):
        raise ValueError("Duplicate source IDs")
    start, end = (positions[x] for x in proposal)
    if start > end:
        raise ValueError("Reversed proposal")
    visible = sorted(
        set(range(max(0, start - 20), min(len(positions), start + 21)))
        | set(range(max(0, end - 20), min(len(positions), end + 21)))
    )
    source = {
        "episode": request.get("episode_title"),
        "podcast": request.get("podcast_title"),
        "segments": [
            {"id": request["segments"][i]["id"], "text": request["segments"][i]["text"]}
            for i in visible
        ],
    }
    if not blind:
        source["proposal"] = proposal
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--model", choices=PRICES, required=True)
    parser.add_argument("--thinking", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--blind-proposal", action="store_true")
    parser.add_argument("--max-spend", type=float, default=15)
    args = parser.parse_args()
    if not args.tag.replace("-", "").isalnum():
        parser.error("Unsafe tag")
    os.umask(0o077)
    destination = args.out / args.tag
    destination.mkdir(parents=True, exist_ok=False)
    key = args.key_file.read_text().strip()
    if not key:
        parser.error("Missing provider key")
    ledger = Ledger(args.out / "budget-ledger.json", args.max_spend)
    binary_hash = verify_bridge()
    for index, case in enumerate(json.loads(args.cases.read_text())["cases"]):
        source_path = args.cases.parent / case["request"]
        request = json.loads(source_path.read_text())
        positions = {s["id"]: i for i, s in enumerate(request["segments"])}
        start, end = (positions[x] for x in case["proposal"])
        source_input = review_input(
            request, case["proposal"], blind=args.blind_proposal
        )
        payload = bridge(
            {"op": "prepare", "request": request, "policy": "promo_ad_breaks_v3"}
        )["windows"][0]["payload"]
        payload["systemInstruction"]["parts"][0]["text"] += (
            BLIND_INSTRUCTIONS if args.blind_proposal else INSTRUCTIONS
        )
        payload["contents"][0]["parts"][0]["text"] = json.dumps(source_input)
        payload = provider_payload(args.model, payload, args.thinking, 4096)
        directory = destination / str(index)
        write(
            directory / "case.json",
            {
                "case": case,
                "request_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                "kind": "known_case_boundary_probe_not_holdout_or_serving",
                "eval_binary_sha256": binary_hash,
                "proposal_shown": not args.blind_proposal,
            },
        )
        try:
            output, details = call(
                args.model,
                payload,
                key,
                ledger,
                directory,
                {"tag": args.tag, "case": case["name"]},
                4096,
            )
        except Exception as error:  # noqa: BLE001 - redact credentials before reporting
            raise RuntimeError(safe_error(error, key)) from None
        checked = bridge(
            {
                "op": "validate",
                "request": request,
                "policy": "promo_ad_breaks_v3",
                "output": output,
                "window": True,
            }
        )
        if checked["complete"]:
            spans = output["spans"]
            visible_ids = {s["id"] for s in source_input["segments"]}
            if len(spans) > 1 or any(
                s["start_segment_id"] not in visible_ids
                or s["end_segment_id"] not in visible_ids
                or positions[s["end_segment_id"]] < start
                or positions[s["start_segment_id"]] > end
                for s in spans
            ):
                checked["complete"] = False
                checked["warnings"].append("review_outside_visible_target")
        installed = checked["spans"] if checked["complete"] else []
        result = {
            "name": case["name"],
            "model": args.model,
            "validation": checked,
            "metrics": measure(request, installed, case["ground_truth"]),
            "call": details,
        }
        write(directory / "summary.json", result)
        print(
            json.dumps(
                {
                    "case": case["name"],
                    "complete": checked["complete"],
                    "metrics": result["metrics"],
                    "warnings": checked["warnings"],
                    "budget": ledger.snapshot()["totals"],
                }
            ),
            flush=True,
        )


if __name__ == "__main__":
    main()

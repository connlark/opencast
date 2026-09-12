"""Revalidate archived model responses without inference or changing history.

This measures a validator change, NOT another model trial. If validation now
requires a repair that was not captured, report incomplete instead of inventing
one. Use the original fixture manifest and preserve its frozen labels.
"""

import argparse
import copy
import hashlib
import json
from pathlib import Path

from run import answer_of, bridge, measure, verify_bridge, write


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    digest = verify_bridge()
    fixtures = {f["name"]: f for f in json.loads(args.manifest.read_text())["fixtures"]}
    for original in sorted(args.runs.glob("*/summary.json")):
        source = json.loads(original.read_text())
        metadata = json.loads(original.with_name("fixture.json").read_text())
        fixture = fixtures[metadata["fixture"]["name"]]
        path = args.manifest.parent / fixture["request"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != metadata["request_sha256"]:
            raise ValueError("Source transcript changed since original run")
        request = json.loads(path.read_text())
        if source["policy"] != "promo_ad_breaks_v3":
            raise ValueError("Replay requires archived v3 inputs")
        # Preserve the ORIGINAL model's view, even if current windowing changed.
        # Feeding a 2,000-segment answer to a new 800-segment scope is not replay.
        by_id = {s["id"]: s for s in request["segments"]}
        windows = []
        covered = set()
        for saved in sorted(
            original.parent.glob("window-*/request.json"),
            key=lambda p: int(p.parent.name.split("-")[1]),
        ):
            payload = json.loads(saved.read_text())
            text = (
                payload["contents"][0]["parts"][0]["text"]
                if "contents" in payload
                else payload["input"][0]["content"][0]["text"]
            )
            segments = json.loads(text)["segments"]
            if any(
                s != {"id": by_id[s["id"]]["id"], "text": by_id[s["id"]]["text"]}
                for s in segments
            ):
                raise ValueError(
                    "Archived model view does not match original transcript"
                )
            window = copy.deepcopy(request)
            window["segments"] = [by_id[s["id"]] for s in segments]
            window["transcript"]["segment_count"] = len(segments)
            windows.append({"request": window})
            covered.update(s["id"] for s in segments)
        combined = []
        issues = (
            [] if covered == set(by_id) else ["archived_window_coverage_incomplete"]
        )
        for i, window in enumerate(windows):

            def read_response(
                directory, run_path=original.parent, model=source["model"]
            ):
                response_path = run_path / directory / "response.json"
                if not response_path.exists():
                    return None
                try:
                    return answer_of(model, json.loads(response_path.read_text()))
                except (ValueError, KeyError, TypeError):
                    return None

            def validate(output, window_request=window["request"]):
                return bridge(
                    {
                        "op": "validate",
                        "policy": "promo_ad_breaks_v3",
                        "request": window_request,
                        "output": output,
                        "window": True,
                    }
                )

            output = read_response(f"window-{i}")
            checked = validate(output)
            if not checked["complete"]:
                before = output
                output = read_response(f"repair-{i}")
                repaired = validate(output)
                if (
                    before is not None
                    and "v3_malformed_model_json" not in checked["warnings"]
                    and repaired["complete"]
                ):
                    repaired = bridge(
                        {
                            "op": "check_repair",
                            "policy": "promo_ad_breaks_v3",
                            "request": window["request"],
                            "before": before,
                            "output": output,
                        }
                    )
                checked = repaired
            if checked["complete"]:
                combined.extend(output["spans"])
            else:
                issues.extend(checked["warnings"])
        validated = bridge(
            {
                "op": "validate",
                "policy": "promo_ad_breaks_v3",
                "request": request,
                "output": {"spans": combined},
            }
        )
        validated["warnings"].extend(issues)
        validated["complete"] = not validated["warnings"]
        installed = validated["spans"] if validated["complete"] else []
        result = {
            "kind": "offline_revalidation_not_new_model_trial",
            "source": str(original),
            "eval_binary_sha256": digest,
            "validation": validated,
            "metrics": measure(request, installed, fixture["ground_truth"]),
        }
        write(args.out / (original.parent.name + ".json"), result)
        print(
            json.dumps(
                {
                    "run": original.parent.name,
                    "metrics": result["metrics"],
                    "warnings": validated["warnings"],
                }
            )
        )


if __name__ == "__main__":
    main()

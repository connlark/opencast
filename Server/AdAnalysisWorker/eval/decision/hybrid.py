"""H1 hybrid: a decision model localises, the unchanged v3 generative path decides.

The localiser is (b') chunk probabilities for `h1` and (c) chunk-choice
P(ad) for `h1_c` (summary.json `localiser`); either gives Schmitt runs (every entered run, before the
install filters: the localiser is recall-first). Each run becomes the
neighbourhood `[run.start - 180 s, run.end + 180 s]`; neighbourhoods closer
than 360 s merge (their padded intervals overlap), which keeps the sn1094
final 281 s break contiguous. A neighbourhood becomes a sub-request exactly
the way `v3_windowing::analysis_windows` builds a window: the request cloned,
`segments` sliced by ARRAY INDEX (original ids kept), `segment_count` reset.
Each sub-request goes through the unchanged bridge `prepare` -> provider call
-> `validate` / one `repair` -> `check_repair` ops, then one final
whole-request `validate` (merge, 600 s, budget, 80 %). Quotes, trimming, tier
merging and fail-closed behaviour are production's; nothing is synthesised.

Generative calls archive under `window-<i>/` and `repair-<i>/` (numbered
across neighbourhoods), the localiser's under `decision-w<k>/`.
"""

from __future__ import annotations

import copy

from .common import lane_a, write

PAD_S = 180.0
MERGE_GAP_S = 360.0
POLICY_V3 = "promo_ad_breaks_v3"


def neighbourhoods(runs, chunks, audio_end, pad_s=PAD_S, merge_gap_s=MERGE_GAP_S):
    """[[start_s, end_s, [run keys]]] sorted, merged when runs are < merge_gap_s apart."""
    out = []
    for run in sorted(runs, key=lambda r: r["first"]):
        start, end = chunks[run["first"]].start, chunks[run["last"]].end
        key = f"{run['first']}-{run['last']}"
        if out and start - out[-1][3] < merge_gap_s:
            out[-1][1] = max(out[-1][1], min(audio_end, end + pad_s))
            out[-1][3] = max(out[-1][3], end)
            out[-1][2].append(key)
        else:
            out.append([max(0.0, start - pad_s), min(audio_end, end + pad_s), [key], end])
    return [[round(a, 3), round(b, 3), keys] for a, b, keys, _ in out]


def index_range(segments, start_s, end_s):
    """Array indices of every segment overlapping [start_s, end_s]."""
    inside = [i for i, s in enumerate(segments) if s["end"] > start_s and s["start"] < end_s]
    return (inside[0], inside[-1]) if inside else None


def sub_request(request, lo, hi):
    sub = copy.deepcopy(request)
    sub["segments"] = copy.deepcopy(request["segments"][lo : hi + 1])
    sub["transcript"]["segment_count"] = len(sub["segments"])
    return sub


def _words(text, count, last=False):
    words = str(text).split()
    return " ".join(words[-count:] if last else words[:count])


def stub_output(window_request, truth):
    """Offline stand-in for a generative model: v3-shaped spans for the pods
    visible in the window, receipts copied from the boundary segments (used
    only by the dry run and tests; it exercises the real bridge)."""
    segments = window_request["segments"]
    position = {s["id"]: i for i, s in enumerate(segments)}
    spans = []
    for a, b in truth.get("pods", []):
        visible = [s["id"] for s in segments if a <= s["id"] <= b]
        if not visible:
            continue
        first, last = segments[position[visible[0]]], segments[position[visible[-1]]]
        spans.append(
            {
                "start_segment_id": first["id"],
                "end_segment_id": last["id"],
                "start_quote": _words(first["text"], 8),
                "end_quote": _words(last["text"], 8, last=True),
                "evidence_quote": _words(first["text"], 4),
                "kind": "inserted_ad",
                "label": "stub pod",
                "confidence": 0.95,
            }
        )
    return {"spans": spans}


def runner(*, model, key_file, ledger, thinking, repair, stub, max_output=16384, truth_of=None):
    """Return `fn(request, chunks, doc, localiser, run_dir, context, calls)
    -> (derivation, extra)` for run_decision's H1 path."""
    run = lane_a("run")
    key = None if stub else key_file.read_text().strip()

    def dispatch(payload, directory, ctx, window_request, truth):
        if stub:
            directory.mkdir(parents=True, exist_ok=True)
            write(directory / "request.json", payload)
            output = stub_output(window_request, truth)
            write(directory / "response.json", {"stub": True, "output": output})
            return output, {"stage": "generative", "elapsed_s": 0.0, "usage": {"input": 0, "cached": 0, "write": 0, "output": 0, "reasoning": 0}, "cost_usd": 0.0}
        wire = run.provider_payload(model, payload, thinking, max_output)
        output, details = run.call(model, wire, key, ledger, directory, ctx, max_output)
        entry = next((e for e in ledger.snapshot()["entries"] if e["id"] == details.get("reservation")), {})
        details = {**details, "model": model, "stage": "generative", "cost_usd": entry.get("actual_usd", 0.0)}
        if details.get("transport_error"):
            raise ValueError("ad_analysis_incomplete: " + str(details["transport_error"]))
        return output, details

    def hybrid(request, chunks, doc, localiser, run_dir, context, calls):
        truth = (truth_of or {}).get(context["fixture"], {})
        segments = request["segments"]
        audio_end = max(segments[-1]["end"], float(request["transcript"].get("audio_duration") or 0))
        hoods = neighbourhoods(localiser["runs"], chunks, audio_end)
        thinking_arg = None if thinking in (None, "default") else thinking
        outputs, records, index = [], [], 0
        for start_s, end_s, keys in hoods:
            found = index_range(segments, start_s, end_s)
            if not found:
                continue
            lo, hi = found
            sub = sub_request(request, lo, hi)
            records.append({"seconds": [start_s, end_s], "indices": [lo, hi], "runs": keys, "segments": hi - lo + 1})
            for window in run.bridge({"op": "prepare", "policy": POLICY_V3, "request": sub, "thinking": thinking_arg})["windows"]:
                ctx = {**context, "stage": "generative", "window": index}
                output, details = dispatch(window["payload"], run_dir / f"window-{index}", ctx, window["request"], truth)
                calls.append(details)
                if repair:
                    checked = run.bridge({"op": "validate", "policy": POLICY_V3, "request": window["request"], "output": output, "window": True})
                    if not checked["complete"]:
                        write(run_dir / f"window-{index}" / "initial-validation.json", checked)
                        before = output
                        corrective = run.bridge({
                            "op": "repair", "policy": POLICY_V3, "request": window["request"], "payload": window["payload"],
                            "output": output or {"unusable_previous_output": True}, "issues": checked["warnings"],
                        })
                        output, details = dispatch(corrective, run_dir / f"repair-{index}", {**ctx, "repair": True}, window["request"], truth)
                        calls.append(details)
                        repaired = run.bridge({"op": "validate", "policy": POLICY_V3, "request": window["request"], "output": output, "window": True})
                        if before is not None and "v3_malformed_model_json" not in checked["warnings"] and repaired["complete"]:
                            repaired = run.bridge({"op": "check_repair", "policy": POLICY_V3, "request": window["request"], "before": before, "output": output})
                        write(run_dir / f"repair-{index}" / "validation.json", repaired)
                        if not repaired["complete"]:
                            raise ValueError("ad_analysis_incomplete: " + ",".join(repaired["warnings"]))
                if output is None:
                    raise ValueError("Incomplete model output")
                outputs.extend(output["spans"])
                index += 1
        validated = run.bridge({"op": "validate", "policy": POLICY_V3, "request": request, "output": {"spans": outputs}})
        derivation = {
            "design": "h1",
            "localiser": localiser,
            "neighbourhoods": records,
            "raw_spans": outputs,
            "guards": {"source": "bridge validate (production v3)", "warnings": validated["warnings"]},
            "validation": validated,
        }
        extra = {"hybrid": {"generative_model": "stub" if stub else model, "thinking": thinking, "repair": repair,
                            "neighbourhoods": records, "neighbourhood_count": len(records),
                            "neighbourhood_seconds": round(sum(b - a for (a, b) in (r["seconds"] for r in records)), 3),
                            "audio_seconds": round(audio_end, 3),
                            "final_validate_complete": bool(validated["complete"]),
                            "pad_s": PAD_S, "merge_gap_s": MERGE_GAP_S}}
        return derivation, extra

    return hybrid

#!/usr/bin/env python3
"""Budgeted v2/v3 bake-off using the Worker's real Rust prompt and validation.

No dependency on private notes, hosted services, or non-stdlib Python packages.
Inputs are a local manifest of request paths and pre-annotated segment ranges.
Outputs may contain copyrighted transcripts: use a private, ignored directory.

Providers: Gemini and OpenAI over HTTPS (metered by the shared ledger), and
`pcc`, Apple's Private Cloud Compute model, reached through a signed, entitled
helper executable (`--pcc-helper`) that speaks the JSON contract in `pcc_input`.
PCC has no monetary price and an unpublished per-user quota, so its calls are
journaled to `pcc-usage.json` in the output root instead of the ledger.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

from budget import PRICES, Ledger

WORKER = Path(__file__).resolve().parents[1]
BRIDGE_HASH = None
PCC_MODEL = "pcc"
# The harness thinking vocabulary mapped onto ContextOptions.ReasoningLevel.
PCC_REASONING = {
    "default": None,
    "none": None,
    "low": "light",
    "medium": "moderate",
    "high": "deep",
}
# Background-class PCC requests were shed intermittently in the probes and the
# limit cleared within minutes; retry a rate limit a few times per window.
PCC_RETRY_DELAYS_S = (30, 90, 180)
PCC_HELPER_TIMEOUT_S = 900
# Not model answers: the serving path would fall back to another provider, not
# spend a repair turn on them.
PCC_TRANSPORT_ERRORS = frozenset(
    {
        "rateLimited",
        "timeout",
        "pcc.networkFailure",
        "pcc.serviceUnavailable",
        "contextSizeExceeded",
        "contextBudgetExhausted",
    }
)


class PCCQuotaExhausted(RuntimeError):
    pass


def verify_bridge():
    global BRIDGE_HASH
    executable = WORKER / "target/debug/examples/eval_bridge"
    sources = [
        *list((WORKER / "src").glob("*")),
        WORKER / "examples/eval_bridge.rs",
        WORKER / "Cargo.toml",
        WORKER / "Cargo.lock",
    ]
    if not executable.exists() or any(
        p.is_file() and p.stat().st_mtime > executable.stat().st_mtime for p in sources
    ):
        raise RuntimeError(
            "Build eval_bridge successfully before any paid inference; binary is missing or stale"
        )
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    if BRIDGE_HASH is not None and digest != BRIDGE_HASH:
        raise RuntimeError(
            "Eval binary changed during the run; stop rather than mix contracts"
        )
    BRIDGE_HASH = digest
    return digest


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def bridge(command):
    verify_bridge()
    executable = WORKER / "target/debug/examples/eval_bridge"
    run = subprocess.run(
        [str(executable)],
        input=json.dumps(command),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(run.stdout)


def http(url, payload, headers):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"content-type": "application/json", **headers},
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.load(response)


def safe_error(error, key):
    detail = (
        error.read().decode(errors="replace")
        if isinstance(error, urllib.error.HTTPError)
        else str(error)
    )
    if key:
        detail = detail.replace(key, "[REDACTED]")
    detail = re.sub(r"(?:sk-|AIza)[A-Za-z0-9_-]{16,}", "[REDACTED]", detail)
    return detail[:1600]


def pcc_run(report):
    """The helper's final attempt, or None when it never reached the model."""
    runs = (report or {}).get("runs") or []
    return runs[-1] if runs else None


def usage_of(model, response):
    if model == PCC_MODEL:
        run = pcc_run(response)
        u = run.get("usage") if run and run.get("ok") else None
        if not u:
            return None
        return {
            "input": u["input_total"],
            "cached": u["input_cached"],
            "write": 0,
            "output": u["output_total"],
            "reasoning": u["output_reasoning"],
        }
    if model.startswith("gemini"):
        u = response.get("usageMetadata", {})
        # Missing billed output metadata is ambiguous, even for safety refusals.
        if "promptTokenCount" not in u or "candidatesTokenCount" not in u:
            return None
        return {
            "input": u["promptTokenCount"],
            "cached": u.get("cachedContentTokenCount", 0),
            "write": 0,
            "output": u["candidatesTokenCount"] + u.get("thoughtsTokenCount", 0),
            "reasoning": u.get("thoughtsTokenCount", 0),
        }
    u = response.get("usage")
    if not u:
        return None
    d = u.get("input_tokens_details") or {}
    return {
        "input": u["input_tokens"],
        "cached": d.get("cached_tokens", 0),
        "write": d.get("cache_write_tokens", 0),
        "output": u["output_tokens"],
        "reasoning": (u.get("output_tokens_details") or {}).get("reasoning_tokens", 0),
    }


def answer_of(model, response):
    if model == PCC_MODEL:
        run = pcc_run(response)
        if not run or not run.get("ok"):
            raise ValueError("Incomplete or refused PCC output")
        texts = [str(run.get("raw_json", ""))]
    elif model.startswith("gemini"):
        candidates = response.get("candidates", [])
        if len(candidates) != 1 or candidates[0].get("finishReason") != "STOP":
            raise ValueError("Incomplete or refused Gemini output")
        texts = [
            p["text"]
            for p in candidates[0].get("content", {}).get("parts", [])
            if not p.get("thought") and "text" in p
        ]
    else:
        if (
            response.get("status") != "completed"
            or response.get("error")
            or response.get("incomplete_details")
        ):
            raise ValueError("Incomplete or refused OpenAI output")
        texts = [
            p["text"]
            for m in response.get("output", [])
            if m.get("type") == "message" and m.get("status") == "completed"
            for p in m.get("content", [])
            if p.get("type") == "output_text"
        ]
    texts = [text for text in texts if text.strip()]
    if len(texts) != 1 or len(texts[0].encode()) > 100_000:
        raise ValueError("Expected exactly one bounded answer")
    return json.loads(texts[0])


def pcc_ordered(schema):
    """Ordered-properties form for the helper's DynamicGenerationSchema builder."""
    result = dict(schema)
    if "properties" in schema:
        result["properties"] = [[k, pcc_ordered(v)] for k, v in schema["properties"].items()]
    if "items" in schema:
        result["items"] = pcc_ordered(schema["items"])
    return result


def pcc_input(payload, max_output, label):
    """Helper input: the same instructions, turns, and schema the Worker sends Gemini."""
    return {
        "label": label,
        "instructions": payload["systemInstruction"]["parts"][0]["text"],
        "messages": [
            {"role": m["role"], "text": m["parts"][0]["text"]}
            for m in payload["contents"]
        ],
        "schema": pcc_ordered(payload["generationConfig"]["responseJsonSchema"]),
        "max_output_tokens": max_output,
    }


def pcc_journal(path, entry):
    doc = json.loads(path.read_text()) if path.exists() else {"calls": []}
    doc["calls"].append(entry)
    calls = doc["calls"]
    doc["totals"] = {
        "calls": len(calls),
        "ok": sum(1 for c in calls if c["ok"]),
        "rate_limited": sum(1 for c in calls if c.get("error_kind") == "rateLimited"),
        "input_tokens": sum((c.get("usage") or {}).get("input", 0) for c in calls),
        "output_tokens": sum((c.get("usage") or {}).get("output", 0) for c in calls),
        "helper_wall_s": round(sum(c["wall_s"] for c in calls), 1),
    }
    write(path, doc)
    return doc["totals"]


def call_pcc(helper, payload, out, context, max_output, reasoning, journal):
    write(out / "request.json", payload)
    label = "-".join(str(context[k]) for k in ("tag", "fixture", "repeat", "window"))
    if context.get("repair"):
        label += "-repair"
    request_path = out / "pcc-request.json"
    write(request_path, pcc_input(payload, max_output, label))
    kind = None
    for attempt, delay in enumerate((0, *PCC_RETRY_DELAYS_S)):
        if delay:
            time.sleep(delay)
        report_path = out / f"response-attempt-{attempt}.json"
        command = [
            str(helper),
            "--in",
            str(request_path),
            "--out",
            str(report_path),
            "--fit-context",
            "1",
        ]
        if reasoning:
            command += ["--reasoning", reasoning]
        start = time.monotonic()
        process = subprocess.run(
            command, capture_output=True, text=True, timeout=PCC_HELPER_TIMEOUT_S
        )
        wall = time.monotonic() - start
        report = json.loads(report_path.read_text()) if report_path.exists() else None
        run = pcc_run(report)
        if run is None:
            raise RuntimeError(
                f"PCC helper produced no run (exit {process.returncode}): "
                + process.stderr[-800:]
            )
        kind = None if run.get("ok") else (run.get("error") or {}).get("kind", "unknown")
        pcc_journal(
            journal,
            {
                "context": context,
                "attempt": attempt,
                "ok": bool(run.get("ok")),
                "error_kind": kind,
                "elapsed_s": round(run.get("elapsed_s", 0), 3),
                "wall_s": round(wall, 3),
                "usage": usage_of(PCC_MODEL, report),
                "quota_after": run.get("quota_after"),
                "max_output_effective": report.get("max_output_effective"),
                "at": run.get("finished_at"),
            },
        )
        if kind != "rateLimited":
            break
    os.replace(report_path, out / "response.json")
    if kind == "pcc.quotaLimitReached" or (run.get("quota_after") or {}).get(
        "isLimitReached"
    ):
        raise PCCQuotaExhausted(f"PCC quota reached ({kind}); stopping")
    details = {
        "elapsed_s": round(run.get("elapsed_s", 0), 3),
        "usage": usage_of(PCC_MODEL, report),
        "pcc": {
            "reasoning": reasoning,
            "attempts": attempt + 1,
            "error_kind": kind,
            "quota_after": run.get("quota_after"),
            "max_output_effective": report.get("max_output_effective"),
            "token_proxy_total": report.get("token_proxy_total"),
        },
    }
    if kind in PCC_TRANSPORT_ERRORS:
        details["transport_error"] = kind
        return None, details
    try:
        return answer_of(PCC_MODEL, report), details
    except (ValueError, KeyError, TypeError) as error:
        details["answer_error"] = f"pcc_{kind}" if kind else str(error)
        return None, details


def provider_payload(model, payload, thinking, max_output):
    if model == PCC_MODEL:
        # Same Gemini-shaped archive as the other providers; the helper input is
        # derived from it per call and reasoning travels as a helper flag.
        payload["generationConfig"]["maxOutputTokens"] = max_output
        return payload
    if model.startswith("gemini"):
        payload["generationConfig"]["maxOutputTokens"] = max_output
        if model == "gemini-3.8-flash":
            payload["generationConfig"].pop("temperature", None)
            payload["generationConfig"].pop("topP", None)
        if thinking != "default":
            payload["generationConfig"]["thinkingConfig"] = {"thinkingLevel": thinking}
        return payload
    schema = payload["generationConfig"]["responseJsonSchema"]
    schema["additionalProperties"] = False
    schema["properties"]["spans"]["items"]["additionalProperties"] = False
    result = {
        "model": model,
        "input": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": payload["contents"][0]["parts"][0]["text"],
                    }
                ],
            }
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "podcast_ad_breaks",
                "strict": True,
                "schema": schema,
            }
        },
        "reasoning": {"effort": thinking if thinking != "default" else "low"},
        "max_output_tokens": max_output,
        "tools": [],
        "store": False,
        "background": False,
        "service_tier": "default",
        "prompt_cache_options": {"mode": "explicit"},
    }
    if "systemInstruction" in payload:
        result["instructions"] = payload["systemInstruction"]["parts"][0]["text"]
    for message in payload["contents"][1:]:
        result["input"].append(
            {
                "role": "assistant" if message["role"] == "model" else "user",
                "content": message["parts"][0]["text"],
            }
        )
    return result


def call(model, payload, key, ledger, out, context, max_output):
    gemini = model.startswith("gemini")
    headers = {"x-goog-api-key": key} if gemini else {"authorization": f"Bearer {key}"}
    base = (
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}"
        if gemini
        else "https://api.openai.com/v1/responses"
    )
    count_payload = (
        {"generateContentRequest": {"model": f"models/{model}", **payload}}
        if gemini
        else {
            k: v
            for k, v in payload.items()
            if k in ("model", "input", "instructions", "text", "tools")
        }
    )
    count = http(
        base + ":countTokens" if gemini else base + "/input_tokens",
        count_payload,
        headers,
    )
    tokens = count.get("totalTokens" if gemini else "input_tokens")
    ident = ledger.reserve(model, tokens, max_output, context)
    write(out / "request.json", payload)
    start = time.monotonic()
    try:
        response = http(base + ":generateContent" if gemini else base, payload, headers)
    except Exception as error:  # noqa: BLE001 - retain spend on any uncertain dispatch
        detail = safe_error(error, key)
        definite = isinstance(error, urllib.error.HTTPError) and error.code in (
            400,
            401,
            403,
            404,
            413,
            422,
            429,
        )
        ledger.finish(ident, "released" if definite else "ambiguous", error=detail)
        write(out / "error.json", {"error": detail, "reservation": ident})
        raise RuntimeError(detail) from None
    elapsed = time.monotonic() - start
    write(out / "response.json", response)
    usage = usage_of(model, response)
    try:
        ledger.finish(ident, "settled" if usage else "ambiguous", usage=usage)
    except (ValueError, TypeError):
        ledger.finish(ident, "ambiguous", error="Invalid usage metadata")
        raise
    if not usage:
        raise RuntimeError("Missing usage; reservation retained, stopping")
    if any(e.get("reservation_exceeded") for e in ledger.snapshot()["entries"]):
        raise RuntimeError("Provider exceeded reservation; stopping")
    details = {"elapsed_s": round(elapsed, 3), "usage": usage, "reservation": ident}
    try:
        return answer_of(model, response), details
    except (ValueError, KeyError, TypeError) as error:
        details["answer_error"] = str(error)
        return None, details


def union(ranges):
    result = []
    for start, end in sorted(ranges):
        if result and start <= result[-1][1] + 1e-6:
            result[-1][1] = max(end, result[-1][1])
        else:
            result.append([start, end])
    return result


def measure(request, spans, truth):
    by_id = {s["id"]: s for s in request["segments"]}

    def intervals(key):
        return [(by_id[a]["start"], by_id[b]["end"]) for a, b in truth.get(key, [])]

    def intersection(a, b):
        return max(0, min(a[1], b[1]) - max(a[0], b[0]))

    zones = union(
        (s["start_time"], s["end_time"]) for s in spans if s["confidence"] >= 0.8
    )
    # Exactly the client's <=1 s merge (not a new gap-bridging algorithm).
    merged = []
    for a, b in zones:
        if merged and a - merged[-1][1] <= 1:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    allowed = union(intervals("pods") + intervals("optional"))
    pods = []
    for ids, pod in zip(truth.get("pods", []), intervals("pods")):
        touching = [z for z in merged if intersection(z, pod) > 0]
        covered = sum(intersection(z, pod) for z in touching)
        pods.append(
            {
                "ids": ids,
                "coverage": covered / (pod[1] - pod[0]),
                "missed_s": round(pod[1] - pod[0] - covered, 3),
                "zones": len(touching),
            }
        )
    fp = sum(b - a - sum(intersection((a, b), r) for r in allowed) for a, b in merged)
    negatives = sum(
        intersection(z, n) for z in merged for n in union(intervals("negatives"))
    )
    return {
        "pods": pods,
        "missed_ad_s": round(sum(p["missed_s"] for p in pods), 3),
        "false_skip_s": round(max(0, fp), 3),
        "negative_overlap_s": round(negatives, 3),
        "zones": merged,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, help="Provider API key (paid providers)")
    parser.add_argument("--model", choices=(*PRICES, PCC_MODEL), required=True)
    parser.add_argument(
        "--pcc-helper",
        type=Path,
        help="Signed, PCC-entitled helper executable (required for --model pcc)",
    )
    parser.add_argument(
        "--policy", choices=("promo_ad_breaks_v2", "promo_ad_breaks_v3"), required=True
    )
    parser.add_argument(
        "--thinking",
        choices=("default", "none", "low", "medium", "high"),
        default="default",
    )
    parser.add_argument("--fixtures", nargs="*")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--tag", required=True)
    parser.add_argument(
        "--repair",
        action="store_true",
        help="One paid semantic repair per invalid v3 window",
    )
    parser.add_argument("--max-spend", type=float, default=15)
    parser.add_argument("--max-output", type=int, default=16384)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.tag):
        parser.error("Unsafe tag")
    if not 1 <= args.repeats <= 10 or not 256 <= args.max_output <= 16384:
        parser.error("Invalid run bounds")
    os.umask(0o077)
    pcc = args.model == PCC_MODEL
    if pcc:
        if not args.pcc_helper or not os.access(args.pcc_helper, os.X_OK):
            parser.error("--pcc-helper must point at an executable PCC helper")
        key = ""
        helper_hash = hashlib.sha256(args.pcc_helper.read_bytes()).hexdigest()
    else:
        if not args.key_file:
            parser.error("--key-file is required for paid providers")
        key = args.key_file.read_text().strip()
        if not key:
            parser.error("Empty key file")
        helper_hash = None
    binary_hash = verify_bridge()
    ledger = None if pcc else Ledger(args.out / "budget-ledger.json", args.max_spend)
    journal = args.out / "pcc-usage.json"
    manifest = json.loads(args.manifest.read_text())
    selected = [
        f
        for f in manifest["fixtures"]
        if not args.fixtures or f["name"] in args.fixtures
    ]
    if not selected or (
        args.fixtures and set(args.fixtures) - {f["name"] for f in selected}
    ):
        parser.error("Unknown fixture")
    for fixture in selected:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", fixture["name"]):
            parser.error("Unsafe fixture name")
        request_path = args.manifest.parent / fixture["request"]
        request = json.loads(request_path.read_text())
        for repeat in range(args.repeats):
            run = args.out / args.tag / f"{fixture['name']}-{repeat + 1}"
            if run.exists():
                raise RuntimeError(f"Run exists, refusing overwrite: {run}")
            run.mkdir(parents=True)
            write(
                run / "fixture.json",
                {
                    "fixture": fixture,
                    "request_sha256": hashlib.sha256(
                        request_path.read_bytes()
                    ).hexdigest(),
                    "eval_binary_sha256": binary_hash,
                    **({"pcc_helper_sha256": helper_hash} if pcc else {}),
                },
            )
            started = time.monotonic()
            outputs = []
            calls = []
            error = None

            def dispatch(payload, directory, context):
                if pcc:
                    output, details = call_pcc(
                        args.pcc_helper,
                        payload,
                        directory,
                        context,
                        args.max_output,
                        PCC_REASONING[args.thinking],
                        journal,
                    )
                else:
                    output, details = call(
                        args.model, payload, key, ledger, directory, context, args.max_output
                    )
                calls.append(details)
                if details.get("transport_error"):
                    raise ValueError(
                        "ad_analysis_incomplete: pcc_" + details["transport_error"]
                    )
                return output

            try:
                windows = bridge(
                    {
                        "op": "prepare",
                        "policy": args.policy,
                        "request": request,
                        # PCC reasoning is a helper flag, never a Gemini config.
                        "thinking": None
                        if args.thinking == "default" or pcc
                        else args.thinking,
                    }
                )["windows"]
                for index, window in enumerate(windows):
                    payload = provider_payload(
                        args.model, window["payload"], args.thinking, args.max_output
                    )
                    output = dispatch(
                        payload,
                        run / f"window-{index}",
                        {
                            "tag": args.tag,
                            "fixture": fixture["name"],
                            "repeat": repeat + 1,
                            "window": index,
                        },
                    )
                    if args.repair and args.policy.endswith("v3"):
                        checked = bridge(
                            {
                                "op": "validate",
                                "policy": args.policy,
                                "request": window["request"],
                                "output": output,
                                "window": True,
                            }
                        )
                        if not checked["complete"]:
                            write(
                                run / f"window-{index}" / "initial-validation.json",
                                checked,
                            )
                            before = output
                            corrective = bridge(
                                {
                                    "op": "repair",
                                    "policy": args.policy,
                                    "request": window["request"],
                                    "payload": window["payload"],
                                    "output": output
                                    or {"unusable_previous_output": True},
                                    "issues": checked["warnings"],
                                }
                            )
                            output = dispatch(
                                provider_payload(
                                    args.model,
                                    corrective,
                                    args.thinking,
                                    args.max_output,
                                ),
                                run / f"repair-{index}",
                                {
                                    "tag": args.tag,
                                    "fixture": fixture["name"],
                                    "repeat": repeat + 1,
                                    "window": index,
                                    "repair": True,
                                },
                            )
                            repaired = bridge(
                                {
                                    "op": "validate",
                                    "policy": args.policy,
                                    "request": window["request"],
                                    "output": output,
                                    "window": True,
                                }
                            )
                            if (
                                before is not None
                                and "v3_malformed_model_json" not in checked["warnings"]
                                and repaired["complete"]
                            ):
                                repaired = bridge(
                                    {
                                        "op": "check_repair",
                                        "policy": args.policy,
                                        "request": window["request"],
                                        "before": before,
                                        "output": output,
                                    }
                                )
                            write(run / f"repair-{index}" / "validation.json", repaired)
                            if not repaired["complete"]:
                                raise ValueError(
                                    "ad_analysis_incomplete: "
                                    + ",".join(repaired["warnings"])
                                )
                    if output is None:
                        raise ValueError("Incomplete model output")
                    outputs.extend(output["spans"])
                validated = bridge(
                    {
                        "op": "validate",
                        "policy": args.policy,
                        "request": request,
                        "output": {"spans": outputs},
                    }
                )
            except Exception as exc:  # noqa: BLE001 - archive failures before stopping
                error = safe_error(exc, key)
                validated = {"complete": False, "spans": [], "warnings": [error]}
            # V2 installs surviving spans even when warnings indicate lost coverage.
            # V3 is fail-closed until its bounded recovery can resolve all issues.
            installed = (
                validated["spans"]
                if args.policy.endswith("v2") or validated["complete"]
                else []
            )
            summary = {
                "model": args.model,
                "policy": args.policy,
                "thinking": args.thinking,
                **({"pcc_reasoning": PCC_REASONING[args.thinking]} if pcc else {}),
                "raw_spans": outputs,
                "validation": validated,
                "metrics": measure(request, installed, fixture["ground_truth"]),
                "calls": calls,
                "elapsed_s": round(time.monotonic() - started, 3),
                "error": error,
            }
            write(run / "summary.json", summary)
            print(
                json.dumps(
                    {
                        "run": str(run),
                        "metrics": summary["metrics"],
                        "warnings": validated["warnings"],
                        "error": error,
                        "budget": ledger.snapshot()["totals"] if ledger else None,
                        "pcc": json.loads(journal.read_text())["totals"]
                        if pcc and journal.exists()
                        else None,
                    }
                ),
                flush=True,
            )
            if error and not error.startswith("ad_analysis_incomplete:"):
                raise RuntimeError(error)


if __name__ == "__main__":
    main()

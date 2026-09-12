#!/usr/bin/env python3
"""Budgeted v2/v3 bake-off using the Worker's real Rust prompt and validation.

No dependency on private notes, hosted services, or non-stdlib Python packages.
Inputs are a local manifest of request paths and pre-annotated segment ranges.
Outputs may contain copyrighted transcripts: use a private, ignored directory.
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
    detail = detail.replace(key, "[REDACTED]")
    detail = re.sub(r"(?:sk-|AIza)[A-Za-z0-9_-]{16,}", "[REDACTED]", detail)
    return detail[:1600]


def usage_of(model, response):
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
    if model.startswith("gemini"):
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


def provider_payload(model, payload, thinking, max_output):
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
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--model", choices=PRICES, required=True)
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
    key = args.key_file.read_text().strip()
    if not key:
        parser.error("Empty key file")
    binary_hash = verify_bridge()
    ledger = Ledger(args.out / "budget-ledger.json", args.max_spend)
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
                },
            )
            started = time.monotonic()
            outputs = []
            calls = []
            error = None
            try:
                windows = bridge(
                    {
                        "op": "prepare",
                        "policy": args.policy,
                        "request": request,
                        "thinking": None
                        if args.thinking == "default"
                        else args.thinking,
                    }
                )["windows"]
                for index, window in enumerate(windows):
                    payload = provider_payload(
                        args.model, window["payload"], args.thinking, args.max_output
                    )
                    output, details = call(
                        args.model,
                        payload,
                        key,
                        ledger,
                        run / f"window-{index}",
                        {
                            "tag": args.tag,
                            "fixture": fixture["name"],
                            "repeat": repeat + 1,
                            "window": index,
                        },
                        args.max_output,
                    )
                    calls.append(details)
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
                            output, repair_details = call(
                                args.model,
                                provider_payload(
                                    args.model,
                                    corrective,
                                    args.thinking,
                                    args.max_output,
                                ),
                                key,
                                ledger,
                                run / f"repair-{index}",
                                {
                                    "tag": args.tag,
                                    "fixture": fixture["name"],
                                    "repeat": repeat + 1,
                                    "window": index,
                                    "repair": True,
                                },
                                args.max_output,
                            )
                            calls.append(repair_details)
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
                        "budget": ledger.snapshot()["totals"],
                    }
                ),
                flush=True,
            )
            if error and not error.startswith("ad_analysis_incomplete:"):
                raise RuntimeError(error)


if __name__ == "__main__":
    main()

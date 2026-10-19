#!/usr/bin/env python3
"""Budgeted v2/v3 bake-off using the Worker's real Rust prompt and validation.

No dependency on private notes, hosted services, or non-stdlib Python packages.
Inputs are a local manifest of request paths and pre-annotated segment ranges.
Outputs may contain copyrighted transcripts: use a private, ignored directory.

Providers: every `budget.PRICES` key through one `providers.Adapter` (Gemini,
OpenAI Responses, Anthropic Messages, Cloudflare Workers AI and AI Gateway,
and the decision models in `providers.systemone`), all metered by one shared
ledger (`--ledger`), and `pcc`, Apple's Private Cloud Compute model, reached
through a signed, entitled helper executable (`--pcc-helper`) that speaks the
JSON contract in `pcc_input`. PCC has no monetary price and an unpublished
per-user quota, so its calls are journaled to `pcc-usage.json` in the output
root instead of the ledger.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import time
import urllib.error
from pathlib import Path

from budget import PRICES, Ledger, cost_usd
from providers import (
    MODELS,
    ContextExceeded,
    adapter_for,
    adapter_recognizing,
    sanitize,
)
from providers.base import http, safe_error  # noqa: F401 - re-exported for callers

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
    return adapter_of(model, response).usage(response)


def adapter_of(model, response):
    """The model's adapter; for an unknown (archived) key, sniff the doc."""
    if model in MODELS:
        return MODELS[model]
    found = adapter_recognizing(response)
    if found:
        return found
    # Historical fallback: Gemini by name, everything else OpenAI Responses.
    return MODELS["gemini-3.8-flash" if model.startswith("gemini") else "gpt-5.6-luna"]


def archived_window_text(payload):
    """Window input text from an archived request.json of any shape: the
    Gemini-shaped canonical, a historical OpenAI Responses wire, or a
    systemone decision request (`state`)."""
    if "contents" in payload:
        return payload["contents"][0]["parts"][0]["text"]
    if isinstance(payload.get("input"), list):
        return payload["input"][0]["content"][0]["text"]
    if isinstance(payload.get("state"), str):
        return payload["state"]
    raise ValueError("Unrecognized archived request shape")


def answer_of(model, response):
    if model == PCC_MODEL:
        run = pcc_run(response)
        if not run or not run.get("ok"):
            raise ValueError("Incomplete or refused PCC output")
        texts = [str(run.get("raw_json", ""))]
    else:
        return adapter_of(model, response).answer(response)
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
    return adapter_for(model).build(payload, thinking, max_output)


DEFINITE_HTTP_ERRORS = (400, 401, 403, 404, 413, 422, 429)


def call(model, payload, key, ledger, out, context, max_output, thinking=None):
    """One metered model call for one window.

    `payload` is the Gemini-shaped canonical window payload when `thinking`
    is given (the adapter builds the wire; `request.json` keeps the canonical
    and `wire-request.json` the body actually sent when it differs), or an
    already-built wire from `provider_payload` when `thinking` is None (the
    historical contract of boundary_probe/recall_audit: archived as-is).
    """
    adapter = adapter_for(model)
    creds = adapter.credentials(key)
    secrets = adapter.secrets(creds)
    if thinking is None:
        wire, request_doc, wire_doc = payload, payload, None
    else:
        canonical = copy.deepcopy(payload)
        canonical["generationConfig"]["maxOutputTokens"] = max_output
        wire = adapter.build(payload, thinking, max_output)
        request_doc, wire_doc = adapter.archived_request(canonical, wire)
    tokens = adapter.count(wire, creds)
    estimated = tokens is None
    if estimated:
        tokens = adapter.estimate(wire)
    details = {
        **adapter.describe(),
        "input_count": tokens,
        **({"input_estimated": True} if estimated else {}),
    }
    try:
        adapter.check_context(tokens)
    except ContextExceeded as exceeded:
        write(out / "request.json", request_doc)
        if wire_doc is not None:
            write(out / "wire-request.json", wire_doc)
        write(out / "error.json", {"error": str(exceeded)})
        details.update(
            transport_error="context_exceeded",
            input_tokens=exceeded.tokens,
            context_limit=exceeded.limit,
        )
        return None, details
    ident = ledger.reserve(
        model,
        tokens + adapter.schema_allowance(wire),
        adapter.reserved_output(wire, max_output) or 1,
        context,
    )
    write(out / "request.json", request_doc)
    if wire_doc is not None:
        write(out / "wire-request.json", wire_doc)
    if adapter.rate_limiter:
        adapter.rate_limiter.wait()
    start = time.monotonic()
    try:
        response = adapter.call(wire, creds)
    except Exception as error:  # noqa: BLE001 - retain spend on any uncertain dispatch
        detail = safe_error(error, key, secrets)
        definite = (
            isinstance(error, urllib.error.HTTPError) and error.code in DEFINITE_HTTP_ERRORS
        )
        ledger.finish(ident, "released" if definite else "ambiguous", error=detail)
        write(out / "error.json", {"error": detail, "reservation": ident})
        raise RuntimeError(detail) from None
    elapsed = time.monotonic() - start
    write(out / "response.json", response)
    answer = adapter.parse(response)
    usage = answer.usage
    try:
        ledger.finish(ident, "settled" if usage else "ambiguous", usage=usage)
    except (ValueError, TypeError):
        ledger.finish(ident, "ambiguous", error="Invalid usage metadata")
        raise
    if not usage:
        raise RuntimeError("Missing usage; reservation retained, stopping")
    if any(e.get("reservation_exceeded") for e in ledger.snapshot()["entries"]):
        raise RuntimeError("Provider exceeded reservation; stopping")
    details = {
        "elapsed_s": round(elapsed, 3),
        "usage": usage,
        "reservation": ident,
        **details,
        "latency_ms": round(elapsed * 1000),
        "finish_reason": answer.finish_reason,
        **({"answer_channel": answer.channel} if answer.channel else {}),
    }
    if answer.error:
        details["answer_error"] = answer.error
        return None, details
    try:
        return json.loads(answer.text_json), details
    except (ValueError, TypeError) as error:
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


# Original synthetic text (no real podcast): a host-read sponsor block, then
# editorial. Five segments, about 200 tokens of transcript.
SMOKE_REQUEST = {
    "schema_version": 1,
    "request_id": "lane-a-smoke",
    "episode_id": "smoke-episode-1",
    "podcast_id": "smoke-podcast",
    "episode_title": "Keepers of the Northern Light",
    "podcast_title": "Tide Tables",
    "transcript": {
        "language_code": "en",
        "audio_duration": 150,
        "fingerprint": "lane-a-smoke-v1",
        "updated_at": "2026-10-18T00:00:00Z",
        "state": "completed",
        "segment_count": 5,
    },
    "segments": [
        {"id": 1, "start": 0, "end": 12, "text": "Before we get into the tide charts, a quick word from this week's sponsor."},
        {"id": 2, "start": 12, "end": 38, "text": "Harborline Coffee roasts small batches every Tuesday and ships them the same afternoon, so the beans reach your door within days of roasting."},
        {"id": 3, "start": 38, "end": 55, "text": "Go to harborline dot example and use the code TIDEPOOL for twenty percent off your first bag. Thanks to Harborline for supporting the show."},
        {"id": 4, "start": 55, "end": 90, "text": "Now, back to the lighthouse keepers of the northern coast. The first keeper we found kept a logbook for thirty-one winters."},
        {"id": 5, "start": 90, "end": 150, "text": "Every entry starts with the wind direction, then the state of the lamp, and only then, if there was room, a line about her own day."},
    ],
}
SMOKE_QUESTIONS = [
    {"id": "sponsor_read", "type": "noul", "instructions": "Does the transcript window contain a paid sponsor read or advertisement?"},
    {"id": "show_promo", "type": "noul", "instructions": "Does the transcript window contain a promotion for a different podcast or show?"},
]
SMOKE_MAX_OUTPUT = 4096


def key_prefix(adapter, creds):
    """sha256(primary credential)[:8], the only way a key is ever named."""
    value = creds.get("api_token") or creds.get("api_key") or ""
    return hashlib.sha256(value.encode()).hexdigest()[:8]


def smoke(args, adapter, key, ledger):
    """One fixed synthetic window through the same metered path; one JSON line."""
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = args.out / "smoke" / sanitize(args.model) / stamp
    if out.exists():
        raise RuntimeError(f"Smoke archive exists, refusing overwrite: {out}")
    creds = adapter.credentials(key)
    thinking = args.thinking
    window = bridge(
        {
            "op": "prepare",
            "policy": "promo_ad_breaks_v3",
            "request": SMOKE_REQUEST,
            "thinking": adapter.bridge_thinking(thinking),
        }
    )["windows"][0]
    context = {"tag": "smoke", "fixture": "lane-a-smoke", "repeat": 1, "window": 0}
    line = {"model": args.model, **adapter.describe()}
    if getattr(adapter, "decision", False):
        from providers import systemone

        result = systemone.ask(
            args.model, window["payload"], SMOKE_QUESTIONS, key, ledger, out, context
        )
        summary = json.loads((out / "summary.json").read_text())
        calls = summary["calls"]
        line.update(
            count_or_estimate=sum(c["input_estimated_bound"] for c in calls),
            input_estimated=True,
            usage=result["usage"],
            latency_ms=result["latency_ms"],
            finish_reason=None,
            answers=result["answers"],
            parsed_ok=all(
                isinstance(result["answers"].get(q["id"]), float) for q in SMOKE_QUESTIONS
            ),
            pages=result["pages"],
            cost_usd=result["cost_usd"],
        )
    else:
        max_output = min(args.max_output, SMOKE_MAX_OUTPUT)
        output, details = call(
            args.model,
            window["payload"],
            key,
            ledger,
            out / "window-0",
            context,
            max_output,
            thinking=thinking,
        )
        checked = bridge(
            {
                "op": "validate",
                "policy": "promo_ad_breaks_v3",
                "request": window["request"],
                "output": output,
                "window": True,
            }
        )
        write(out / "window-0" / "validation.json", checked)
        accounting = run_accounting(adapter, thinking, [details])
        write(
            out / "summary.json",
            {
                "model": args.model,
                "smoke": True,
                "policy": "promo_ad_breaks_v3",
                "thinking": thinking,
                "calls": [details],
                "validation": checked,
                **accounting,
            },
        )
        line.update(
            count_or_estimate=details.get("input_count"),
            input_estimated=bool(details.get("input_estimated")),
            usage=details.get("usage"),
            latency_ms=details.get("latency_ms"),
            finish_reason=details.get("finish_reason"),
            parsed_ok=isinstance(output, dict) and isinstance(output.get("spans"), list),
            v3_complete=checked["complete"],
            spans=len(output["spans"]) if isinstance(output, dict) and isinstance(output.get("spans"), list) else None,
            transport_error=details.get("transport_error"),
            answer_error=details.get("answer_error"),
            cost_usd=accounting["cost_usd"],
        )
    line.update(
        provider_thinking=adapter.provider_thinking(thinking),
        key_sha256_prefix=key_prefix(adapter, creds),
        archive=str(out),
        budget=ledger.snapshot()["totals"],
    )
    print(json.dumps(line), flush=True)


def check_combination(parser, adapter, args):
    """Reject --thinking/--policy/--repair combinations a route cannot honour."""
    if args.thinking not in adapter.supported_thinking:
        parser.error(
            f"{args.model} supports --thinking "
            + "|".join(adapter.supported_thinking)
            + f", not {args.thinking!r}"
        )
    if getattr(adapter, "decision", False):
        if args.repair:
            parser.error(f"{args.model} is a decision model: --repair does not apply")
        if args.policy != "promo_ad_breaks_v3":
            parser.error(f"{args.model} is a decision model: v3 policy only")
        if not getattr(args, "smoke", False):
            parser.error(
                f"{args.model} is a decision model: it returns probabilities, not spans; "
                "use --smoke here or providers.systemone.ask from eval/decision"
            )


def run_accounting(adapter, thinking, calls):
    """summary.json fields for a metered route (additive to the historical keys)."""
    billed = [c for c in calls if c.get("usage")]
    return {
        **adapter.describe(),
        "provider_thinking": adapter.provider_thinking(thinking),
        "schema_enforcement": "strict" if adapter.strict_schema else "validator_only",
        "prices": price_row(adapter.model),
        "input_estimated_calls": sum(1 for c in calls if c.get("input_estimated")),
        "cost_usd": round(sum(cost_usd(adapter.model, c["usage"]) for c in billed), 9),
        **({"usage_notes": adapter.usage_notes} if getattr(adapter, "usage_notes", None) else {}),
    }


def price_row(model):
    from budget import LONG_CONTEXT_TIERS

    row = {"per_million": dict(zip(("input", "cached", "write", "output"), PRICES[model]))}
    if model in LONG_CONTEXT_TIERS:
        threshold, tier = LONG_CONTEXT_TIERS[model]
        row["above_input_tokens"] = threshold
        row["above_per_million"] = dict(zip(("input", "cached", "write", "output"), tier))
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, help="Provider API key (paid providers)")
    parser.add_argument("--model", choices=(*MODELS, PCC_MODEL), required=True)
    parser.add_argument(
        "--pcc-helper",
        type=Path,
        help="Signed, PCC-entitled helper executable (required for --model pcc)",
    )
    parser.add_argument("--policy", choices=("promo_ad_breaks_v2", "promo_ad_breaks_v3"))
    parser.add_argument(
        "--thinking",
        choices=("default", "none", "low", "medium", "high"),
        default="default",
    )
    parser.add_argument("--fixtures", nargs="*")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--tag")
    parser.add_argument(
        "--repair",
        action="store_true",
        help="One paid semantic repair per invalid v3 window",
    )
    parser.add_argument("--max-spend", type=float, default=15)
    parser.add_argument("--max-output", type=int, default=16384)
    parser.add_argument(
        "--ledger",
        type=Path,
        help="Shared spend ledger (default <out>/budget-ledger.json); one per experiment",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="One fixed synthetic window (two questions for decision models); "
        "archived under <out>/smoke/<model>/<utc>/, one JSON line printed",
    )
    args = parser.parse_args()
    if args.smoke:
        if args.model == PCC_MODEL:
            parser.error("--smoke covers metered providers, not pcc")
        if args.manifest or args.tag or args.fixtures or args.repair:
            parser.error("--smoke takes no --manifest, --tag, --fixtures or --repair")
        args.policy = args.policy or "promo_ad_breaks_v3"
        if args.policy != "promo_ad_breaks_v3":
            parser.error("--smoke renders the v3 window only")
    elif not args.manifest or not args.policy or not args.tag:
        parser.error("--manifest, --policy and --tag are required (unless --smoke)")
    if not args.smoke and not re.fullmatch(r"[A-Za-z0-9._-]+", args.tag):
        parser.error("Unsafe tag")
    if not 1 <= args.repeats <= 10 or not 256 <= args.max_output <= 16384:
        parser.error("Invalid run bounds")
    os.umask(0o077)
    pcc = args.model == PCC_MODEL
    adapter = None if pcc else adapter_for(args.model)
    secrets = []
    if pcc:
        if not args.pcc_helper or not os.access(args.pcc_helper, os.X_OK):
            parser.error("--pcc-helper must point at an executable PCC helper")
        key = ""
        helper_hash = hashlib.sha256(args.pcc_helper.read_bytes()).hexdigest()
    else:
        if (
            args.smoke
            and args.thinking == "default"
            and "default" not in adapter.supported_thinking
        ):
            # A smoke without --thinking uses the route's lowest setting.
            args.thinking = adapter.supported_thinking[0]
        check_combination(parser, adapter, args)
        if not args.key_file:
            parser.error("--key-file is required for paid providers")
        key = args.key_file.read_text().strip()
        if not key:
            parser.error("Empty key file")
        try:
            secrets = adapter.secrets(adapter.credentials(key))
        except (ValueError, KeyError, TypeError):
            parser.error(f"--key-file does not hold {adapter.provider} credentials")
        helper_hash = None
    binary_hash = verify_bridge()
    ledger = (
        None
        if pcc
        else Ledger(args.ledger or args.out / "budget-ledger.json", args.max_spend)
    )
    if args.smoke:
        smoke(args, adapter, key, ledger)
        return
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
                        args.model,
                        payload,
                        key,
                        ledger,
                        directory,
                        context,
                        args.max_output,
                        thinking=args.thinking,
                    )
                calls.append(details)
                if details.get("transport_error"):
                    raise ValueError(
                        "ad_analysis_incomplete: "
                        + ("pcc_" if pcc else "")
                        + details["transport_error"]
                    )
                return output

            try:
                windows = bridge(
                    {
                        "op": "prepare",
                        "policy": args.policy,
                        "request": request,
                        # PCC reasoning is a helper flag, never a Gemini config;
                        # only Gemini thinkingLevel routes bake it in.
                        "thinking": None
                        if pcc
                        else adapter.bridge_thinking(args.thinking),
                    }
                )["windows"]
                for index, window in enumerate(windows):
                    payload = (
                        provider_payload(
                            args.model, window["payload"], args.thinking, args.max_output
                        )
                        if pcc
                        else window["payload"]
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
                                )
                                if pcc
                                else corrective,
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
                error = safe_error(exc, key, secrets)
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
                **({} if pcc else run_accounting(adapter, args.thinking, calls)),
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

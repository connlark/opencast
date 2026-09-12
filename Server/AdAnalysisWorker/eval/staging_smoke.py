#!/usr/bin/env python3
"""Budget-reserved async smoke against an explicitly supplied staging Worker.

Worker retries can incur unreported upstream usage. Settle only a complete
per-attempt accounting receipt; retain the pessimistic reservation whenever a
dispatched attempt has unknown usage. Never run against production.
"""

import argparse
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from budget import Ledger
from run import bridge, http, safe_error, write


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument(
        "--staging-host",
        required=True,
        help="Exact workers.dev hostname independently confirmed to be non-production",
    )
    parser.add_argument("--request", type=Path, required=True)
    credentials = parser.add_mutually_exclusive_group(required=True)
    credentials.add_argument("--key-file", type=Path)
    credentials.add_argument(
        "--key-env-file",
        type=Path,
        help="Read AD_ANALYSIS_CLIENT_TOKEN from a dotenv file without executing it",
    )
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--expected-revision", required=True)
    parser.add_argument("--max-spend", type=float, default=15)
    args = parser.parse_args()
    parsed = urllib.parse.urlparse(args.url)
    if (
        parsed.scheme != "https"
        or parsed.hostname != args.staging_host
        or not args.staging_host.endswith(".workers.dev")
        or "production" in args.staging_host.split(".")[0].split("-")
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        parser.error(
            "Supply the exact, independently confirmed non-production workers.dev host"
        )
    if not args.tag.replace("-", "").isalnum():
        parser.error("Unsafe tag")
    os.umask(0o077)
    out = args.out / args.tag
    out.mkdir(parents=True, exist_ok=False)
    request = json.loads(args.request.read_text())
    request["async_supported"] = True
    request["job_handle_version"] = 1
    if args.key_file:
        key = args.key_file.read_text().strip()
    else:
        matches = re.findall(
            r"^AD_ANALYSIS_CLIENT_TOKEN\s*=\s*(.+?)\s*$",
            args.key_env_file.read_text(),
            re.MULTILINE,
        )
        if len(matches) != 1:
            parser.error("Expected one bearer token assignment")
        key = matches[0].strip().strip("\"'")
    if not key:
        parser.error("Missing bearer token")
    ledger = Ledger(args.out / "budget-ledger.json", args.max_spend)
    windows = bridge(
        {
            "op": "prepare",
            "policy": "promo_ad_breaks_v3",
            "request": request,
            "thinking": "medium",
        }
    )["windows"]
    # UTF-8 byte counts bound text tokens more pessimistically than the quota's
    # chars/4 heuristic. Two initial attempts and one repair per window;
    # nested JSON strings can double the bounded corrective history size.
    input_bound = sum(
        len(json.dumps(w["payload"], ensure_ascii=False).encode()) * 3 + 2 * 132_768 + 4096
        for w in windows
    )
    ident = ledger.reserve(
        "gemini-3.8-flash",
        input_bound,
        16_384 * 3 * len(windows),
        {"tag": args.tag, "worker": args.url},
    )
    # Identify the authorized evaluation client explicitly. Some edge integrity
    # checks reject Python's generic default before the request reaches a Worker.
    headers = {
        "authorization": f"Bearer {key}",
        "user-agent": "OpenCast-Ad-Evaluation/1.0",
    }
    origin = args.url.rstrip("/")
    started = time.monotonic()
    settlement = None
    try:
        result = http(origin + "/v1/ad-analysis/transcript", request, headers)
        write(out / "submit.json", result)
        while result.get("state") == "running" or (
            "job_id" in result and "spans" not in result
        ):
            if time.monotonic() - started > 600:
                raise RuntimeError("Staging job did not finish within its deadline")
            time.sleep(min(10, max(1, result.get("poll_after_seconds", 2))))
            handle = result.get("job_id", "")
            fingerprint = request["transcript"]["fingerprint"]
            if not re.fullmatch(r"(?:a3\.[A-Za-z0-9]{1,24}\.)?[A-Za-z0-9._-]{8,128}", handle) or not (
                handle == fingerprint or handle.startswith("a3.") and handle.split(".", 2)[2] == fingerprint
            ):
                raise RuntimeError("Staging returned an invalid job handle")
            result = http(
                origin + "/v1/ad-analysis/jobs/" + handle,
                {"job_id": handle},
                headers,
            )
        write(out / "response.json", result)
        if (
            result.get("policy") != "promo_ad_breaks_v3"
            or result.get("model") != "gemini-3.8-flash"
            or result.get("policy_revision") != args.expected_revision
        ):
            raise RuntimeError("Unexpected staging policy/model")
        # Check idempotent async cache on the exact same request and namespace.
        cached = http(origin + "/v1/ad-analysis/transcript", request, headers)
        if cached != result:
            raise RuntimeError("Cached resubmit differs from completed result")
        accounting = result.get("accounting") or {}
        usage = accounting.get("reported_usage")
        if (accounting.get("unknown_attempts") == 0 and accounting.get("reserved_input_tokens") == 0
                and accounting.get("dispatched_attempts", 0) > 0 and usage):
            settlement = dict(input=usage["prompt_token_count"], cached=0, write=0,
                output=max(usage["candidates_token_count"] + usage["thoughts_token_count"],
                           usage["total_token_count"] - usage["prompt_token_count"]))
        write(
            out / "summary.json",
            {
                "elapsed_s": round(time.monotonic() - started, 3),
                "reservation": ident,
                "reported_usage": result.get("usage"),
                "policy_revision": result["policy_revision"],
                "accounting": accounting,
                "spans": result["spans"],
                "warnings": result.get("warnings"),
                "cache_verified": True,
            },
        )
        print(
            json.dumps(
                {
                    "policy": result["policy"],
                    "model": result["model"],
                    "policy_revision": result["policy_revision"],
                    "accounting": accounting,
                    "spans": len(result["spans"]),
                    "warnings": result.get("warnings"),
                    "cache_verified": True,
                }
            )
        )
    except Exception as error:  # noqa: BLE001 - redact before reporting any failure
        detail = safe_error(error, key)
        write(out / "error.json", {"error": detail, "reservation": ident})
        raise RuntimeError(detail) from None
    finally:
        ledger.finish(
            ident,
            "settled" if settlement else "ambiguous",
            usage=settlement,
            error=None if settlement else "Worker dispatch: retain full retry reservation; some usage is unknown",
        )
        print(json.dumps(ledger.snapshot()["totals"]))


if __name__ == "__main__":
    main()

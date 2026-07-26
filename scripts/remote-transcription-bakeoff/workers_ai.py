#!/usr/bin/env python3
"""Run byte-stable audio chunks through Workers AI using Wrangler auth."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


MODELS = {
    "@cf/openai/whisper": {"published_dollars_per_minute": 0.0005},
    "@cf/openai/whisper-large-v3-turbo": {"published_dollars_per_minute": 0.0005},
    "@cf/deepgram/nova-3": {"published_dollars_per_minute": 0.0052},
}
RETRYABLE_STATUS = {429, 500, 502, 503, 504}
SAFE_RESPONSE_HEADERS = {"content-type", "cf-ray", "server-timing"}


def wrangler_json(*arguments: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="opencast-remote-transcription-wrangler-") as cwd:
        completed = subprocess.run(
            ["wrangler", *arguments, "--json"],
            check=True,
            capture_output=True,
            text=True,
            cwd=cwd,
        )
    return json.loads(completed.stdout)


def credentials() -> tuple[str, str]:
    auth = wrangler_json("auth", "token")
    identity = wrangler_json("whoami")
    accounts = identity.get("accounts", [])
    if not identity.get("loggedIn") or len(accounts) != 1:
        raise SystemExit("Wrangler must be authenticated to exactly one account for this driver")
    token = auth.get("token")
    account_id = accounts[0].get("id")
    if not isinstance(token, str) or not isinstance(account_id, str):
        raise SystemExit("Wrangler did not return usable in-memory credentials")
    return token, account_id


def request_payload(model: str, audio: bytes) -> tuple[bytes, str, dict[str, str]]:
    if model == "@cf/openai/whisper":
        return audio, "audio/mpeg", {}
    if model == "@cf/openai/whisper-large-v3-turbo":
        body = json.dumps(
            {
                "audio": base64.b64encode(audio).decode("ascii"),
                "task": "transcribe",
                "language": "en",
                "vad_filter": False,
                "condition_on_previous_text": False,
            },
            separators=(",", ":"),
        ).encode("utf-8")
        return body, "application/json", {}
    if model == "@cf/deepgram/nova-3":
        return audio, "audio/mpeg", {
            "language": "en",
            "mip_opt_out": "true",
            "punctuate": "true",
            "smart_format": "true",
        }
    raise AssertionError(model)


def response_headers(headers) -> dict[str, str]:
    return {
        key.lower(): value
        for key, value in headers.items()
        if key.lower() in SAFE_RESPONSE_HEADERS
    }


def post(
    *,
    url: str,
    token: str,
    body: bytes,
    content_type: str,
    timeout: float,
) -> tuple[int, bytes, dict[str, str], float]:
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": content_type,
            "User-Agent": "OpenCast-remote-transcription-bakeoff/1",
        },
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read()
            return response.status, payload, response_headers(response.headers), time.monotonic() - started
    except urllib.error.HTTPError as error:
        payload = error.read()
        return error.code, payload, response_headers(error.headers), time.monotonic() - started


def json_success(status: int, payload: bytes) -> bool:
    if status < 200 or status >= 300:
        return False
    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError:
        return False
    return not (isinstance(decoded, dict) and decoded.get("success") is False)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--model", choices=sorted(MODELS), required=True)
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--end-index-exclusive", type=int)
    parser.add_argument("--max-attempts", type=int, default=2)
    parser.add_argument("--timeout-seconds", type=float, default=600)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.max_attempts < 1 or args.max_attempts > 2:
        raise SystemExit("--max-attempts must be 1 or 2 for this bounded bakeoff")

    manifest = json.loads(args.manifest.read_text())
    chunks = manifest["chunks"]
    end = args.end_index_exclusive if args.end_index_exclusive is not None else len(chunks)
    selected = [chunk for chunk in chunks if args.start_index <= chunk["index"] < end]
    estimated_minutes = sum(chunk["actualDurationSeconds"] for chunk in selected) / 60
    estimated_cost = estimated_minutes * MODELS[args.model]["published_dollars_per_minute"]
    if estimated_cost > 10:
        raise SystemExit(f"selected requests estimate ${estimated_cost:.2f}, above the $10 task cap")

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    token, account_id = credentials()
    model_path = urllib.parse.quote(args.model, safe="@/")
    base_url = f"https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/{model_path}"
    records: list[dict] = []
    for chunk in selected:
        stem = f"chunk-{chunk['index']:04d}"
        raw_path = output_dir / f"{stem}.json"
        metadata_path = output_dir / f"{stem}.meta.json"
        if raw_path.exists() and metadata_path.exists() and not args.force:
            record = json.loads(metadata_path.read_text())
            records.append(record)
            print(f"{args.model} chunk={chunk['index']:04d} skipped=existing")
            continue

        audio_path = Path(chunk["path"])
        audio = audio_path.read_bytes()
        if hashlib.sha256(audio).hexdigest() != chunk["sha256"]:
            raise SystemExit(f"chunk hash mismatch: {audio_path}")
        body, content_type, query = request_payload(args.model, audio)
        url = base_url
        if query:
            url += "?" + urllib.parse.urlencode(query)
        attempts: list[dict] = []
        final_payload = b""
        succeeded = False
        for attempt in range(1, args.max_attempts + 1):
            try:
                status, payload, headers, wall = post(
                    url=url,
                    token=token,
                    body=body,
                    content_type=content_type,
                    timeout=args.timeout_seconds,
                )
                succeeded = json_success(status, payload)
                final_payload = payload
                attempts.append(
                    {
                        "attempt": attempt,
                        "httpStatus": status,
                        "wallSecondsIncludingUpload": wall,
                        "responseHeaders": headers,
                        "responseByteCount": len(payload),
                        "responseSHA256": hashlib.sha256(payload).hexdigest(),
                        "success": succeeded,
                    }
                )
                if succeeded or status not in RETRYABLE_STATUS:
                    break
            except urllib.error.URLError as error:
                attempts.append(
                    {
                        "attempt": attempt,
                        "transportErrorType": type(error.reason).__name__,
                        "success": False,
                    }
                )
            if attempt < args.max_attempts:
                time.sleep(1)

        raw_path.write_bytes(final_payload)
        total_wall = sum(attempt.get("wallSecondsIncludingUpload", 0) for attempt in attempts)
        record = {
            "schemaVersion": 1,
            "model": args.model,
            "sourceSHA256": manifest["source"]["sha256"],
            "chunkIndex": chunk["index"],
            "chunkSHA256": chunk["sha256"],
            "chunkByteCount": chunk["byteCount"],
            "requestBodyByteCount": len(body),
            "requestedStartSeconds": chunk["requestedStartSeconds"],
            "audioDurationSeconds": chunk["actualDurationSeconds"],
            "attempts": attempts,
            "requestCount": len(attempts),
            "retryCount": max(0, len(attempts) - 1),
            "success": succeeded,
            "wallSecondsIncludingUpload": total_wall,
            "realTimeFactorIncludingUpload": (
                total_wall / chunk["actualDurationSeconds"]
                if chunk["actualDurationSeconds"]
                else None
            ),
            "rawOutputPath": str(raw_path),
        }
        metadata_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        records.append(record)
        last_status = attempts[-1].get("httpStatus", "transport-error")
        print(
            f"{args.model} chunk={chunk['index']:04d} status={last_status} "
            f"success={str(succeeded).lower()} wall={total_wall:.3f}s "
            f"rtf={record['realTimeFactorIncludingUpload']:.5f} attempts={len(attempts)}"
        )

    summary = {
        "schemaVersion": 1,
        "model": args.model,
        "sourceSHA256": manifest["source"]["sha256"],
        "manifestPath": str(args.manifest.resolve()),
        "selectedStartIndex": args.start_index,
        "selectedEndIndexExclusive": end,
        "estimatedPublishedCostDollars": estimated_cost,
        "records": records,
    }
    (output_dir / "run.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    failures = sum(not record["success"] for record in records)
    print(
        f"completed model={args.model} requests={sum(r['requestCount'] for r in records)} "
        f"failures={failures} estimated_cost=${estimated_cost:.4f}"
    )
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

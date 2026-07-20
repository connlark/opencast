#!/usr/bin/env python3
"""Remote transcription speed benchmark driver.

Runs the development-bearer synthetic flow against a self-hosted Worker for
each given enclosure URL: fetch the enclosure locally -> hash ->
create job -> report source identity -> poll (server-paced) -> result -> ack,
capturing every poll response with local timestamps plus the server's
`phase_timestamps`. If an R2 bucket is configured, it also verifies cleanup.
One JSON row per run is appended under the output directory.

Set `OPENCAST_REMOTE_TRANSCRIPTION_BASE_URL` and
`OPENCAST_REMOTE_TRANSCRIPTION_CLIENT_TOKEN` in the environment. Optionally
set `OPENCAST_REMOTE_TRANSCRIPTION_R2_BUCKET` to enable cleanup verification.
The token is never taken from arguments and never printed.
Generated rows contain enclosure URLs and job history; keep them outside Git.

Usage:
  python3 scripts/remote-transcription-benchmark/run_benchmark.py \
      --label ep15-c1 --url https://example.com/episode.mp3 \
      [--out /private/tmp/remote-transcription-benchmark-runs] \
      [--note "concurrency=1 cold"] [--stability-check]
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKER_DIR = REPO_ROOT / "Server" / "RemoteTranscriptionWorker"
BASE_URL = os.environ.get(
    "OPENCAST_REMOTE_TRANSCRIPTION_BASE_URL",
    "https://remote-transcription.example.com/development",
).rstrip("/")
R2_BUCKET = os.environ.get("OPENCAST_REMOTE_TRANSCRIPTION_R2_BUCKET", "").strip()
CACHE_DIR = Path("/private/tmp/remote-transcription-benchmark-cache")
USER_AGENT = "OpenCast-Media/1 (+https://opencast.mobile)"
SCHEMA_VERSION = 1
TERMINAL_STATES = {"acknowledged", "cancelled", "failed"}
MICRO_USD_PER_AUDIO_MINUTE = 0.0005  # published whisper-large-v3-turbo rate


def read_bearer() -> str:
    bearer = os.environ.get("OPENCAST_REMOTE_TRANSCRIPTION_CLIENT_TOKEN", "").strip()
    if bearer:
        return bearer
    sys.exit("OPENCAST_REMOTE_TRANSCRIPTION_CLIENT_TOKEN is required")


def api(bearer: str, path: str, body: dict) -> dict:
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=json.dumps(body).encode(),
        headers={
            "authorization": f"Bearer {bearer}",
            "content-type": "application/json",
            # Cloudflare's edge 403s the default Python-urllib user agent.
            "user-agent": "OpenCast-Benchmark/0.5 (+https://opencast.mobile)",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read())


def fetch_enclosure(url: str) -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    name = hashlib.sha256(url.encode()).hexdigest()[:16] + ".mp3"
    target = CACHE_DIR / name
    if not target.exists():
        request = urllib.request.Request(url, headers={"user-agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=300) as response, open(
            target, "wb"
        ) as out:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                out.write(chunk)
    return target


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stability_check(url: str) -> bool:
    """Fetch the enclosure twice over separate connections; DAI hosts serve
    different bytes per fetch and would only waste a server-side mismatch."""
    hashes = []
    for _ in range(2):
        request = urllib.request.Request(url, headers={"user-agent": USER_AGENT})
        digest = hashlib.sha256()
        with urllib.request.urlopen(request, timeout=300) as response:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                digest.update(chunk)
        hashes.append(digest.hexdigest())
    return hashes[0] == hashes[1]


def wrangler_object_exists(key: str) -> bool:
    """`wrangler r2 object get` per known key: an error means deleted."""
    result = subprocess.run(
        [
            "yarn", "--silent", "wrangler", "r2", "object", "get",
            f"{R2_BUCKET}/{key}", "--pipe",
        ],
        cwd=WORKER_DIR,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def verify_r2_cleanup(job_id: str, chunk_count: int) -> dict:
    if not R2_BUCKET:
        return {"skipped": True, "reason": "R2 bucket not configured"}
    keys = [
        f"raw/{job_id}/source",
        f"results/{job_id}/transcript.json",
    ]
    keys += [f"chunks/{job_id}/{index}.mp3" for index in range(chunk_count)]
    keys += [f"responses/{job_id}/{index}.json" for index in range(chunk_count)]
    leftovers = [key for key in keys if wrangler_object_exists(key)]
    return {"checked_keys": len(keys), "leftover_keys": leftovers}


def run(args: argparse.Namespace) -> dict:
    bearer = read_bearer()
    started_wall = time.time()

    local_path = fetch_enclosure(args.url)
    byte_count = local_path.stat().st_size
    sha256 = sha256_of(local_path)
    print(f"[{args.label}] enclosure {byte_count} bytes sha256={sha256[:12]}…")

    if args.stability_check and not stability_check(args.url):
        sys.exit(f"[{args.label}] enclosure is NOT byte-stable across fetches; pick another episode")

    bootstrap = api(bearer, "/v1/remote-transcription/account/bootstrap", {"schema_version": SCHEMA_VERSION})
    balance_before = bootstrap["balance"]

    client_request_id = f"bench-{args.label}-{int(started_wall)}"
    created = api(
        bearer,
        "/v1/remote-transcription/jobs",
        {
            "schema_version": SCHEMA_VERSION,
            "client_request_id": client_request_id,
            "episode_id": f"bench-{sha256[:16]}",
            "enclosure_url": args.url,
        },
    )
    job_id = created["job"]["job_id"]
    print(f"[{args.label}] job {job_id} created")

    api(
        bearer,
        f"/v1/remote-transcription/jobs/{job_id}/source",
        {
            "schema_version": SCHEMA_VERSION,
            "source_identity": {"sha256": sha256, "byte_count": byte_count},
        },
    )

    polls = []
    state = created["job"]["state"]
    result_payload = None
    while True:
        poll = api(bearer, f"/v1/remote-transcription/jobs/{job_id}/poll", {"schema_version": SCHEMA_VERSION})
        polls.append({"at": time.time(), "job": poll["job"]})
        state = poll["job"]["state"]
        if state in ("result_ready", "delivered"):
            break
        if state in TERMINAL_STATES:
            break
        time.sleep(poll.get("poll_after_seconds", 5))

    if state in ("result_ready", "delivered"):
        result_payload = api(bearer, f"/v1/remote-transcription/jobs/{job_id}/result", {"schema_version": SCHEMA_VERSION})
        normalized = result_payload["result"]["provenance"]["normalized_transcript_sha256"]
        api(
            bearer,
            f"/v1/remote-transcription/jobs/{job_id}/ack",
            {"schema_version": SCHEMA_VERSION, "normalized_transcript_sha256": normalized},
        )

    final_poll = api(bearer, f"/v1/remote-transcription/jobs/{job_id}/poll", {"schema_version": SCHEMA_VERSION})
    polls.append({"at": time.time(), "job": final_poll["job"]})
    balance_after = api(bearer, "/v1/remote-transcription/account/bootstrap", {"schema_version": SCHEMA_VERSION})["balance"]

    job = final_poll["job"]
    timestamps = job.get("phase_timestamps") or {}
    states = timestamps.get("states") or {}
    chunk_spans = timestamps.get("chunks") or []
    progress = job.get("progress") or {}
    chunk_count = progress.get("chunks_total") or 0
    cleanup = verify_r2_cleanup(job_id, chunk_count) if job["state"] in TERMINAL_STATES else {"skipped": True}

    result_summary = None
    if result_payload:
        result = result_payload["result"]
        result_summary = {
            "duration_seconds": result["duration_seconds"],
            "segments": len(result["segments"]),
            "normalized_transcript_sha256": result["provenance"]["normalized_transcript_sha256"],
            "chunk_manifest_sha256": result["provenance"]["chunk_manifest_sha256"],
            "model": result["provenance"]["model_identifier"],
        }

    duration = (result_summary or {}).get("duration_seconds") or 0
    retried_seconds = sum(
        span.get("failed_attempts", 0) * 300 for span in chunk_spans
    )
    estimated_cost_usd = ((duration + retried_seconds) / 60.0) * MICRO_USD_PER_AUDIO_MINUTE

    row = {
        "label": args.label,
        "note": args.note,
        "enclosure_url": args.url,
        "source_identity": {"sha256": sha256, "byte_count": byte_count},
        "job_id": job_id,
        "final_state": job["state"],
        "error": job.get("error"),
        "chunks_total": chunk_count,
        "phase_timestamps": states,
        "chunk_ai_spans": chunk_spans,
        "result": result_summary,
        "settled_seconds": balance_before["available_seconds"] - balance_after["available_seconds"],
        "balance_reserved_after": balance_after["reserved_seconds"],
        "estimated_workers_ai_cost_usd": round(estimated_cost_usd, 5),
        "r2_cleanup": cleanup,
        "wall_started_at": started_wall,
        "wall_ended_at": time.time(),
        "polls": polls,
    }
    return row


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, help="short run label, e.g. ep45-c4-warm")
    parser.add_argument("--url", required=True, help="public MP3 enclosure URL")
    parser.add_argument("--note", default="", help="free-form context recorded in the row")
    parser.add_argument("--stability-check", action="store_true", help="verify the enclosure is byte-stable before running")
    parser.add_argument(
        "--out",
        default="/private/tmp/remote-transcription-benchmark-runs",
        help="directory for per-run JSON rows",
    )
    args = parser.parse_args()

    row = run(args)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{args.label}.json"
    out_path.write_text(json.dumps(row, indent=2) + "\n")

    states = row["phase_timestamps"]
    if states:
        ordered = sorted(states.items(), key=lambda item: item[1])
        phases = " -> ".join(f"{name}@{ts - ordered[0][1]}s" for name, ts in ordered)
        print(f"[{args.label}] phases: {phases}")
    print(
        f"[{args.label}] state={row['final_state']} settled={row['settled_seconds']}s "
        f"cost~${row['estimated_workers_ai_cost_usd']} cleanup_leftovers={row['r2_cleanup'].get('leftover_keys', 'n/a')} -> {out_path}"
    )
    if row["final_state"] != "acknowledged":
        sys.exit(2)


if __name__ == "__main__":
    main()

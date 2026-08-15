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

Host prerequisites: `ffprobe` (ships with ffmpeg, e.g. `brew install ffmpeg`)
for the local duration measurement, and `yarn`/`wrangler` credentials able to
read the dev R2 bucket for cleanup verification.

Account-wide balance deltas (settlement and reservation gates) assume this
dev account runs nothing else concurrently; another active or abandoned job
would masquerade as a settlement mismatch. The script records a failed gate
if the account already holds a reservation at start.

Validation is deferred: after the job is created, observations and gate
failures are accumulated instead of raised, so result retrieval,
acknowledgement, balance inspection, R2 cleanup verification, and the JSON
row are always attempted. The row carries `failed_gates`; the exit status
reflects them only after the evidence is written.

Usage:
  python3 scripts/remote-transcription-benchmark/run_benchmark.py \
      --label ep15-c1 --url https://example.com/episode.mp3 \
      [--out /private/tmp/remote-transcription-benchmark-runs] \
      [--note "concurrency=1 cold"] [--stability-check] \
      [--require-probing-eta]
"""

import argparse
import hashlib
import json
import math
import os
import re
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

# Mirror of the server's calibrated native scan budget (src/eta.rs): a
# `delayed` probing classification is legitimate once this much time has
# passed since the first durable source_matched/probing timestamp.
PROBE_AND_RESERVATION_SECONDS = 4.0
NATIVE_WALK_SECONDS_PER_MB = 0.3
DELAYED_GRACE_SECONDS = 30.0


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


def sanitized_stderr(stderr: str, limit: int = 300) -> str:
    lines = [line.strip() for line in (stderr or "").splitlines() if line.strip()]
    return " | ".join(lines)[:limit] or "(no stderr)"


def duration_of(path: Path) -> float:
    try:
        completed = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        sys.exit(
            "ffprobe not found on PATH; it is a host prerequisite "
            "(ships with ffmpeg, e.g. `brew install ffmpeg`)"
        )
    if completed.returncode != 0:
        sys.exit(
            f"ffprobe failed for {path} (exit {completed.returncode}): "
            f"{sanitized_stderr(completed.stderr)}"
        )
    text = completed.stdout.strip()
    if not text or text == "N/A":
        sys.exit(
            f"ffprobe reported no duration for {path} (output {text!r}); "
            "is this a valid audio file?"
        )
    try:
        duration = float(text)
    except ValueError:
        sys.exit(f"ffprobe duration not parseable for {path}: {text!r}")
    if not math.isfinite(duration) or duration <= 0:
        sys.exit(f"ffprobe returned invalid duration for {path}: {duration}")
    return duration


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


def wrangler_object_status(key: str) -> str:
    """'present', 'absent', or 'error: …'. Fail closed: only an explicit
    object-not-found from wrangler counts as deleted — auth, config,
    network, or executable failures must not read as clean R2."""
    try:
        result = subprocess.run(
            [
                str(REPO_ROOT / "node_modules" / ".bin" / "wrangler"),
                "r2", "object", "get", f"{R2_BUCKET}/{key}", "--pipe",
            ],
            cwd=WORKER_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        return "error: root wrangler binary missing; run `yarn install` at the repo root"
    if result.returncode == 0:
        return "present"
    stderr = sanitized_stderr(result.stderr)
    lowered = stderr.lower()
    if (
        "does not exist" in lowered
        or "not found" in lowered
        or "10007" in lowered
        or "404" in lowered
    ):
        return "absent"
    return f"error: exit {result.returncode}: {stderr}"


def verify_r2_cleanup(job_id: str, chunk_count: int) -> dict:
    if not R2_BUCKET:
        return {"skipped": True, "reason": "R2 bucket not configured"}
    keys = [
        f"raw/{job_id}/source",
        f"uploads/{job_id}/source",
        f"results/{job_id}/transcript.json",
    ]
    keys += [f"chunks/{job_id}/{index}.mp3" for index in range(chunk_count)]
    keys += [f"responses/{job_id}/{index}.json" for index in range(chunk_count)]
    leftovers = []
    errors = []
    for key in keys:
        status = wrangler_object_status(key)
        if status == "present":
            leftovers.append(key)
        elif status != "absent":
            errors.append({"key": key, "error": status})
    return {
        "checked_keys": len(keys),
        "leftover_keys": leftovers,
        "verification_errors": errors,
    }


def record_probing_observation(observations: list, job: dict, at: float) -> None:
    progress = job.get("progress")
    if not isinstance(progress, dict):
        progress = {}
    observations.append(
        {
            "at": at,
            "estimate_status": progress.get("estimate_status"),
            "estimated_remaining_seconds": progress.get(
                "estimated_remaining_seconds"
            ),
        }
    )


def is_positive_on_track(observation: dict) -> bool:
    return (
        observation.get("estimate_status") == "on_track"
        and isinstance(observation.get("estimated_remaining_seconds"), int)
        and observation["estimated_remaining_seconds"] > 0
    )


def evaluate_probing_observations(
    observations: list, byte_count: int, states: dict
) -> list:
    """Deferred phase-aware gate checks over the recorded probing polls.

    A positive on-track ETA is required at least once when
    --require-probing-eta asked for it (checked by the caller). `delayed`
    is a failure only when observed before the calibrated scan budget plus
    grace has elapsed since the first durable source_matched/probing
    timestamp; a legitimately over-budget delayed scan is not a server
    failure. Any other status (missing progress, queued during probing with
    no ETA, unknown strings) fails the observation.
    """
    failures = []
    first_native = min(
        (
            states[state]
            for state in ("source_matched", "probing")
            if isinstance(states.get(state), (int, float))
        ),
        default=None,
    )
    budget = (
        PROBE_AND_RESERVATION_SECONDS
        + byte_count / 1_000_000.0 * NATIVE_WALK_SECONDS_PER_MB
        + DELAYED_GRACE_SECONDS
    )
    for observation in observations:
        if is_positive_on_track(observation):
            continue
        if observation.get("estimate_status") == "delayed":
            if first_native is None:
                failures.append(
                    {
                        "gate": "probing_delayed_without_phase_timestamp",
                        "detail": observation,
                    }
                )
            elif observation["at"] < first_native + budget:
                failures.append(
                    {
                        "gate": "probing_delayed_before_budget",
                        "detail": {
                            "observation": observation,
                            "budget_seconds": round(budget, 3),
                            "elapsed_seconds": round(
                                observation["at"] - first_native, 3
                            ),
                        },
                    }
                )
            continue
        failures.append({"gate": "probing_estimate_invalid", "detail": observation})
    return failures


def run(args: argparse.Namespace) -> dict:
    bearer = read_bearer()
    started_wall = time.time()

    local_path = fetch_enclosure(args.url)
    byte_count = local_path.stat().st_size
    sha256 = sha256_of(local_path)
    duration_seconds = duration_of(local_path)
    print(
        f"[{args.label}] enclosure {byte_count} bytes duration={duration_seconds:.3f}s "
        f"sha256={sha256[:12]}…"
    )

    if args.stability_check and not stability_check(args.url):
        sys.exit(f"[{args.label}] enclosure is NOT byte-stable across fetches; pick another episode")

    failures = []
    bootstrap = api(bearer, "/v1/remote-transcription/account/bootstrap", {"schema_version": SCHEMA_VERSION})
    balance_before = bootstrap["balance"]
    if balance_before.get("reserved_seconds"):
        failures.append(
            {
                "gate": "isolated_account_precondition",
                "detail": {
                    "reserved_seconds_at_start": balance_before["reserved_seconds"],
                },
            }
        )

    client_request_id = f"bench-{args.label}-{int(started_wall)}"
    created = api(
        bearer,
        "/v1/remote-transcription/jobs",
        {
            "schema_version": SCHEMA_VERSION,
            "client_request_id": client_request_id,
            "episode_id": f"bench-{sha256[:16]}",
            "enclosure_url": args.url,
            "declared_duration_seconds": duration_seconds,
        },
    )
    job_id = created["job"]["job_id"]
    print(f"[{args.label}] job {job_id} created")

    # From here on, validation is deferred: record, never raise, so the
    # normal result/ack/balance/cleanup/row sequence always runs.

    # Report the identity only after the job is actually waiting for it
    # (mirrors the app and the workerd suite): a report that lands during
    # staging just stores the identity and returns the staging state, so the
    # pinned inline source_matched contract would be unobservable.
    pre_polls = []
    wait_deadline = time.time() + 120
    while time.time() < wait_deadline:
        poll = api(bearer, f"/v1/remote-transcription/jobs/{job_id}/poll", {"schema_version": SCHEMA_VERSION})
        pre_polls.append({"at": time.time(), "job": poll["job"]})
        if poll["job"]["state"] not in ("created", "staging_origin"):
            break
        time.sleep(1)
    if (pre_polls[-1]["job"]["state"] if pre_polls else None) != "waiting_for_device_source":
        failures.append(
            {
                "gate": "reached_waiting_for_device_source",
                "detail": {
                    "last_state": pre_polls[-1]["job"]["state"] if pre_polls else None,
                },
            }
        )

    source_response = api(
        bearer,
        f"/v1/remote-transcription/jobs/{job_id}/source",
        {
            "schema_version": SCHEMA_VERSION,
            "source_identity": {
                "sha256": sha256,
                "byte_count": byte_count,
                "duration_seconds": duration_seconds,
            },
        },
    )
    source_job = source_response.get("job") or {}
    source_observation = {
        "at": time.time(),
        "state": source_job.get("state"),
        "progress": source_job.get("progress"),
    }
    # The matching identity's immediate /source response is the pinned
    # inline-evaluation contract: source_matched with a positive on-track
    # ETA (never a response that merely armed an alarm and still reports
    # waiting_for_device_source).
    source_progress = source_job.get("progress") or {}
    if source_job.get("state") != "source_matched" or not is_positive_on_track(
        {
            "estimate_status": source_progress.get("estimate_status"),
            "estimated_remaining_seconds": source_progress.get(
                "estimated_remaining_seconds"
            ),
        }
    ):
        failures.append(
            {"gate": "source_response_matched_with_eta", "detail": source_observation}
        )

    polls = pre_polls
    probing_eta_observations = []
    state = source_job.get("state") or created["job"]["state"]
    result_payload = None
    ack_state = None
    while True:
        poll = api(bearer, f"/v1/remote-transcription/jobs/{job_id}/poll", {"schema_version": SCHEMA_VERSION})
        polls.append({"at": time.time(), "job": poll["job"]})
        state = poll["job"]["state"]
        if state == "probing":
            record_probing_observation(
                probing_eta_observations, poll["job"], polls[-1]["at"]
            )
        if state in ("result_ready", "delivered"):
            break
        if state in TERMINAL_STATES:
            break
        time.sleep(poll.get("poll_after_seconds", 5))

    if state in ("result_ready", "delivered"):
        try:
            result_payload = api(bearer, f"/v1/remote-transcription/jobs/{job_id}/result", {"schema_version": SCHEMA_VERSION})
            normalized = result_payload["result"]["provenance"]["normalized_transcript_sha256"]
            ack = api(
                bearer,
                f"/v1/remote-transcription/jobs/{job_id}/ack",
                {"schema_version": SCHEMA_VERSION, "normalized_transcript_sha256": normalized},
            )
            ack_state = (ack.get("job") or {}).get("state")
        except Exception as error:  # record, keep gathering evidence
            failures.append(
                {"gate": "result_or_ack_request", "detail": repr(error)[:300]}
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

    # --- Deferred gates (the job is terminal/observed; evidence is intact).
    failures.extend(
        evaluate_probing_observations(probing_eta_observations, byte_count, states)
    )
    if args.require_probing_eta and not any(
        is_positive_on_track(observation)
        for observation in probing_eta_observations
    ):
        failures.append(
            {
                "gate": "probing_eta_required",
                "detail": f"{len(probing_eta_observations)} probing polls, none on-track",
            }
        )
    if job["state"] != "acknowledged":
        failures.append(
            {
                "gate": "final_state_acknowledged",
                "detail": {"final_state": job["state"], "ack_state": ack_state,
                           "error": job.get("error")},
            }
        )
    settled_seconds = balance_before["available_seconds"] - balance_after["available_seconds"]
    if result_summary:
        expected_settlement = math.ceil(result_summary["duration_seconds"])
        if settled_seconds != expected_settlement:
            failures.append(
                {
                    "gate": "exact_settlement",
                    "detail": {"expected": expected_settlement, "settled": settled_seconds},
                }
            )
    else:
        failures.append({"gate": "result_retrieved", "detail": "no result payload"})
    if balance_after["reserved_seconds"] != 0:
        failures.append(
            {
                "gate": "zero_reservation_after",
                "detail": {"reserved_seconds": balance_after["reserved_seconds"]},
            }
        )
    if cleanup.get("leftover_keys"):
        failures.append(
            {"gate": "r2_cleanup_empty", "detail": cleanup["leftover_keys"]}
        )
    if cleanup.get("verification_errors"):
        failures.append(
            {
                "gate": "r2_cleanup_verification",
                "detail": cleanup["verification_errors"],
            }
        )

    return {
        "label": args.label,
        "note": args.note,
        "enclosure_url": args.url,
        "source_identity": {
            "sha256": sha256,
            "byte_count": byte_count,
            "duration_seconds": duration_seconds,
        },
        "job_id": job_id,
        "final_state": job["state"],
        "error": job.get("error"),
        "chunks_total": chunk_count,
        "phase_timestamps": states,
        "chunk_ai_spans": chunk_spans,
        "source_response": source_observation,
        "probing_eta_observations": probing_eta_observations,
        "result": result_summary,
        "settled_seconds": settled_seconds,
        "balance_reserved_after": balance_after["reserved_seconds"],
        "estimated_workers_ai_cost_usd": round(estimated_cost_usd, 5),
        "r2_cleanup": cleanup,
        "failed_gates": failures,
        "wall_started_at": started_wall,
        "wall_ended_at": time.time(),
        "polls": polls,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--label", required=True, help="short run label, e.g. ep45-c4-warm")
    parser.add_argument("--url", required=True, help="public MP3 enclosure URL")
    parser.add_argument("--note", default="", help="free-form context recorded in the row")
    parser.add_argument("--stability-check", action="store_true", help="verify the enclosure is byte-stable before running")
    parser.add_argument(
        "--require-probing-eta",
        action="store_true",
        help="fail (after evidence capture) unless at least one probing poll "
        "carried a positive on-track ETA; a legitimately over-budget "
        "delayed scan alone does not satisfy or fail this",
    )
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
    if row["failed_gates"]:
        for failure in row["failed_gates"]:
            print(f"[{args.label}] FAILED GATE {failure['gate']}: {json.dumps(failure['detail'], default=str)}")
        sys.exit(2)
    print(f"[{args.label}] all gates passed")


if __name__ == "__main__":
    main()

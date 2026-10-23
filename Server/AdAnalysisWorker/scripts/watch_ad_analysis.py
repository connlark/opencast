#!/usr/bin/env python3
"""Read-only health/observability snapshot; never submits a model job.

Example: python3 Server/AdAnalysisWorker/scripts/watch_ad_analysis.py \
    --credentials-env-file /path/to/operator.env \
    --production-worker ad-analysis-production --staging-worker ad-analysis-staging \
    --production-health-url https://production.example.com/health \
    --staging-health-url https://staging.example.com/health

Only allowlisted metrics and opaque trace identifiers leave this process. Raw
Cloudflare rows can contain request headers and are neither printed nor saved.
"""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import shlex
import time
import urllib.error
import urllib.parse
import urllib.request


ENVIRONMENTS = ("production", "prod-staging")
ROW_LIMIT = 2000
SAFE_CODE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")


class ReadError(Exception):
    """A content-free operational error safe to include in JSON output."""


def mapping(value):
    """Untrusted JSON: anything but an object reads as empty, never raises."""
    return value if isinstance(value, dict) else {}


def sequence(value):
    return value if isinstance(value, list) else []


def safe_code(value, fallback="unknown"):
    return value if isinstance(value, str) and SAFE_CODE.fullmatch(value) else fallback


def health_url(value):
    """Accept only an explicit HTTPS health endpoint with no credential data."""
    try:
        parsed = urllib.parse.urlsplit(value)
        valid = (parsed.scheme == "https" and parsed.hostname and parsed.path == "/health"
                 and parsed.username is None and parsed.password is None
                 and "?" not in value and "#" not in value
                 and not any(character.isspace() or ord(character) < 32 for character in value))
        parsed.port  # Validate any explicit port without accepting parser errors.
    except ValueError:
        valid = False
    if not valid:
        raise argparse.ArgumentTypeError("health URL must be HTTPS /health without userinfo, query, or fragment")
    return value


def worker_name(value):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", value):
        raise argparse.ArgumentTypeError("worker name must contain only lowercase letters, digits, and hyphens")
    return value


def credentials(path):
    values = {}
    try:
        lines = Path(path).expanduser().read_text().splitlines()
        for line in lines:
            match = re.match(r"^\s*(?:export\s+)?(CLOUDFLARE_ACCOUNT_ID|CLOUDFLARE_API_TOKEN)\s*=(.*)$", line)
            if match:
                parts = shlex.split(match[2], comments=True)
                if len(parts) == 1:
                    values[match[1]] = parts[0]
    except (OSError, ValueError):
        raise ReadError("credentials_file_unreadable_or_invalid") from None
    account = values.get("CLOUDFLARE_ACCOUNT_ID", "")
    token = values.get("CLOUDFLARE_API_TOKEN", "")
    if not re.fullmatch(r"[a-fA-F0-9]{32}", account) or not token:
        raise ReadError("credentials_missing_or_invalid")
    return account, token


def read_json(url, *, token=None, body=None):
    headers = {"Accept": "application/json", "Content-Type": "application/json",
               "User-Agent": "OpenCast-Ad-Analysis-Watch/1.0"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers, data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            raw = response.read(32 * 1024 * 1024 + 1)
            if len(raw) > 32 * 1024 * 1024:
                raise ReadError("response_too_large")
            return response.status, json.loads(raw)
    except urllib.error.HTTPError as error:
        # Do not echo error bodies: proxies and providers may include headers.
        raise ReadError(f"http_{error.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ReadError("network_error") from None
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ReadError("invalid_json") from None


def collect_events(query, start, end, budget):
    """Split capped intervals, with a strict bound on read-only API requests."""
    result = mapping(query(start, end))
    if result.get("success") is False:
        raise ReadError("telemetry_query_failed")
    result = mapping(result.get("result", result))
    events = mapping(result.get("events"))
    rows = events.get("events")
    if not isinstance(rows, list):
        raise ReadError("telemetry_shape_unrecognized")
    count = events.get("count")
    capped = len(rows) >= ROW_LIMIT or (isinstance(count, (int, float)) and count > len(rows))
    rows = [row for row in rows if isinstance(row, dict)]
    intervals = [mapping(entry).get("sampleInterval", 1) for bucket in sequence(events.get("series"))
                 for entry in sequence(mapping(bucket).get("data"))]
    abr = mapping(result.get("statistics")).get("abr_level", 1)
    sampled = any(isinstance(value, (int, float)) and value > 1 for value in intervals + [abr])
    if capped and budget >= 3 and end - start > 1000:
        middle = (start + end) // 2
        left_budget = (budget - 1) // 2
        left, left_meta = collect_events(query, start, middle, left_budget)
        right, right_meta = collect_events(query, middle, end, budget - 1 - left_budget)
        unique = {}
        for row in left + right:
            key = mapping(row.get("$metadata")).get("id") or hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest()
            unique[key] = row
        return list(unique.values()), {
            "queries": 1 + left_meta["queries"] + right_meta["queries"],
            "possibly_truncated": left_meta["possibly_truncated"] or right_meta["possibly_truncated"],
            "sampling_observed": sampled or left_meta["sampling_observed"] or right_meta["sampling_observed"],
        }
    return rows, {"queries": 1, "possibly_truncated": capped, "sampling_observed": sampled}


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else None


def percentiles(values):
    values = sorted(values)
    if not values:
        return {"samples": 0, "p50_ms": None, "p95_ms": None, "max_ms": None}
    return {"samples": len(values), "p50_ms": values[math.ceil(len(values) * .5) - 1],
            "p95_ms": values[math.ceil(len(values) * .95) - 1], "max_ms": values[-1]}


def summarize(rows):
    attempts, outcomes, statuses, worker_outcomes, versions = [], Counter(), Counter(), Counter(), Counter()
    accounting, revisions, failures = Counter(), {}, []
    exchange_errors, job_unavailable, alarm_errors = Counter(), Counter(), Counter()
    accounting_records = validation_failures = over_60s = near_limit = storage_resets = wall_time = 0
    for row in map(mapping, rows):
        source, worker, metadata = mapping(row.get("source")), mapping(row.get("$workers")), mapping(row.get("$metadata"))
        event = source.get("event")
        outcome = worker.get("outcome")
        if outcome:
            worker_outcomes[safe_code(outcome)] += 1
        status = number(mapping(mapping(worker.get("event")).get("response")).get("status"))
        if status is not None:
            statuses[str(int(status))] += 1
        version = mapping(worker.get("scriptVersion")).get("id")
        if version:
            versions[safe_code(version)] += 1
        failed = (status is not None and (status >= 500 or status == 429)) or (outcome is not None and outcome not in ("ok", "canceled"))
        # Platform exception text is matched here and never copied out.
        if any(isinstance(text, str) and "caused object to be reset" in text for text in (metadata.get("message"), metadata.get("error"))):
            storage_resets += 1
            failed = True
        wall_time += outcome == "exceededWallTime"
        if event == "ad_analysis_accounting_error":
            attempt = number(source.get("attempt"))
            key = f"{safe_code(source.get('op'))}:{safe_code(source.get('kind'))}:{int(attempt) if attempt is not None else 'unknown'}"
            code = source.get("code")
            exchange_errors[f"{key}:{safe_code(code)}" if code is not None else key] += 1
            failed = True
        elif event == "ad_analysis_job_unavailable":
            job_unavailable[safe_code(source.get("op"))] += 1
            failed = True
        elif event == "ad_analysis_alarm_error":
            alarm_errors[safe_code(source.get("op"))] += 1
            failed = True
        if event in ("ad_analysis_attempt", "ad_analysis_accounting", "ad_analysis_incomplete"):
            revision = safe_code(source.get("policy_revision"))
            bucket = revisions.setdefault(revision, {"attempts": 0, "accounting_records": 0, "unknown_attempts": 0, "outcomes": Counter(), "latencies": []})
            if event == "ad_analysis_attempt":
                code = safe_code(source.get("outcome"))
                upstream = number(source.get("upstream_status"))
                label = f"response_{int(upstream)}" if code == "response" and upstream is not None else code
                outcomes[label] += 1
                bucket["attempts"] += 1
                bucket["outcomes"][label] += 1
                elapsed, timeout = number(source.get("elapsed_ms")), number(source.get("timeout_ms"))
                if elapsed is not None:
                    attempts.append(elapsed)
                    bucket["latencies"].append(elapsed)
                    over_60s += elapsed > 60_000
                    near_limit += timeout is not None and timeout > 0 and elapsed >= .9 * timeout
                failed = failed or code != "response" or upstream is None or upstream >= 400
            elif event == "ad_analysis_accounting":
                accounting_records += 1
                bucket["accounting_records"] += 1
                usage = mapping(source.get("accounting"))
                for key in ("request_count", "dispatched_attempts", "unknown_attempts", "dispatched_input_tokens"):
                    value = number(usage.get(key))
                    if value is not None:
                        accounting[key] += value
                for key in ("prompt_token_count", "candidates_token_count", "thoughts_token_count", "total_token_count"):
                    value = number(mapping(usage.get("reported_usage")).get(key))
                    if value is not None:
                        accounting[f"reported_{key}"] += value
                unknown = number(usage.get("unknown_attempts")) or 0
                bucket["unknown_attempts"] += unknown
                failed = failed or unknown > 0
            else:
                validation_failures += 1
                failed = True
        if failed and len(failures) < 20:
            timestamp = number(row.get("timestamp"))
            failures.append({"timestamp": timestamp if timestamp is not None else safe_code(row.get("timestamp")), "request_id": safe_code(metadata.get("requestId")),
                "trace_id": safe_code(metadata.get("traceId")), "run_id": safe_code(source.get("run_id")),
                "event": safe_code(event), "outcome": safe_code(source.get("outcome")),
                "op": safe_code(source.get("op")), "kind": safe_code(source.get("kind")),
                "worker_outcome": safe_code(outcome),
                "policy_revision": safe_code(source.get("policy_revision")), "http_status": status,
                "upstream_status": number(source.get("upstream_status"))})
    for bucket in revisions.values():
        bucket["latency"] = percentiles(bucket.pop("latencies"))
    return {"observed_log_rows": len(rows), "provider_attempt_outcomes": outcomes, "provider_latency": percentiles(attempts),
        "attempts_over_60_seconds": over_60s, "attempts_at_least_90_percent_of_timeout": near_limit,
        "accounting_records": accounting_records, "accounting_totals": accounting, "validation_failure_events": validation_failures,
        "by_policy_revision": revisions, "http_response_event_counts": statuses, "worker_outcome_event_counts": worker_outcomes,
        "worker_version_event_counts": versions, "failure_examples": failures,
        "accounting_exchange_errors": exchange_errors, "job_unavailable_events": job_unavailable,
        "alarm_error_events": alarm_errors, "storage_reset_rows": storage_resets, "exceeded_wall_time_rows": wall_time,
        "analysis_traffic_observed": bool(accounting_records or outcomes),
        "log_payload_truncation_observed": any(mapping(mapping(row).get("$workers")).get("truncated") is True for row in rows)}


def environment_snapshot(name, service, endpoint, account, token, start, end, max_queries):
    report = {"environment": name, "worker": service, "health_url": endpoint}
    try:
        status, health = read_json(endpoint)
        health = mapping(health)
        report["health"] = {"status": status, "message": safe_code(health.get("message")),
            "policy_revision": safe_code(health.get("policy_revision"))}
    except ReadError as error:
        report["health"] = {"error": str(error)}
    def query(begin, finish):
        _, result = read_json(f"https://api.cloudflare.com/client/v4/accounts/{account}/workers/observability/telemetry/query", token=token, body={
            "queryId": "opencast-ad-analysis-watch", "dry": True, "view": "events", "limit": ROW_LIMIT,
            "timeframe": {"from": begin, "to": finish}, "parameters": {"datasets": ["cloudflare-workers"],
                "filters": [{"key": "$metadata.service", "type": "string", "operation": "eq", "value": service}]}})
        return result
    try:
        rows, coverage = collect_events(query, start, end, max_queries)
        report["coverage"] = coverage
        report["telemetry"] = summarize(rows)
    except ReadError as error:
        report["telemetry"] = {"error": str(error)}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials-env-file", required=True)
    parser.add_argument("--production-worker", required=True, type=worker_name)
    parser.add_argument("--staging-worker", required=True, type=worker_name)
    parser.add_argument("--staging-health-url", required=True, type=health_url)
    parser.add_argument("--production-health-url", required=True, type=health_url)
    parser.add_argument("--hours", type=float, default=4)
    parser.add_argument("--max-queries-per-environment", type=int, default=7)
    args = parser.parse_args()
    if not 0 < args.hours <= 24 or not 1 <= args.max_queries_per_environment <= 31:
        parser.error("hours must be in (0,24]; max queries must be in [1,31]")
    try:
        account, token = credentials(args.credentials_env_file)
    except ReadError as error:
        print(json.dumps({"error": str(error)}))
        return 1
    end = int(time.time() * 1000)
    start = end - int(args.hours * 3_600_000)
    endpoints = {"production": args.production_health_url, "prod-staging": args.staging_health_url}
    services = {"production": args.production_worker, "prod-staging": args.staging_worker}
    with ThreadPoolExecutor(max_workers=2) as pool:
        reports = list(pool.map(lambda name: environment_snapshot(name, services[name], endpoints[name], account, token, start, end, args.max_queries_per_environment), ENVIRONMENTS))
    result = {"generated_at": datetime.now(timezone.utc).isoformat(), "window": {"from_ms": start, "to_ms": end, "hours": args.hours},
        "read_only": True, "environments": reports, "interpretation": [
            "Counts and latency percentiles describe observed log events, not all requests or distinct jobs.",
            "HTTP polls and accounting records are not successful job counts; accounting also records failed analyses.",
            "Sampling, log retention, ingestion delay, and capped queries can hide events; no errors observed is not proof of absence.",
            "If analysis_traffic_observed is false, health alone does not verify Gemini analysis or client recovery.",
            "Near-timeout attempts and unknown usage merit investigation; a successful response over 60 seconds demonstrates the extended wait.",
            "accounting_exchange_errors keys are op:kind:attempt, plus :code when the limiter's refusal decoded. A timeout, transport or decode key at attempt 1 is a retry that failed too (usage_limiter_error unless the op is finish); dispatch:status:1:attempt_already_dispatched is a recovered dispatch, not a failure.",
            "job_unavailable_events are polls or submits answered 503 while the job object threw; storage_reset_rows count the platform's reset exception."]}
    print(json.dumps(result, indent=2, sort_keys=True))
    return int(any("error" in report["health"] or "error" in report["telemetry"] for report in reports))


if __name__ == "__main__":
    raise SystemExit(main())

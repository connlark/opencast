"""Offline checks for privacy, partial coverage, and monitor interpretation."""
import argparse
import json
import unittest

import watch_ad_analysis as watch


class WatchTests(unittest.TestCase):
    def test_health_url_requires_https_health_without_credentials_or_parameters(self):
        endpoint = "https://staging.example.com/health"
        self.assertEqual(watch.health_url(endpoint), endpoint)
        for invalid in ("http://example.com/health", "https://example.com/analyze", "https://user:secret@example.com/health",
                        "https://example.com/health?token=secret", "https://example.com/health#secret",
                        "https://example.com/health?", "https://example.com/health\n", "https://example.com:invalid/health"):
            with self.subTest(endpoint=invalid), self.assertRaises(argparse.ArgumentTypeError):
                watch.health_url(invalid)

    def test_allowlist_discards_content_and_summarizes_unknown_usage(self):
        private = "PRIVATE_HEADER_TRANSCRIPT_OR_PROVIDER_BODY"
        rows = [
            {"timestamp": 123, "$metadata": {"requestId": "request-1", "traceId": "trace-1", "message": private},
             "$workers": {"event": {"request": {"headers": {"authorization": private}}}},
             "source": {"event": "ad_analysis_attempt", "policy_revision": "revision-1", "run_id": "run-1",
                        "outcome": "gemini_timeout", "elapsed_ms": 120000, "timeout_ms": 120000, "body": private}},
            {"source": {"event": "ad_analysis_accounting", "policy_revision": "revision-1", "run_id": "run-1",
                        "accounting": {"request_count": 1, "dispatched_attempts": 2, "unknown_attempts": 1,
                                       "reported_usage": {"thoughts_token_count": 8000}}}},
            {"source": {"event": "ad_analysis_attempt", "policy_revision": "revision-1", "run_id": "run-1",
                        "outcome": "response", "upstream_status": 200, "elapsed_ms": 70000, "timeout_ms": 120000}},
        ]
        result = watch.summarize(rows)
        self.assertNotIn(private, json.dumps(result))
        self.assertEqual(result["provider_attempt_outcomes"], {"gemini_timeout": 1, "response_200": 1})
        self.assertEqual(result["provider_latency"]["p95_ms"], 120000)
        self.assertEqual(result["accounting_totals"]["unknown_attempts"], 1)
        self.assertEqual(result["accounting_totals"]["reported_thoughts_token_count"], 8000)
        self.assertEqual(result["failure_examples"][0]["timestamp"], 123)
        self.assertTrue(result["analysis_traffic_observed"])
        self.assertNotIn("successful_jobs", result)

    def test_storage_stall_signals_are_counted_without_platform_text(self):
        private = "Durable Object storage operation exceeded timeout which caused object to be reset. PRIVATE"
        rows = [
            {"$metadata": {"message": private}, "$workers": {"outcome": "exception"}},
            {"$workers": {"outcome": "exceededWallTime"}},
            {"source": {"event": "ad_analysis_job_unavailable", "op": "poll", "error": private}},
            {"source": {"event": "ad_analysis_accounting_error", "op": "admit", "kind": "timeout", "attempt": 0,
                        "run_id": "run-2", "policy_revision": "revision-1"}},
            {"source": {"event": "ad_analysis_accounting_error", "op": "admit", "kind": "timeout", "attempt": 1,
                        "run_id": "run-2", "policy_revision": "revision-1"}},
            {"source": {"event": "ad_analysis_accounting_error", "op": "dispatch", "kind": "status", "attempt": 1,
                        "code": "attempt_already_dispatched", "run_id": "run-3", "policy_revision": "revision-1"}},
            {"source": {"event": "ad_analysis_alarm_error", "op": "read", "error": private}},
        ]
        result = watch.summarize(rows)
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertEqual(result["storage_reset_rows"], 1)
        self.assertEqual(result["exceeded_wall_time_rows"], 1)
        self.assertEqual(result["job_unavailable_events"], {"poll": 1})
        self.assertEqual(result["accounting_exchange_errors"], {"admit:timeout:0": 1, "admit:timeout:1": 1,
                                                                "dispatch:status:1:attempt_already_dispatched": 1})
        self.assertEqual(result["alarm_error_events"], {"read": 1})
        self.assertEqual(len(result["failure_examples"]), 7)
        self.assertEqual(result["failure_examples"][2]["op"], "poll")

    def test_capped_query_splits_deduplicates_and_stays_bounded(self):
        calls = []
        def query(start, end):
            calls.append((start, end))
            if len(calls) == 1:
                return {"result": {"events": {"events": [], "count": 2001}}}
            return {"result": {"events": {"events": [{"$metadata": {"id": "boundary-row"}}], "count": 1},
                               "statistics": {"abr_level": 2}}}
        rows, coverage = watch.collect_events(query, 0, 10000, 3)
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(rows), 1)
        self.assertTrue(coverage["sampling_observed"])
        self.assertFalse(coverage["possibly_truncated"])
        _, capped = watch.collect_events(lambda _start, _end: {"events": {"events": [], "count": 2001}}, 0, 10000, 1)
        self.assertTrue(capped["possibly_truncated"])

    def test_health_poll_traffic_does_not_prove_analysis_or_count_cancellation_as_failure(self):
        result = watch.summarize([{"$workers": {"outcome": "canceled", "event": {"response": {"status": 200}}}}])
        self.assertFalse(result["analysis_traffic_observed"])
        self.assertEqual(result["http_response_event_counts"], {"200": 1})
        self.assertEqual(result["failure_examples"], [])

    def test_non_object_json_reads_as_empty_instead_of_crashing(self):
        rows = ["panic: plain console text", {"source": "plain console text", "$workers": ["unexpected"],
                "$metadata": None}, {"source": {"event": "ad_analysis_accounting", "accounting": "bad",
                "policy_revision": "revision-1"}, "$workers": {"event": "bad", "scriptVersion": 7}}]
        result = watch.summarize(rows)
        self.assertEqual(result["observed_log_rows"], 3)
        self.assertEqual(result["accounting_records"], 1)
        for payload in (None, "proxy error", [], {"result": None}, {"result": {"events": "bad"}}):
            with self.subTest(payload=payload), self.assertRaises(watch.ReadError):
                watch.collect_events(lambda _start, _end, payload=payload: payload, 0, 10000, 1)
        rows, _ = watch.collect_events(lambda _start, _end: {"events": {"events": ["text", {"source": {}}],
                                       "series": "bad"}, "statistics": None}, 0, 10000, 1)
        self.assertEqual(rows, [{"source": {}}])

    def test_non_object_health_body_is_reported_not_raised(self):
        original = watch.read_json
        def fake(url, **_):
            if url.endswith("/health"):
                return 200, ["not", "an", "object"]
            return 200, {"result": None}
        watch.read_json = fake
        try:
            report = watch.environment_snapshot("production", "worker", "https://example.com/health",
                                                "0" * 32, "token", 0, 10000, 1)
        finally:
            watch.read_json = original
        self.assertEqual(report["health"], {"status": 200, "message": "unknown", "policy_revision": "unknown"})
        self.assertEqual(report["telemetry"], {"error": "telemetry_shape_unrecognized"})


if __name__ == "__main__":
    unittest.main()

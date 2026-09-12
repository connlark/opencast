import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import staging_smoke
from budget import Ledger


class StagingSmokeTests(unittest.TestCase):
    def exercise(self, *, unknown=0, handle=None, revision="revision-b"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fingerprint = "f" * 64
            request = {"transcript": {"fingerprint": fingerprint}}
            (root / "request.json").write_text(json.dumps(request))
            (root / "token").write_text("local-test-token")
            ledger = Ledger(root / "budget-ledger.json", 25)
            previous = ledger.reserve("gemini-3.8-flash", 100, 100, {})
            ledger.finish(previous, "ambiguous")
            old_entry = ledger.snapshot()["entries"][0]
            accepted = {"state": "running", "job_id": handle or f"a3.20260911b.{fingerprint}"}
            result = {
                "policy": "promo_ad_breaks_v3", "model": "gemini-3.8-flash",
                "policy_revision": revision, "spans": [], "warnings": [],
                # Only the per-attempt receipt is sufficient to release a hold.
                "usage": {"prompt_token_count": 1},
                "accounting": {
                    "unknown_attempts": unknown, "reserved_input_tokens": 0,
                    "dispatched_attempts": 2,
                    "reported_usage": {"prompt_token_count": 1000,
                        "candidates_token_count": 100, "thoughts_token_count": 50,
                        "total_token_count": 1200},
                },
            }
            arguments = ["staging_smoke.py", "--url", "https://example-staging.workers.dev",
                "--staging-host", "example-staging.workers.dev", "--request", str(root / "request.json"),
                "--key-file", str(root / "token"), "--out", str(root), "--tag", "test",
                "--expected-revision", "revision-b", "--max-spend", "25"]
            error = None
            with patch("sys.argv", arguments), patch.object(staging_smoke, "bridge", return_value={
                "windows": [{"payload": {"text": "Local fixture"}}]
            }), patch.object(staging_smoke, "http", side_effect=[accepted, result, result]) as http, \
                    patch.object(staging_smoke.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
                try:
                    staging_smoke.main()
                except RuntimeError as caught:
                    error = caught
            entries = ledger.snapshot()["entries"]
            self.assertEqual(entries[0], old_entry)
            self.assertTrue(http.call_args_list[0].args[1]["async_supported"])
            self.assertEqual(http.call_args_list[0].args[1]["job_handle_version"], 1)
            return entries[-1], http.call_args_list, error

    def test_complete_receipt_settles_all_attempt_usage_and_polls_returned_handle(self):
        entry, calls, error = self.exercise()
        self.assertIsNone(error)
        self.assertEqual(entry["state"], "settled")
        self.assertEqual(entry["usage"], {"input": 1000, "output": 200, "cached": 0, "write": 0})
        self.assertTrue(calls[1].args[0].endswith("a3.20260911b." + "f" * 64))
        self.assertEqual(len(calls), 3)

    def test_missing_attempt_usage_keeps_entire_reservation(self):
        entry, _, error = self.exercise(unknown=1)
        self.assertIsNone(error)
        self.assertEqual(entry["state"], "ambiguous")
        self.assertNotIn("actual_usd", entry)

    def test_mismatched_handle_never_polls_and_keeps_reservation(self):
        entry, calls, error = self.exercise(handle="a3.20260911b." + "e" * 64)
        self.assertIsNotNone(error)
        self.assertEqual(entry["state"], "ambiguous")
        self.assertEqual(len(calls), 1)

    def test_wrong_serving_revision_fails_without_claiming_a_verified_smoke(self):
        entry, calls, error = self.exercise(revision="revision-a")
        self.assertIsNotNone(error)
        self.assertEqual(entry["state"], "ambiguous")
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()

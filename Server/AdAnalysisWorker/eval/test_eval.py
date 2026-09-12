import tempfile
import unittest
from pathlib import Path

from boundary_probe import review_input
from budget import BudgetExceeded, Ledger, MAX_AUTHORIZED_CAP
from run import answer_of, measure, usage_of


class BudgetTests(unittest.TestCase):
    def test_ambiguous_attempt_keeps_its_reservation(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Ledger(Path(tmp) / "ledger.json", 0.3)
            ident = ledger.reserve("gemini-3.5-flash", 10000, 16384, {})
            ledger.finish(ident, "ambiguous")
            with self.assertRaises(BudgetExceeded):
                ledger.reserve("gemini-3.5-flash", 10000, 16384, {})

    def test_settlement_and_shared_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ledger.json"
            first = Ledger(path, 15)
            ident = first.reserve("gpt-6-astra", 1000, 1000, {})
            second = Ledger(path, 15)
            self.assertAlmostEqual(second.snapshot()["totals"]["committed_usd"], 0.0625)
            second.finish(
                ident,
                "settled",
                {"input": 1000, "cached": 0, "write": 0, "output": 100},
            )
            self.assertAlmostEqual(first.snapshot()["totals"]["confirmed_usd"], 0.015)
            with self.assertRaises(ValueError):
                Ledger(path, 14)
            with self.assertRaises(ValueError):
                second.finish(ident, "released")

    def test_invalid_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            for cap in (0, -1, MAX_AUTHORIZED_CAP + 1, float("nan"), float("inf")):
                with self.assertRaises(ValueError):
                    Ledger(Path(tmp) / "unused.json", cap)

    def test_current_authorized_ceiling_is_accepted_without_resetting_spend(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Ledger(Path(tmp) / "ledger.json", 20)
            ident = ledger.reserve("gemini-3.8-flash", 1000, 1000, {})
            ledger.finish(ident, "ambiguous")
            before = ledger.snapshot()
            ledger.authorize_increase(25, "User authorized $25 total in chat")
            after = Ledger(ledger.path, 25).snapshot()
            self.assertEqual(before["entries"], after["entries"])
            self.assertEqual(after["cap_usd"], 25)
            self.assertEqual(before["totals"]["committed_usd"], after["totals"]["committed_usd"])

    def test_authorized_increase_preserves_every_entry_and_reservation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ledger.json"
            ledger = Ledger(path, 15)
            ident = ledger.reserve("gemini-3.8-flash", 1000, 1000, {})
            ledger.finish(ident, "ambiguous")
            before = ledger.snapshot()
            stale = Ledger(path, 15)
            ledger.authorize_increase(20, "User authorized $20 total in chat")
            after = Ledger(path, 20).snapshot()
            self.assertEqual(before["entries"], after["entries"])
            self.assertEqual(before["prices"], after["prices"])
            self.assertEqual(after["cap_authorizations"][0]["previous_cap_usd"], 15)
            self.assertAlmostEqual(
                before["totals"]["committed_usd"], after["totals"]["committed_usd"]
            )
            self.assertAlmostEqual(
                after["totals"]["remaining_usd"] - before["totals"]["remaining_usd"], 5
            )
            with self.assertRaises(ValueError):
                stale.reserve("gemini-3.8-flash", 1, 1, {})

    def test_cap_increase_rejects_missing_authority_or_active_calls(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Ledger(Path(tmp) / "ledger.json", 15)
            for cap, authority in [(20, ""), (MAX_AUTHORIZED_CAP + 1, "Authorized"), (14, "Authorized")]:
                with self.assertRaises(ValueError):
                    ledger.authorize_increase(cap, authority)
            ident = ledger.reserve("gemini-3.8-flash", 1, 1, {})
            with self.assertRaises(ValueError):
                ledger.authorize_increase(20, "Authorized")
            ledger.finish(ident, "released")
            ledger.authorize_increase(20, "Authorized")

    def test_provider_overrun_stops_even_a_new_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ledger.json"
            ledger = Ledger(path, 15)
            ident = ledger.reserve("gemini-3.8-flash", 1, 1, {})
            ledger.finish(
                ident, "settled", {"input": 10, "cached": 0, "write": 0, "output": 10}
            )
            with self.assertRaises(BudgetExceeded):
                Ledger(path, 15).reserve("gemini-3.8-flash", 1, 1, {})


class ResponseTests(unittest.TestCase):
    def test_truncated_valid_json_is_not_complete(self):
        response = {
            "candidates": [
                {
                    "finishReason": "MAX_TOKENS",
                    "content": {"parts": [{"text": '{"spans":[]}'}]},
                }
            ]
        }
        with self.assertRaises(ValueError):
            answer_of("gemini-3.8-flash", response)

    def test_thoughts_are_excluded_and_billed(self):
        response = {
            "candidates": [
                {
                    "finishReason": "STOP",
                    "content": {
                        "parts": [
                            {"thought": True, "text": "reasoning"},
                            {"text": '{"spans":[]}'},
                        ]
                    },
                }
            ],
            "usageMetadata": {
                "promptTokenCount": 30,
                "candidatesTokenCount": 10,
                "thoughtsTokenCount": 20,
            },
        }
        self.assertEqual(answer_of("gemini-3.8-flash", response), {"spans": []})
        self.assertEqual(usage_of("gemini-3.8-flash", response)["output"], 30)

    def test_metrics_use_ids_not_list_indices_and_confidence_floor(self):
        req = {
            "segments": [
                {"id": 100, "start": 0, "end": 10},
                {"id": 500, "start": 10, "end": 20},
            ]
        }
        spans = [
            {"start_time": 0, "end_time": 10, "confidence": 0.7},
            {"start_time": 10, "end_time": 20, "confidence": 0.9},
        ]
        score = measure(req, spans, {"pods": [[100, 100]], "negatives": [[500, 500]]})
        self.assertEqual(score["missed_ad_s"], 10)
        self.assertEqual(score["false_skip_s"], 10)
        self.assertEqual(score["negative_overlap_s"], 10)


class BoundaryProbeTests(unittest.TestCase):
    def test_scoped_ids_and_blinding_never_leak_labels_or_times(self):
        request = {
            "episode_title": "Episode",
            "podcast_title": "Show",
            "ground_truth": "secret scoring labels",
            "segments": [
                {"id": (i + 1) * 7, "start": i, "end": i + 1, "text": str(i)}
                for i in range(100)
            ],
        }
        proposal = [217, 637]  # array positions 30 and 90, not IDs-as-indexes
        visible = review_input(request, proposal, blind=False)
        blind = review_input(request, proposal, blind=True)
        self.assertEqual(visible.pop("proposal"), proposal)
        self.assertEqual(visible, blind)
        self.assertEqual(set(blind), {"episode", "podcast", "segments"})
        self.assertEqual(len(blind["segments"]), 71)
        self.assertTrue(all(set(s) == {"id", "text"} for s in blind["segments"]))
        self.assertNotIn(427, {s["id"] for s in blind["segments"]})

    def test_ambiguous_or_reversed_source_is_rejected_before_inference(self):
        request = {"segments": [{"id": 7, "text": "first"}, {"id": 14, "text": "last"}]}
        with self.assertRaises(ValueError):
            review_input(request, [14, 7], blind=True)
        request["segments"][1]["id"] = 7
        with self.assertRaises(ValueError):
            review_input(request, [7, 7], blind=True)


if __name__ == "__main__":
    unittest.main()

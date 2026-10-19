"""Lane A (2026-10 bakeoff) harness tests: prices, ledger, verify, adapters."""

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import budget
from budget import MAX_AUTHORIZED_CAP, PRICES, Ledger, cost_usd, rates, verify

EVAL = Path(__file__).resolve().parent
# sha256 of json.dumps(budget.price_snapshot(), sort_keys=True, separators=(",", ":")).
# A price edit must change this literal in the same commit (and reopen no ledger).
PRICE_SNAPSHOT_SHA256 = "0dda41479332b472f40c88d3eeb76323d8021b101e031bd64e586194102cc593"
DECISION_MODELS = {
    "@cf/cloudflare/clef",
    "@cf/cloudflare/clef-flash",
    "typesafe/jev",
    "pplx-decider-latest",
    "pplx-decider-flash-latest",
    "decisions/gpt-6-luna",
}
SEPTEMBER_PRICES = {
    "gemini-3.5-flash": [1.5, 0.15, 1.5, 9],
    "gemini-3.8-flash": [0.75, 0.075, 0.75, 3.75],
    "gpt-6-astra": [10, 1, 12.5, 50],
    "gpt-5.6-sol": [4, 0.4, 5, 20],
    "gpt-5.6-terra": [2, 0.2, 2.5, 12],
    "gpt-5.6-luna": [0.2, 0.02, 0.25, 1.2],
}


def usage(i, o, cached=0, write=0, reasoning=0):
    return {"input": i, "cached": cached, "write": write, "output": o, "reasoning": reasoning}


class PriceTableTests(unittest.TestCase):
    def test_price_snapshot_digest_is_pinned(self):
        dump = json.dumps(budget.price_snapshot(), sort_keys=True, separators=(",", ":"))
        self.assertEqual(hashlib.sha256(dump.encode()).hexdigest(), PRICE_SNAPSHOT_SHA256)

    def test_bakeoff_rows_and_conventions(self):
        self.assertEqual(MAX_AUTHORIZED_CAP, 50)
        self.assertEqual(len(PRICES), 22)
        for model in DECISION_MODELS:
            row = PRICES[model]
            self.assertEqual(row[3], 0, model)
            self.assertEqual(row[0], row[2], model)  # flat input
        self.assertEqual(PRICES["@cf/cloudflare/clef-flash"], (0.038, 0.038, 0.038, 0))
        self.assertEqual(PRICES["typesafe/jev"], (0.042, 0.0, 0.042, 0))
        self.assertEqual(rates("decisions/gpt-6-luna", 272_001)[0], 0.2)
        self.assertEqual(PRICES["claude-haiku-5-5"], (0.10, 0.01, 0.125, 0.50))
        self.assertEqual(PRICES["cf/anthropic/claude-haiku-5.5"], PRICES["claude-haiku-5-5"])
        self.assertEqual(PRICES["cf/openai/gpt-6-luna"], PRICES["gpt-6-luna"])
        self.assertEqual(PRICES["cf/google/gemini-3.8-flash"], PRICES["gemini-3.8-flash"])
        for model in ("@cf/google/gemma-4-26b-a4b-it", "@cf/qwen/qwen3-30b-a3b-fp8", "@cf/openai/gpt-oss-120b"):
            self.assertEqual(len(set(PRICES[model][:3])), 1, model)
        # September rows unchanged.
        for model, row in SEPTEMBER_PRICES.items():
            self.assertEqual(list(PRICES[model]), row)

    def test_haiku_tier_boundary(self):
        self.assertEqual(rates("claude-haiku-5-5", 100_000), (0.10, 0.01, 0.125, 0.50))
        self.assertEqual(rates("claude-haiku-5-5", 100_001), (0.50, 0.05, 0.625, 2.50))
        self.assertEqual(rates("cf/anthropic/claude-haiku-5.5", 100_001)[0], 0.50)
        self.assertAlmostEqual(cost_usd("claude-haiku-5-5", usage(100_000, 1000)), 0.0105)
        self.assertAlmostEqual(cost_usd("claude-haiku-5-5", usage(100_001, 1000)), 0.0525005)
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Ledger(Path(tmp) / "ledger.json", 15)
            low = ledger.reserve("claude-haiku-5-5", 100_000, 1000, {})
            high = ledger.reserve("claude-haiku-5-5", 100_001, 1000, {})
            entries = {e["id"]: e for e in ledger.snapshot()["entries"]}
            self.assertAlmostEqual(entries[low]["reserved_usd"], (100_000 * 0.125 + 1000 * 0.5) / 1e6)
            self.assertAlmostEqual(entries[high]["reserved_usd"], (100_001 * 0.625 + 1000 * 2.5) / 1e6)

    def test_openai_long_context_tier_unchanged(self):
        self.assertEqual(rates("gpt-5.6-luna", 272_000), (0.2, 0.02, 0.25, 1.2))
        self.assertEqual(rates("gpt-5.6-luna", 272_001)[:3], (0.4, 0.04, 0.5))
        self.assertAlmostEqual(rates("gpt-5.6-luna", 272_001)[3], 1.8)
        self.assertAlmostEqual(rates("gpt-6-luna", 272_001)[0], 0.2)

    def test_gemini_3_guard_covers_every_gemini_3_key(self):
        import datetime

        original = budget.GEMINI_3_PRICE_EXPIRY
        budget.GEMINI_3_PRICE_EXPIRY = datetime.date(2026, 1, 1)
        try:
            for model in ("gemini-3.8-flash", "gemini-3.5-flash", "gemini-3.1-flash-lite", "cf/google/gemini-3.8-flash"):
                with self.assertRaises(ValueError, msg=model):
                    rates(model, 1)
            rates("gemini-2.5-flash-lite", 1)
            rates("gpt-6-luna", 1)
        finally:
            budget.GEMINI_3_PRICE_EXPIRY = original

    def test_decision_reservation_with_one_output_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Ledger(Path(tmp) / "ledger.json", 15)
            ident = ledger.reserve("pplx-decider-latest", 10_000, 1, {"q": 2})
            entry = ledger.snapshot()["entries"][0]
            self.assertAlmostEqual(entry["reserved_usd"], 10_000 * 0.02 / 1e6)
            ledger.finish(ident, "settled", usage(9_000, 3))
            entry = ledger.snapshot()["entries"][0]
            self.assertAlmostEqual(entry["actual_usd"], 9_000 * 0.02 / 1e6)
            self.assertNotIn("reservation_exceeded", entry)


class LedgerCapTests(unittest.TestCase):
    def test_raise_15_to_50_accepted_51_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ledger.json"
            ledger = Ledger(path, 15)
            ident = ledger.reserve("gpt-6-luna", 1000, 1000, {})
            ledger.finish(ident, "settled", usage(1000, 100))
            with self.assertRaises(ValueError):
                ledger.authorize_increase(51, "Connor authorized $51")
            ledger.authorize_increase(50, "Connor authorized $50 total for the 2026-10 ad-analysis bakeoff")
            after = Ledger(path, 50).snapshot()
            self.assertEqual(after["cap_usd"], 50)
            self.assertEqual(after["cap_authorizations"][0]["previous_cap_usd"], 15)
            self.assertEqual(len(after["entries"]), 1)
            with self.assertRaises(ValueError):
                Ledger(path, 15)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                Ledger(Path(tmp) / "fresh.json", 51)
            Ledger(Path(tmp) / "fresh.json", 50)

    def test_cli_cap_raise(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ledger.json"
            Ledger(path, 15)
            cli = [sys.executable, str(EVAL / "budget.py"), "--ledger", str(path), "--previous-cap", "15"]
            refused = subprocess.run(cli + ["--new-cap", "51", "--authorization", "x"], capture_output=True)
            self.assertNotEqual(refused.returncode, 0)
            done = subprocess.run(
                cli + ["--new-cap", "50", "--authorization", "Connor authorized $50"],
                capture_output=True, text=True,
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(json.loads(done.stdout)["remaining_usd"], 50)

    def test_september_price_snapshot_refuses_to_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ledger.json"
            path.write_text(json.dumps({"cap_usd": 15, "prices": SEPTEMBER_PRICES, "entries": []}))
            with self.assertRaises(ValueError):
                Ledger(path, 15)
            # Current prices without the tier snapshot (a pre-tier ledger) refuse too.
            path.write_text(json.dumps({"cap_usd": 15, "prices": budget.price_snapshot()["prices"], "entries": []}))
            with self.assertRaises(ValueError):
                Ledger(path, 15)


def write_summary(path, model, calls, cost=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    total = sum(cost_usd(c.get("model", model), c["usage"]) for c in calls if c.get("usage"))
    path.write_text(json.dumps({"model": model, "calls": calls, "cost_usd": round(total if cost is None else cost, 9)}))


class VerifyTests(unittest.TestCase):
    def build(self, tmp):
        ledger = Ledger(Path(tmp) / "ledger" / "budget-ledger.json", 15)
        runs = Path(tmp) / "runs"
        decision = Path(tmp) / "decision"
        calls = []
        for model, u in (("gpt-6-luna", usage(2000, 300, cached=500)), ("claude-haiku-5-5", usage(1500, 200, write=100))):
            ident = ledger.reserve(model, u["input"], 1000, {})
            ledger.finish(ident, "settled", u)
            calls.append((model, {"reservation": ident, "usage": u}))
        write_summary(runs / "probe-a" / "f-1" / "summary.json", "gpt-6-luna", [calls[0][1]])
        write_summary(runs / "probe-b" / "f-1" / "summary.json", "claude-haiku-5-5", [calls[1][1]])
        ident = ledger.reserve("pplx-decider-latest", 4000, 1, {})
        u = usage(4000, 2)
        ledger.finish(ident, "settled", u)
        inner = {"reservation": ident, "usage": u, "model": "pplx-decider-latest"}
        write_summary(decision / "t" / "ask-0" / "summary.json", "pplx-decider-latest", [inner])
        # A pipeline summary nesting the same call is not double counted.
        write_summary(decision / "t" / "summary.json", "pipeline", [inner])
        released = ledger.reserve("gpt-6-luna", 10, 10, {})
        ledger.finish(released, "released", error="400")
        return ledger, [runs, decision]

    def test_agrees_then_disagrees_after_an_edit(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger, roots = self.build(tmp)
            report, ok = verify(ledger.path, roots)
            self.assertTrue(ok, json.dumps(report, indent=1))
            self.assertEqual(report["summaries_with_calls"], 4)
            self.assertEqual(report["unarchived_settled_reservations"], [])
            self.assertAlmostEqual(report["archived_usd"], report["ledger_settled_usd"])
            # Edited cost_usd: internal mismatch.
            path = roots[0] / "probe-a" / "f-1" / "summary.json"
            doc = json.loads(path.read_text())
            doc["cost_usd"] = 0.5
            path.write_text(json.dumps(doc))
            report, ok = verify(ledger.path, roots)
            self.assertFalse(ok)
            self.assertEqual(len(report["summary_issues"]), 1)
            # Edited usage (cost recomputed to match): disagrees with the ledger.
            doc["calls"][0]["usage"]["output"] = 50_000
            write_summary(path, "gpt-6-luna", doc["calls"])
            report, ok = verify(ledger.path, roots)
            self.assertFalse(ok)
            self.assertFalse(report["per_model"]["gpt-6-luna"]["agrees"])
            self.assertTrue(report["per_model"]["claude-haiku-5-5"]["agrees"])

    def test_missing_summary_and_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger, roots = self.build(tmp)
            cli = [sys.executable, str(EVAL / "budget.py"), "--verify", "--ledger", str(ledger.path), "--roots", *map(str, roots)]
            self.assertEqual(subprocess.run(cli, capture_output=True).returncode, 0)
            (roots[0] / "probe-b" / "f-1" / "summary.json").unlink()
            # Haiku's call is now unarchived but costs < 1 cent: per-model usage still disagrees.
            result = subprocess.run(cli, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            report = json.loads(result.stdout)
            self.assertEqual(len(report["unarchived_settled_reservations"]), 1)


if __name__ == "__main__":
    unittest.main()

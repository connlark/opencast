"""Decision rows price input only: a reservation with max_output = 1 costs
input tokens x the input rate and nothing for output (Lane A's budget.py)."""

import tempfile
import unittest
from pathlib import Path

from decision.common import lane_a

budget = lane_a("budget")
DECISION_ROWS = ("pplx-decider-latest", "pplx-decider-flash-latest", "typesafe/jev", "@cf/cloudflare/clef", "decisions/gpt-6-luna")
PRESENT = [m for m in DECISION_ROWS if m in budget.PRICES]


@unittest.skipUnless(PRESENT, "budget.PRICES has no decision-model rows yet")
class DecisionLedgerTests(unittest.TestCase):
    def test_input_only_reservation_and_settlement(self):
        for model in PRESENT:
            with self.subTest(model=model), tempfile.TemporaryDirectory() as tmp:
                price = budget.rates(model, 10_000)
                self.assertEqual(price[3], 0, "decision rows bill no output")
                ledger = budget.Ledger(Path(tmp) / "ledger.json", 1.0)
                ident = ledger.reserve(model, 10_000, 1, {"test": True})
                entry = ledger.snapshot()["entries"][0]
                self.assertAlmostEqual(entry["reserved_usd"], 10_000 * max(price[:3]) / 1_000_000)
                ledger.finish(ident, "settled", usage={"input": 9_000, "cached": 0, "write": 0, "output": 1})
                entry = ledger.snapshot()["entries"][0]
                self.assertAlmostEqual(entry["actual_usd"], 9_000 * price[0] / 1_000_000)
                self.assertNotIn("reservation_exceeded", entry)


if __name__ == "__main__":
    unittest.main()

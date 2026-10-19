"""Answer normalisation against recorded minimal responses (shapes verbatim
from the vendor docs in ROOT/smoke/docs-digest.md, values shortened)."""

import importlib
import unittest

from decision.common import lane_a_available
from decision.questions import CHOICES

OPTION_IDS = {c["id"]: c["description"] for c in CHOICES}
from decision.run_decision import AnswerError, normalize

NOUL = {"id": "c0_ad", "type": "noul", "instructions": "q"}
CHOICE = {"id": "c0_kind", "type": "choice", "instructions": "q", "criteria": OPTION_IDS}
OPTIONS = {"ad_read": 0.6, "inserted_ad": 0.1, "promo": 0.1, "content": 0.15, "transition": 0.05}

# Perplexity / Clef / Jev share the System One answer map.
PPLX = {
    "model": "pplx-decider-latest",
    "answers": {
        "c0_ad": {"type": "noul", "noul": 0.9424522889347015},
        "c0_kind": {"type": "choice", "choice": "ad_read", "confidence": 0.9, "probabilities": OPTIONS},
    },
    "usage": {"input_tokens": 367, "output_tokens": 2},
}
CLEF = {"success": True, "errors": [], "messages": [], "result": {"model": "clef", **{k: PPLX[k] for k in ("answers", "usage")}}}
JEV = {"model": "jev-1.13.0", **{k: PPLX[k] for k in ("answers", "usage")}}
OPENAI = {
    "answers": [
        {"type": "predicate", "name": "c0_ad", "probability": 0.9424522889347015},
        {"type": "choice", "name": "c0_kind", "choice": "ad_read",
         "probabilities": [{"value": k, "probability": v} for k, v in OPTIONS.items()], "confidence": 0.9},
    ],
    "usage": {"input_tokens": 447, "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0}, "output_tokens": 0},
}


class NormalizeTests(unittest.TestCase):
    def expected(self):
        return {"c0_ad": 0.9424522889347015, "c0_kind": OPTIONS}

    def check(self, answers):
        out = normalize([NOUL, CHOICE], answers)
        self.assertAlmostEqual(out["c0_ad"], self.expected()["c0_ad"])
        for k, v in OPTIONS.items():
            self.assertAlmostEqual(out["c0_kind"][k], v)

    def test_raw_vendor_answer_shapes_normalise_identically(self):
        self.check(PPLX["answers"])
        self.check(CLEF["result"]["answers"])
        self.check(JEV["answers"])
        self.check(OPENAI["answers"])

    def test_unwrapped_lane_a_shape(self):
        self.check({"c0_ad": 0.9424522889347015, "c0_kind": OPTIONS})

    def test_saturated_and_unnormalised(self):
        out = normalize([NOUL, CHOICE], {"c0_ad": 1.0, "c0_kind": {"content": 2.0, "promo": 2.0}})
        self.assertEqual(out["c0_ad"], 1.0)
        self.assertEqual(out["c0_kind"]["content"], 0.5)
        self.assertEqual(normalize([NOUL], {"c0_ad": 0})["c0_ad"], 0.0)

    def test_failures_fail_closed(self):
        for answers in (
            {},
            {"c0_ad": 1.2},
            {"c0_ad": True},
            {"c0_ad": float("nan")},
            {"c0_ad": {"type": "refusal", "refusal": "no"}},
            [{"type": "refusal", "name": "c0_ad"}],
        ):
            with self.assertRaises(AnswerError):
                normalize([NOUL], answers)
        with self.assertRaises(AnswerError):
            normalize([CHOICE], {"c0_kind": {"content": 0.0}})
        with self.assertRaises(AnswerError):
            normalize([CHOICE], {"c0_kind": {"bogus": 1.0}})


@unittest.skipUnless(lane_a_available("providers.systemone"), "providers.systemone is not present yet; re-run once it lands")
class LaneAEnvelopeTests(unittest.TestCase):
    """Lane A's per-answer `systemone.probability` over each vendor's raw answers
    must normalise to the same {qid: p} as the raw answers do here."""

    def test_envelopes(self):
        probability = importlib.import_module("providers.systemone").probability
        for vendor, answers in (
            ("perplexity", PPLX["answers"]),
            ("cloudflare", CLEF["result"]["answers"]),
            ("typesafe", JEV["answers"]),
            ("openai", {a["name"]: a for a in OPENAI["answers"]}),
        ):
            with self.subTest(vendor=vendor):
                unwrapped = {qid: probability(raw) for qid, raw in answers.items()}
                self.check_same(normalize([NOUL, CHOICE], unwrapped))
        self.assertIsNone(probability({"type": "refusal"}))
        with self.assertRaises(AnswerError):
            normalize([NOUL], {"c0_ad": probability({"type": "refusal"})})

    def test_canonical_questions_build_for_every_decision_vendor(self):
        from decision import chunking, questions
        from decision.fakes import request

        build = importlib.import_module("providers.systemone").build_decision_request
        req = request([5.0] * 400)
        chunks = chunking.make(req["segments"], {"kind": "segments", "size": 4})
        for design in ("b_prime", "c"):
            qs = questions.chunk_questions(chunks, design)
            state = questions.render_state(req, chunks)
            for model in ("pplx-decider-latest", "@cf/cloudflare/clef", "typesafe/jev", "decisions/gpt-6-luna"):
                with self.subTest(design=design, model=model):
                    pages = build(state, model, qs)
                    asked = [q["id"] for page in pages for q in page["questions"]]
                    self.assertEqual(asked, [q["id"] for q in qs])
                    self.assertTrue(all(len(page["questions"]) <= 128 for page in pages))

    def check_same(self, out):
        self.assertAlmostEqual(out["c0_ad"], 0.9424522889347015)
        for k, v in OPTIONS.items():
            self.assertAlmostEqual(out["c0_kind"][k], v)


if __name__ == "__main__":
    unittest.main()

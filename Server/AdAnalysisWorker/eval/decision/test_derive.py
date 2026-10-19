import unittest

from decision import chunking
from decision.derive import PREREGISTERED, DeriveParams, derive, filter_runs, find_runs, median_filter, refine_run
from decision.fakes import request

P = DeriveParams()
# Frozen before the first paid wave; a change here must be a deliberate re-freeze.
FROZEN_SHA256 = "f9d6c05d57fbc5ffdb2a75d082b4681f2d1b96a14066c73f53a9069f7f0e9bc5"


def doc_of(pairs):
    return {"chunks": [{"p_ad": a, "p_content": c} for a, c in pairs], "refine": {}, "confirm": {}}


def runs(pairs, params=P):
    return [(r["first"], r["last"], r["bridged"]) for r in find_runs([(a, c, None) for a, c in pairs], params)]


class HysteresisTests(unittest.TestCase):
    def test_enter_needs_t_on_and_content_facet(self):
        self.assertEqual(runs([(0.85, 0.4)]), [])
        self.assertEqual(runs([(0.79, 0.0)]), [])
        self.assertEqual(runs([(0.80, 0.30)]), [(0, 0, [])])

    def test_stay_until_t_off_or_content_objects(self):
        self.assertEqual(runs([(0.9, 0.1), (0.6, 0.3), (0.5, 0.5), (0.45, 0.6), (0.9, 0.1)]), [(0, 2, []), (4, 4, [])])
        self.assertEqual(runs([(0.9, 0.1), (0.7, 0.55), (0.9, 0.1)]), [(0, 0, []), (2, 2, [])])

    def test_bridge_exactly_one_never_two(self):
        self.assertEqual(runs([(0.9, 0.1), (0.3, 0.4), (0.9, 0.1)]), [(0, 2, [1])])
        self.assertEqual(runs([(0.9, 0.1), (0.3, 0.4), (0.3, 0.4), (0.9, 0.1)]), [(0, 0, []), (3, 3, [])])
        self.assertEqual(runs([(0.9, 0.1), (0.2, 0.4), (0.9, 0.1)]), [(0, 0, []), (2, 2, [])])
        self.assertEqual(runs([(0.9, 0.1), (0.3, 0.6), (0.9, 0.1)]), [(0, 0, []), (2, 2, [])])
        self.assertEqual(runs([(0.9, 0.1), (0.3, 0.4)]), [(0, 0, [])])

    def test_saturated_answers(self):
        self.assertEqual(runs([(0.0, 1.0), (1.0, 0.0), (1.0, 0.0), (0.0, 1.0)]), [(1, 2, [])])

    def test_single_chunk_and_min_run_filters(self):
        chunks = chunking.make(request([10.0] * 6)["segments"], {"kind": "segments", "size": 1})
        probs = [(0.85, 0.1, None), (0.0, 1.0, None), (0.95, 0.0, None), (0.0, 1.0, None), (0.9, 0.0, None), (0.9, 0.0, None)]
        kept, dropped = filter_runs(find_runs(probs, P), chunks, probs, PREREGISTERED)
        self.assertEqual([(r["first"], r["last"]) for r in kept], [(4, 5)])
        self.assertEqual({(r["first"], r["reason"]) for r in dropped}, {(0, "single_chunk_below_min_p"), (2, "shorter_than_min_run")})
        kept, _ = filter_runs(find_runs(probs, P), chunks, probs, P)
        self.assertEqual([(r["first"], r["last"]) for r in kept], [(2, 2), (4, 5)])
        short = chunking.make(request([4.0, 30.0])["segments"], {"kind": "segments", "size": 1})
        probs = [(0.95, 0.0, None), (0.0, 1.0, None)]
        kept, dropped = filter_runs(find_runs(probs, P), short, probs, P)
        self.assertEqual((kept, dropped[0]["reason"]), ([], "shorter_than_min_run"))


class SpanTests(unittest.TestCase):
    def setUp(self):
        self.req = request([10.0] * 50)
        self.chunks = chunking.make(self.req["segments"], {"kind": "segments", "size": 10})

    def test_confidence_is_min_over_non_bridged_and_quotes_are_never_fabricated(self):
        doc = doc_of([(0.0, 1.0), (0.95, 0.05), (0.3, 0.4), (0.85, 0.1), (0.0, 1.0)])
        out = derive(self.req, self.chunks, doc, "b_prime", P)
        self.assertTrue(out["validation"]["complete"])
        [span] = out["validation"]["spans"]
        self.assertEqual(span["confidence"], 0.85)
        self.assertEqual((span["start_segment_id"], span["end_segment_id"]), (107, 397))
        self.assertEqual(span["evidence_quote"], "")
        self.assertIsNone(span["start_boundary"])
        self.assertEqual(span["decision"]["bridged_chunks"], [2])
        self.assertEqual(span["decision"]["confidence_mean"], 0.9)

    def test_one_doubtful_chunk_drags_under_floor(self):
        out = derive(self.req, self.chunks, doc_of([(0.95, 0.0), (0.6, 0.3), (0.95, 0.0), (0, 1), (0, 1)]), "b_prime", P)
        self.assertEqual(out["validation"]["spans"][0]["confidence"], 0.6)

    def test_guard_violation_fails_episode_closed(self):
        req = request([20.0] * 50)
        chunks = chunking.make(req["segments"], {"kind": "segments", "size": 10})
        out = derive(req, chunks, doc_of([(0.95, 0.0)] * 4 + [(0.0, 1.0)]), "b_prime", P)
        self.assertFalse(out["validation"]["complete"])
        self.assertEqual(out["validation"]["spans"], [])
        self.assertTrue(any(w.startswith("decision_break_duration") for w in out["validation"]["warnings"]))
        self.assertEqual(len(out["raw_spans"]), 1)

    def test_choice_design_derives_ad_from_content_and_gated_transition(self):
        def ch(promo, content, transition):
            return {"choice": {"ad_read": promo, "inserted_ad": 0.0, "promo": 0.0, "content": content, "transition": transition}}
        alone = {"chunks": [ch(0.0, 1.0, 0.0), ch(0.05, 0.05, 0.9), ch(0.0, 1.0, 0.0), ch(0, 1, 0), ch(0, 1, 0)]}
        self.assertEqual(derive(self.req, self.chunks, alone, "c", P)["runs"], [])
        beside = {"chunks": [ch(0.9, 0.1, 0.0), ch(0.05, 0.05, 0.9), ch(0.0, 1.0, 0.0), ch(0, 1, 0), ch(0, 1, 0)]}
        out = derive(self.req, self.chunks, beside, "c", P)
        self.assertEqual([(r["first"], r["last"]) for r in out["runs"]], [(0, 1)])
        self.assertEqual(out["validation"]["spans"][0]["kind"], "host_read_ad")


class RefineTests(unittest.TestCase):
    def setUp(self):
        self.req = request([5.0] * 60)
        self.segs = self.req["segments"]
        self.chunks = chunking.make(self.segs, {"kind": "segments", "size": 10})
        self.run = {"first": 2, "last": 3, "bridged": []}

    def test_median_filter(self):
        self.assertEqual(median_filter([0, 1, 0, 1, 1], 3), [0, 0, 1, 1, 1])
        self.assertEqual(median_filter([0.2, 0.9], 1), [0.2, 0.9])

    def test_boundaries_from_segment_evidence(self):
        p = {i: (1.0 if 23 <= i <= 37 else 0.0) for i in range(10, 50)}
        p[30] = 0.0  # an isolated dip inside the break is filtered out
        start, end, notes = refine_run(self.run, self.chunks, self.segs, p, P)
        self.assertEqual((start, end), (23, 37))

    def test_spike_survives_through_raw_fallback(self):
        p = {i: 0.0 for i in range(10, 50)}
        p[25] = 0.95
        start, end, notes = refine_run(self.run, self.chunks, self.segs, p, P)
        self.assertEqual((start, end, "median_fallback_raw" in notes), (25, 25, True))

    def test_mixed_boundary_rule(self):
        p = {i: (1.0 if 23 <= i <= 37 else 0.0) for i in range(10, 50)}
        p[22] = 0.6  # first passing after the median, raw p < t_on: a mixed boundary
        for length, expected, note in ((12.0, 23, "mixed_start_trimmed"), (5.0, 22, "short_mixed_start_included")):
            req = request([5.0] * 22 + [length] + [5.0] * 37)
            chunks = chunking.make(req["segments"], {"kind": "segments", "size": 10})
            start, _, notes = refine_run(self.run, chunks, req["segments"], p, P)
            self.assertEqual((start, note in notes), (expected, True))

    def test_confirmation_gate_and_missing_inference(self):
        doc = doc_of([(0, 1), (0, 1), (0.95, 0.0), (0.95, 0.0), (0, 1), (0, 1)])
        doc["refine"] = {str(i): (1.0 if 20 <= i <= 39 else 0.0) for i in range(10, 50)}
        doc["confirm"] = {"20-39": 0.7}
        out = derive(self.req, self.chunks, doc, "d", P)
        self.assertEqual(out["validation"]["spans"], [])
        self.assertEqual(out["rejected_runs"][0]["reason"], "confirm_below_min_p")
        doc["confirm"] = {"20-39": 0.92}
        [span] = derive(self.req, self.chunks, doc, "d", P)["validation"]["spans"]
        self.assertEqual((span["confidence"], span["decision"]["confirm_p"]), (0.92, 0.92))
        doc["refine"], doc["confirm"] = {}, {}
        out = derive(self.req, self.chunks, doc, "d", P)
        self.assertEqual(out["rejected_runs"][0]["reason"], "no_confidence")
        self.assertIn("refine_missing", out["rejected_runs"][0].get("reason", "") + str(out["validation"]["notices"]))

    def test_params_hash_changes_with_any_threshold(self):
        self.assertNotEqual(P.sha256(), P.with_(min_run_s=15.0).sha256())
        self.assertEqual(DeriveParams.from_dict({**P.as_dict(), "sha256": "x"}), P)

    def test_frozen_params(self):
        self.assertEqual((P.min_run_s, P.refine_threshold, P.t_on, P.t_off), (5.0, 0.51, 0.80, 0.50))
        self.assertEqual(P.sha256(), FROZEN_SHA256)
        self.assertEqual(P.with_(min_run_s=5).sha256(), FROZEN_SHA256)  # JSON int vs float
        self.assertEqual(PREREGISTERED.sha256(), "5b03815098ac57e76d53a380c0a74565f761936c0bbddaea0abf1139f36e5cd7")

    def test_archive_flags_fallback_and_both_confidence_definitions(self):
        doc = doc_of([(0, 1), (0, 1), (0.95, 0.0), (0.95, 0.0), (0, 1), (0, 1)])
        doc["refine"] = {str(i): 0.0 for i in range(10, 50)}
        doc["refine"]["25"] = 0.95
        doc["refine"]["34"] = 0.95
        doc["confirm"] = {"25-34": 0.9}
        out = derive(self.req, self.chunks, doc, "d", P)
        self.assertEqual(out["median_fallback_raw_fired"], [[2, 3]])
        [span] = out["validation"]["spans"]
        self.assertEqual((span["confidence"], span["decision"]["confidence_min_all"]), (0.9, 0.95))
        self.assertIn("confidence_p10", span["decision"])
        self.assertIn("installed", out["confidence_definitions"])


if __name__ == "__main__":
    unittest.main()

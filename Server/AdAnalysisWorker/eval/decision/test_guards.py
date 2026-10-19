"""Guard constants pinned to the frozen Rust sources (read-only regex)."""

import re
import unittest

from decision import guards
from decision.common import SRC
from decision.fakes import request


def const(source, name):
    match = re.search(rf"pub const {name}: f64 = ([0-9_.]+);", source)
    if not match:
        raise AssertionError(f"{name} not found")
    return float(match.group(1).replace("_", ""))


class GuardDriftTests(unittest.TestCase):
    def test_constants_match_rust(self):
        promo = (SRC / "promo_v3.rs").read_text()
        validation = (SRC / "validation.rs").read_text()
        self.assertEqual(const(promo, "MAX_BREAK_SECONDS"), guards.MAX_BREAK_SECONDS)
        self.assertEqual(const(promo, "MAX_MIXED_BOUNDARY_SECONDS"), guards.MAX_MIXED_BOUNDARY_SECONDS)
        self.assertEqual(const(validation, "MAX_SPAN_DURATION_SECONDS"), guards.MAX_BREAK_SECONDS)
        self.assertEqual(const(validation, "MAX_SPAN_REQUEST_COVERAGE"), guards.MAX_SPAN_REQUEST_COVERAGE)
        self.assertEqual(const(validation, "AD_BUDGET_EPISODE_FRACTION"), guards.AD_BUDGET_EPISODE_FRACTION)
        self.assertEqual(const(validation, "AD_BUDGET_FLOOR_SECONDS"), guards.AD_BUDGET_FLOOR_SECONDS)
        self.assertEqual(const(validation, "DECLARED_DURATION_MIN_FRACTION"), guards.DECLARED_DURATION_MIN_FRACTION)
        covers = re.findall(r"request\.segments\.len\(\) as f64 \* ([0-9.]+)", promo)
        self.assertGreaterEqual(len(covers), 2)
        self.assertEqual({float(x) for x in covers}, {guards.COVERS_REQUEST_FRACTION})
        tier = re.findall(r"span\.confidence >= ([0-9.]+)\)\]", promo)
        self.assertEqual([float(x) for x in tier], [guards.CONFIDENCE_TIER])
        self.assertIn("fn episode_ad_budget_seconds", validation)
        self.assertIn("base(declared) + (audio - declared)", validation)


class GuardBehaviourTests(unittest.TestCase):
    def test_budget_port(self):
        self.assertEqual(guards.episode_ad_budget_seconds({"audio_duration": 1000}), 600.0)
        self.assertEqual(guards.episode_ad_budget_seconds({"audio_duration": 3600}), 1440.0)
        self.assertEqual(guards.episode_ad_budget_seconds({"audio_duration": 3600, "declared_duration": 3000}), 1800.0)
        self.assertEqual(guards.episode_ad_budget_seconds({"audio_duration": 3600, "declared_duration": 1000}), 1440.0)
        self.assertEqual(guards.episode_ad_budget_seconds({"audio_duration": 3600, "declared_duration": 4000}), 1440.0)

    def span(self, req, a, b):
        segs = req["segments"]
        return {"start_segment_id": segs[a]["id"], "end_segment_id": segs[b]["id"],
                "start_time": segs[a]["start"], "end_time": segs[b]["end"], "confidence": 0.9}

    def test_violations(self):
        req = request([10.0] * 100)
        pos = {s["id"]: i for i, s in enumerate(req["segments"])}
        self.assertTrue(guards.check(req, [self.span(req, 0, 9)], pos)["ok"])
        self.assertIn("decision_break_duration:7-617", guards.check(req, [self.span(req, 0, 61)], pos)["warnings"])
        small = request([1.0] * 10)
        pos_small = {s["id"]: i for i, s in enumerate(small["segments"])}
        self.assertTrue(any(w.startswith("decision_covers_request") for w in guards.check(small, [self.span(small, 0, 8)], pos_small)["warnings"]))
        long_req = request([10.0] * 100, audio=1000.0)
        spans = [self.span(long_req, 0, 39), self.span(long_req, 50, 89)]
        self.assertIn("decision_ad_budget_exceeded", guards.check(long_req, spans, pos)["warnings"])


if __name__ == "__main__":
    unittest.main()

"""End to end on synthetic fixtures with sparse ids, offline (stub answers)."""

import json
import tempfile
import unittest
from pathlib import Path

from decision import frontier, hybrid, jitter, rederive, run_decision
from decision.chunking import make
from decision.common import lane_a, load_manifest, read
from decision.derive import DeriveParams
from decision.fakes import manifest, request

TRUTH = {"pods": [[107, 167], [407, 437]], "optional": [[97, 97]], "negatives": [[257, 307]]}


def fixture():
    durations = [6.4] * 50
    texts = [f"show talk number {i} about boats and wood" for i in range(50)]
    for i in range(10, 17):
        texts[i] = f"this episode is brought to you by harborsafe insurance part {i} visit the site"
    return request(durations, ids=[7 + 10 * i for i in range(50)], texts=texts)


class StubPipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.manifest = manifest(self.root / "fixtures", [("fake-show", fixture(), TRUTH)])

    def tearDown(self):
        self.tmp.cleanup()

    def run_stub(self, tag, design="d", chunking="sec30", repeats=1, extra=()):
        run_decision.main(["--manifest", str(self.manifest), "--out", str(self.root / "decision"), "--model", "oracle",
                           "--stub", "oracle", "--design", design, "--chunking", chunking, "--tag", tag,
                           "--repeats", str(repeats), *extra])
        return self.root / "decision" / tag

    def test_archive_shape_and_summary(self):
        tag = self.run_stub("dry", repeats=2)
        run = tag / "fake-show-1"
        names = sorted(p.name for p in run.iterdir())
        self.assertIn("decision-w0", names)
        self.assertTrue(any(n.startswith("refine-t") for n in names))
        self.assertTrue(any(n.startswith("confirm-s") for n in names))
        self.assertFalse(any(n.startswith(("window-", "repair-")) for n in names))
        for name in ("fixture.json", "probabilities.json", "derivation.json", "summary.json"):
            self.assertIn(name, names)
        s = read(run / "summary.json")
        for key in ("model", "policy", "design", "question_set", "chunking", "derive_params", "validation", "guards",
                    "metrics", "calls", "elapsed_s", "requests_total", "input_tokens_total", "cost_usd", "latency", "error"):
            self.assertIn(key, s)
        self.assertEqual((s["model"], s["policy"], s["cost_usd"], s["error"]), ("stub:oracle", "decision_ad_breaks_v4_proto", 0.0, None))
        self.assertTrue(all(set(c["usage"]) == {"input", "cached", "write", "output", "reasoning"} for c in s["calls"]))
        self.assertTrue(s["validation"]["complete"])
        self.assertEqual([round(p["coverage"], 3) for p in s["metrics"]["pods"]], [1.0, 1.0])
        self.assertEqual(s["metrics"]["false_skip_s"], 0)
        for span in s["validation"]["spans"]:
            self.assertEqual(span["evidence_quote"], "")
            self.assertIn("decision", span)
        fx = read(run / "fixture.json")
        self.assertEqual(fx["derive_params_sha256"], DeriveParams().sha256())
        self.assertEqual(fx["request_sha256"], load_manifest(self.manifest)["fake-show"][0]["request_sha256"])
        with self.assertRaises(RuntimeError):
            self.run_stub("dry")

        out = self.root / "decision" / "rederived"
        rederive.main(["--manifest", str(self.manifest), "--runs", str(tag), "--out", str(out)])
        again = read(out / "fake-show-1" / "summary.json")
        self.assertEqual(again["validation"], s["validation"])
        self.assertEqual((again["calls"], again["rederive_gaps"]), ([], 0))
        out2 = self.root / "decision" / "rederived-strict"
        rederive.main(["--manifest", str(self.manifest), "--runs", str(tag), "--out", str(out2), "--derive-params", '{"t_on": 0.99}'])
        self.assertEqual(read(out2 / "fake-show-1" / "summary.json")["derive_params"]["t_on"], 0.99)

        jitter.main(["--manifest", str(self.manifest), "--runs", str(tag)])
        j = read(tag / "jitter.json")["fake-show"]
        self.assertEqual((j["max_abs_delta_p_pod"], j["zone_sets_identical"], j["boundary_drift_s"]), (0.0, True, 0.0))
        rows = []
        frontier.main(["--manifest", str(self.manifest), "--runs", f"dry={tag}", "--out", str(self.root / "FRONTIER.md")])
        rows = read(self.root / "FRONTIER.json")
        self.assertEqual((rows[0]["fallback_rate"], rows[0]["whole_pod_misses"], rows[0]["max_pod_jitter"]), (0.0, 0, 0.0))
        self.assertEqual(rows[0]["disqualifiers"], [])

    def test_median_of_three_and_saturation(self):
        docs = [{"chunks": [{"p_ad": p, "p_content": 1 - p}], "refine": {"3": p}, "confirm": {}} for p in (0.0, 1.0, 1.0)]
        median = jitter.median_of(docs)
        self.assertEqual((median["chunks"][0]["p_ad"], median["refine"]["3"]), (1.0, 1.0))

    def test_paid_path_refuses_to_create_a_ledger(self):
        with self.assertRaises(SystemExit):
            run_decision.main(["--manifest", str(self.manifest), "--out", str(self.root / "decision"), "--model",
                               "pplx-decider-latest", "--design", "b_prime", "--tag", "x", "--key-file", str(self.manifest),
                               "--ledger", str(self.root / "absent-ledger.json"), "--max-spend", "1"])
        self.assertFalse((self.root / "absent-ledger.json").exists())

    def test_windows_fit_small_contexts(self):
        req = request([6.4] * 600)
        chunks = make(req["segments"], {"kind": "segments", "size": 10})
        windows = run_decision.plan_windows(req, chunks, "b_prime", "w1", {"context_tokens": 6000, "max_questions": 64})
        self.assertGreater(len(windows), 1)
        self.assertEqual(windows[0][0], 0)
        self.assertEqual(windows[-1][1], len(chunks) - 1)
        self.assertTrue(all(b + 1 == c for (_, b), (c, _) in zip(windows, windows[1:])))


class HybridTests(unittest.TestCase):
    def test_neighbourhoods_merge_under_360_s(self):
        req = request([10.0] * 200)
        chunks = make(req["segments"], {"kind": "segments", "size": 10})
        runs = [{"first": 0, "last": 0}, {"first": 4, "last": 4}, {"first": 12, "last": 13}]
        hoods = hybrid.neighbourhoods(runs, chunks, 2000.0)
        self.assertEqual(hoods, [[0.0, 680.0, ["0-0", "4-4"]], [1020.0, 1580.0, ["12-13"]]])
        lo, hi = hybrid.index_range(req["segments"], 1020.0, 1580.0)
        sub = hybrid.sub_request(req, lo, hi)
        self.assertEqual(sub["segments"][0]["id"], req["segments"][lo]["id"])
        self.assertEqual(sub["transcript"]["segment_count"], hi - lo + 1)
        self.assertEqual(len(req["segments"]), 200)

    def test_stub_hybrid_through_the_real_bridge(self):
        run = lane_a("run")
        try:
            run.verify_bridge()
        except RuntimeError as error:
            self.skipTest(f"eval_bridge not built or stale: {error}")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = manifest(root / "fixtures", [("fake-show", fixture(), TRUTH)])
            run_decision.main(["--manifest", str(path), "--out", str(root / "decision"), "--model", "oracle", "--stub",
                               "oracle", "--design", "h1", "--chunking", "sec30", "--tag", "h1", "--repair"])
            out = root / "decision" / "h1" / "fake-show-1"
            s = read(out / "summary.json")
            self.assertIsNone(s["error"])
            self.assertTrue(s["validation"]["complete"], s["validation"]["warnings"])
            self.assertTrue((out / "window-0" / "request.json").exists())
            self.assertTrue((out / "decision-w0" / "request.json").exists())
            self.assertEqual([round(p["coverage"], 3) for p in s["metrics"]["pods"]], [1.0, 1.0])
            self.assertTrue(all(span["evidence_quote"] for span in s["validation"]["spans"]))
            self.assertEqual(len(s["hybrid"]["neighbourhoods"]), 1)


if __name__ == "__main__":
    unittest.main()

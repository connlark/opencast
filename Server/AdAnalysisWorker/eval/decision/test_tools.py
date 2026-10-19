"""Paid-wave tools: calibration, --questions-per-request grouping, the offline estimator, the grouping probe."""

import tempfile
import unittest
from pathlib import Path

from decision import calibration, estimate, run_decision
from decision.common import lane_a, lane_a_available, load_manifest, read
from decision.fakes import manifest, request

TRUTH = {"pods": [[107, 167], [407, 437]], "optional": [[97, 97]], "negatives": [[257, 307]]}


def fixture():
    durations = [6.4] * 50
    texts = [f"show talk number {i} about boats and wood" for i in range(50)]
    for i in range(10, 17):
        texts[i] = f"this episode is brought to you by harborsafe insurance part {i} visit the site"
    return request(durations, ids=[7 + 10 * i for i in range(50)], texts=texts)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.manifest = manifest(self.root / "fixtures", [("fake-show", fixture(), TRUTH)])

    def tearDown(self):
        self.tmp.cleanup()

    def run_stub(self, tag, design="d", extra=()):
        run_decision.main(["--manifest", str(self.manifest), "--out", str(self.root / "decision"), "--model", "oracle",
                           "--stub", "oracle", "--design", design, "--chunking", "sec30", "--tag", tag, *extra])
        return self.root / "decision" / tag


class CalibrationTests(Base):
    def test_classes_precedence_and_pod_share(self):
        fx, req, _ = load_manifest(self.manifest)["fake-show"]
        labels = calibration.segment_labels(req, fx["ground_truth"])
        # ids are 7 + 10 i: pod 107..167 = indices 10..16, optional 97 = 9, negative 257..307 = 25..30
        self.assertEqual(labels[9], "optional")
        self.assertEqual(labels[10:17], ["pod"] * 7)
        self.assertEqual(labels[25:31], ["negative"] * 6)
        self.assertEqual(calibration.chunk_class(req, labels, 10, 13), ("pod", 1.0))
        self.assertEqual(calibration.chunk_class(req, labels, 15, 19)[0], "pod_edge")
        self.assertEqual(calibration.chunk_class(req, labels, 6, 9)[0], "optional")
        self.assertEqual(calibration.chunk_class(req, labels, 24, 27)[0], "negative")
        self.assertEqual(calibration.chunk_class(req, labels, 0, 5), ("content", 0.0))

    def test_auc_ties_half_and_histogram_edges(self):
        self.assertEqual(calibration.auc([0.9, 0.8], [0.1, 0.8]), 0.875)
        self.assertIsNone(calibration.auc([], [0.1]))
        self.assertEqual(calibration.histogram([0.0, 0.05, 0.1, 0.99, 1.0]), [2, 1, 0, 0, 0, 0, 0, 0, 0, 2])
        d = calibration.describe([0.0, 1.0, 1.0, 0.5])
        self.assertEqual((d["n"], d["exact0"], d["exact1"]), (4, 0.25, 0.5))

    def test_report_on_stub_runs_both_designs(self):
        b = self.run_stub("b", design="b_prime")
        c = self.run_stub("c", design="c")
        d = self.run_stub("d", design="d")
        out = self.root / "cal.md"
        calibration.main(["--manifest", str(self.manifest), "--runs", f"b={b}", "--runs", f"c={c}", "--runs", f"d={d}", "--out", str(out)])
        reports = {r["configuration"]: r for r in read(out.with_suffix(".json"))}
        rb = reports["b"]
        self.assertEqual(rb["chunks"], sum(rb["p_ad"][k]["n"] for k in calibration.CLASSES))
        self.assertGreaterEqual(rb["p_ad"]["pod"]["mean"], 0.5)
        self.assertEqual((rb["p_ad"]["negative"]["mean"], rb["p_ad"]["content"]["mean"]), (0.0, 0.0))
        self.assertEqual(rb["auc_pod_vs_program"], 1.0)
        self.assertEqual(rb["facets"]["both_yes"], 0)
        self.assertEqual(rb["facets"]["mean_abs_sum_minus_1"], 0.0)
        self.assertIn("choice_mean", reports["c"])
        self.assertNotIn("facets", reports["c"])
        self.assertEqual(reports["c"]["auc_pod_vs_program"], 1.0)
        self.assertIn("refine_p", reports["d"])
        self.assertEqual(reports["d"]["refine_p"]["pod"]["mean"], 1.0)
        text = out.read_text()
        self.assertIn("## b", text)
        none = self.root / "none.md"
        calibration.main(["--manifest", str(self.manifest), "--runs", f"b={b}", "--out", str(none), "--fixtures", "other"])
        self.assertEqual(read(none.with_suffix(".json"))[0]["chunks"], 0)
        self.assertIn("Highest P(ad) on program chunks", text)


class GroupingTests(Base):
    def test_groups_of(self):
        self.assertEqual(run_decision.groups_of([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
        self.assertEqual(run_decision.groups_of([1, 2], None), [[1, 2]])
        with self.assertRaises(ValueError):
            run_decision.groups_of([1], 0)

    def test_grouped_run_asks_n_at_a_time_and_derives_the_same(self):
        plain = self.run_stub("plain")
        grouped = self.run_stub("grouped", extra=("--questions-per-request", "4"))
        p, g = plain / "fake-show-1", grouped / "fake-show-1"
        plain_ids = [q["id"] for q in read(p / "decision-w0" / "request.json")["questions"]]
        dirs = sorted(x for x in g.iterdir() if x.name.startswith("decision-w0g"))
        self.assertEqual(len(dirs), -(-len(plain_ids) // 4))
        self.assertFalse((g / "decision-w0").exists())
        seen = []
        for k in range(len(dirs)):
            qs = read(g / f"decision-w0g{k}" / "request.json")["questions"]
            self.assertLessEqual(len(qs), 4)
            seen += [q["id"] for q in qs]
        self.assertEqual(seen, plain_ids)
        self.assertTrue(any(x.name.startswith("refine-t0g") for x in g.iterdir()))
        self.assertTrue((g / "confirm-s0g0").exists() or (g / "confirm-s0").exists())
        sp, sg = read(p / "summary.json"), read(g / "summary.json")
        self.assertEqual(sp["validation"], sg["validation"])
        self.assertEqual((sp["questions_per_request"], sg["questions_per_request"]), (None, 4))
        self.assertEqual(read(g / "fixture.json")["questions_per_request"], 4)
        self.assertGreater(sg["requests_total"], sp["requests_total"])
        self.assertEqual(read(g / "probabilities.json"), read(p / "probabilities.json"))

    def test_cli_rejects_zero(self):
        with self.assertRaises(SystemExit):
            self.run_stub("zero", extra=("--questions-per-request", "0"))


@unittest.skipUnless(lane_a_available("providers.systemone"), "Lane A's providers package is absent")
class EstimateTests(Base):
    def test_paging_follows_the_adapter_and_the_override_is_scoped(self):
        m = load_manifest(self.manifest)
        big = estimate.estimate(m, ["fake-show"], model="pplx-decider-latest", design="b_prime", chunking_id="sec30", repeats=2)
        flash = estimate.estimate(m, ["fake-show"], model="pplx-decider-flash-latest", design="b_prime", chunking_id="sec30", repeats=2)
        what_if = estimate.estimate(m, ["fake-show"], model="pplx-decider-flash-latest", design="b_prime", chunking_id="sec30",
                                    repeats=1, vendor_max_questions=128)
        q = big["fixtures"][0]["questions"]
        self.assertEqual(big["fixtures"][0]["pages"], 1)
        self.assertEqual(flash["fixtures"][0]["pages"], q)
        self.assertEqual(what_if["fixtures"][0]["pages"], 1)
        self.assertEqual(big["total_pages"], 2)
        self.assertGreater(flash["per_repeat"]["expected_tokens"], 5 * big["per_repeat"]["expected_tokens"])
        self.assertEqual(lane_a("providers").adapter_for("pplx-decider-flash-latest").max_questions, 1)
        self.assertLessEqual(big["per_repeat"]["expected_tokens"], big["per_repeat"]["bound_tokens"])

    def test_two_stage_counts_refine_and_confirm_stages(self):
        m = load_manifest(self.manifest)
        d = estimate.estimate(m, ["fake-show"], model="pplx-decider-latest", design="d", chunking_id="sec30", repeats=1)
        self.assertEqual(set(d["fixtures"][0]["stages"]), {"decision", "refine", "confirm"})
        grouped = estimate.estimate(m, ["fake-show"], model="pplx-decider-latest", design="b_prime", chunking_id="sec30",
                                    repeats=1, qpr=4)
        self.assertEqual(grouped["fixtures"][0]["pages"], -(-grouped["fixtures"][0]["questions"] // 4))



@unittest.skipUnless(lane_a_available("providers.systemone"), "Lane A's providers package is absent")
class ProbeTests(unittest.TestCase):
    def test_one_request_four_questions_settled_on_the_ledger(self):
        from unittest import mock

        from decision import probe_grouping

        sent = []

        def fake_http(url, payload, headers):
            sent.append(payload)
            answers = {qid: {"type": "noul", "noul": 0.9 if truth else 0.1} for qid, _, truth in probe_grouping.QUESTIONS}
            return {"model": payload["model"], "answers": answers, "usage": {"input_tokens": 480, "output_tokens": 4}}

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            snippet = root / "snippet.txt"
            snippet.write_text("[1] This episode is brought to you by a sock brand.\n[2] Back to the story.\n")
            key = root / "key"
            key.write_text("pplx-test-key-value\n")
            ledger_path = root / "ledger.json"
            lane_a("budget").Ledger(ledger_path, 1.0)
            argv = ["--snippet", str(snippet), "--key-file", str(key), "--ledger", str(ledger_path), "--max-spend", "1",
                    "--out", str(root / "decision"), "--tag", "probe"]
            with mock.patch.object(lane_a("providers.systemone"), "http", fake_http):
                probe_grouping.main(argv)
            self.assertEqual(len(sent), 1)
            self.assertEqual(len(sent[0]["questions"]), 4)
            report = read(root / "decision" / "probe" / "probe.json")
            self.assertEqual((report["pages"], report["usage"]["input"]), (1, 480))
            self.assertEqual([a["p"] for a in report["answers"]], [0.9, 0.9, 0.1, 0.1])
            ledger = read(ledger_path)
            self.assertEqual([e["state"] for e in ledger["entries"]], ["settled"])
            self.assertEqual(lane_a("providers").adapter_for("pplx-decider-flash-latest").max_questions, 1)
            self.assertNotIn("pplx-test-key-value", (root / "decision" / "probe" / "wire-request.json").read_text())
            report_ok, ok = lane_a("budget").verify(ledger_path, [root / "decision"])
            self.assertTrue(ok, report_ok)
            with self.assertRaises(SystemExit):
                probe_grouping.main(argv)  # refuses to overwrite
            with self.assertRaises(SystemExit):
                probe_grouping.main([*argv[:4], str(root / "absent.json"), *argv[5:-1], "probe2"])
            self.assertFalse((root / "absent.json").exists())



@unittest.skipUnless(lane_a_available("providers.systemone"), "Lane A's providers package is absent")
class PaidPathTests(Base):
    """The paid driver against a mocked vendor and a temporary ledger."""

    def paid(self, root, tag, model, extra=(), http=None):
        from unittest import mock

        key = root / "key"
        key.write_text("test-key-value\n")
        ledger = root / "ledger.json"
        if not ledger.exists():
            lane_a("budget").Ledger(ledger, 1.0)
        argv = ["--manifest", str(self.manifest), "--out", str(root / "decision"), "--model", model, "--key-file", str(key),
                "--ledger", str(ledger), "--max-spend", "1", "--design", "b_prime", "--chunking", "sec30", "--tag", tag, *extra]
        with mock.patch.object(lane_a("providers.systemone"), "http", http or self.fake_http):
            run_decision.main(argv)
        return root / "decision" / tag

    def setUp(self):
        super().setUp()
        self.sent = []

    def fake_http(self, url, payload, headers):
        self.sent.append(payload)
        answers = {qid: {"type": "noul", "noul": 0.1} for qid in payload["questions"]}
        return {"model": payload["model"], "answers": answers, "usage": {"input_tokens": 100 + 40 * len(answers), "output_tokens": 1}}

    def probe_dir(self, root, model):
        probe = root / "probe"
        probe.mkdir()
        (probe / "probe.json").write_text('{"model": "%s", "pages": 1, "errors": [], "questions_in_one_request": 4, "usage": {"input": 502}}' % model)
        return probe

    def test_vendor_override_pages_flash_per_window_and_is_recorded(self):
        flash = "pplx-decider-flash-latest"
        one = self.paid(self.root, "one", flash)
        questions = len(read(one / "fake-show-1" / "decision-w0" / "request.json")["questions"])
        self.assertEqual(len(self.sent), questions)
        self.sent.clear()
        probe = self.probe_dir(self.root, flash)
        grouped = self.paid(self.root, "grouped", flash, ("--vendor-max-questions", "128", "--vendor-override-evidence", str(probe)))
        self.assertEqual(len(self.sent), 1)
        fx = read(grouped / "fake-show-1" / "fixture.json")
        self.assertEqual((fx["vendor_override"]["max_questions"], fx["vendor_override"]["adapter_max_questions"]), (128, 1))
        self.assertEqual(read(grouped / "fake-show-1" / "summary.json")["vendor_override"]["evidence"], str(probe))
        self.assertEqual(lane_a("providers").adapter_for(flash).max_questions, 1)
        context = read(self.root / "ledger.json")["entries"][-1]["context"]
        self.assertEqual((context["tag"], context["ask"], context["fixture"]), ("grouped", "decision-w0", "fake-show"))
        report, ok = lane_a("budget").verify(self.root / "ledger.json", [self.root / "decision"])
        self.assertTrue(ok, report)

    def test_vendor_override_needs_matching_evidence(self):
        probe = self.probe_dir(self.root, "pplx-decider-latest")
        for extra in (("--vendor-max-questions", "128"), ("--vendor-max-questions", "128", "--vendor-override-evidence", str(probe))):
            with self.assertRaises(SystemExit):
                self.paid(self.root, "bad", "pplx-decider-flash-latest", extra)
        self.assertEqual(self.sent, [])

    def test_two_consecutive_uncertain_failures_stop_the_batch(self):
        import io
        import urllib.error

        def gateway_timeout(url, payload, headers):
            self.sent.append(payload)
            raise urllib.error.HTTPError(url, 504, "Gateway Timeout", {}, io.BytesIO(b"error code: 504"))

        with self.assertRaises(SystemExit) as stop:
            self.paid(self.root, "t504", "pplx-decider-latest", ("--repeats", "3"), http=gateway_timeout)
        self.assertIn("2 consecutive errored runs", str(stop.exception))
        self.assertEqual(len(self.sent), 2)
        self.assertFalse((self.root / "decision" / "t504" / "fake-show-3").exists())
        states = [e["state"] for e in read(self.root / "ledger.json")["entries"]]
        self.assertEqual(states, ["ambiguous", "ambiguous"])



class TwoStageChoiceTests(Base):
    def test_d_c_asks_choice_then_refines_and_confirms(self):
        tag = self.run_stub("dc", design="d_c")
        run = tag / "fake-show-1"
        qs = read(run / "decision-w0" / "request.json")["questions"]
        self.assertTrue(all(q["type"] == "choice" for q in qs))
        names = [p.name for p in run.iterdir()]
        self.assertTrue(any(n.startswith("refine-t") for n in names))
        self.assertTrue(any(n.startswith("confirm-s") for n in names))
        s = read(run / "summary.json")
        self.assertEqual(s["design"], "d_c")
        self.assertTrue(s["validation"]["complete"])
        self.assertEqual([round(p["coverage"], 3) for p in s["metrics"]["pods"]], [1.0, 1.0])
        self.assertTrue(all(span["decision"]["confidence_rule"].startswith("min(confirm") for span in s["validation"]["spans"]))
        d = read(self.run_stub("d", design="d") / "fake-show-1" / "summary.json")
        self.assertEqual(s["metrics"]["zones"], d["metrics"]["zones"])

    def test_w2_wording_is_recorded(self):
        tag = self.run_stub("w2", design="b_prime", extra=("--wording", "w2"))
        fx = read(tag / "fake-show-1" / "fixture.json")
        self.assertEqual(fx["question_set"]["wording"], "w2")
        content = [q for q in read(tag / "fake-show-1" / "decision-w0" / "request.json")["questions"] if q["id"].endswith("_content")]
        self.assertIn("NOT editorial content", content[0]["criteria"]["false"])



class HybridChoiceTests(unittest.TestCase):
    def test_h1_c_localises_with_choice_through_the_real_bridge(self):
        run = lane_a("run")
        try:
            run.verify_bridge()
        except RuntimeError as error:
            self.skipTest(f"eval_bridge not built or stale: {error}")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = manifest(root / "fixtures", [("fake-show", fixture(), TRUTH)])
            run_decision.main(["--manifest", str(path), "--out", str(root / "decision"), "--model", "oracle", "--stub",
                               "oracle", "--design", "h1_c", "--chunking", "sec30", "--tag", "h1c", "--repair"])
            out = root / "decision" / "h1c" / "fake-show-1"
            s = read(out / "summary.json")
            self.assertIsNone(s["error"])
            self.assertEqual((s["design"], s["localiser"]), ("h1_c", "c"))
            self.assertTrue(s["validation"]["complete"], s["validation"]["warnings"])
            self.assertTrue(all(q["type"] == "choice" for q in read(out / "decision-w0" / "request.json")["questions"]))
            self.assertTrue((out / "window-0" / "request.json").exists())
            self.assertEqual([round(p["coverage"], 3) for p in s["metrics"]["pods"]], [1.0, 1.0])
            self.assertTrue(all(span["evidence_quote"] for span in s["validation"]["spans"]))
            h = s["hybrid"]
            self.assertEqual((h["neighbourhood_count"], h["final_validate_complete"]), (1, True))
            self.assertGreater(h["neighbourhood_seconds"], 0)
            self.assertEqual(set(s["cost_by_stage"]), {"decision", "generative"})


if __name__ == "__main__":
    unittest.main()

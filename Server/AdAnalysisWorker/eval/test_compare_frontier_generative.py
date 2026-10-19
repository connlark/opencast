"""Tests for compare_frontier_generative.py on synthetic run trees (no network)."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import budget  # noqa: E402
import compare_frontier_generative as cf  # noqa: E402

# Ten 10-second segments with sparse ids (the harness scores by id).
SEGMENTS = [{"id": 2 * i + 1, "start": 10.0 * i, "end": 10.0 * (i + 1), "text": f"s{i}"} for i in range(10)]
# ids: 1 3 5 7 9 11 13 15 17 19 -> seconds [0,10) ... [90,100)
TRUTH = {
    "pods": [[3, 5], [13, 15]],  # 10-30 s, 60-80 s
    "optional": [[7, 7]],  # 30-40 s
    "negatives": [[17, 19]],  # 80-100 s
}
GEMINI_USAGE = {"input": 1000, "cached": 0, "write": 0, "output": 200, "reasoning": 50}


def request():
    return {"segments": SEGMENTS, "transcript": {"audio_duration": 3600}}


def span(start_id, end_id, confidence=1.0):
    by_id = {s["id"]: s for s in SEGMENTS}
    return {
        "kind": "host_read_ad",
        "label": "x",
        "start_segment_id": start_id,
        "end_segment_id": end_id,
        "start_time": by_id[start_id]["start"],
        "end_time": by_id[end_id]["end"],
        "confidence": confidence,
        "evidence_quote": "q",
    }


def raw(validated):
    """The model-side v3 span: quotes instead of the validator's times."""
    out = {k: v for k, v in validated.items() if k not in ("start_time", "end_time")}
    return {**out, "start_quote": "a", "end_quote": "b"}


def gemini_response(spans, finish="STOP"):
    return {
        "candidates": [
            {
                "content": {"parts": [{"text": json.dumps({"spans": [raw(s) for s in spans]})}]},
                "finishReason": finish,
            }
        ],
        "usageMetadata": {"promptTokenCount": 1000, "candidatesTokenCount": 150, "thoughtsTokenCount": 50},
    }


class Tree:
    """A manifest with two fixtures (sn1094, bugged-tiny) and run trees."""

    def __init__(self, root: Path):
        self.root = root
        (root / "fixtures" / "requests").mkdir(parents=True)
        fixtures = []
        for name in ("sn1094", "bugged-tiny", cf.NEGATIVE_FIXTURE):
            path = root / "fixtures" / "requests" / f"{name}.json"
            path.write_text(json.dumps(request()))
            truth = TRUTH if name != cf.NEGATIVE_FIXTURE else {"pods": [], "optional": [], "negatives": [[1, 19]]}
            fixtures.append({"name": name, "request": f"requests/{name}.json", "ground_truth": truth})
        self.manifest = root / "fixtures" / "manifest.json"
        self.manifest.write_text(json.dumps({"fixtures": fixtures}))

    def run(self, tag, fixture, repeat, spans, *, model="gemini-3.8-flash", complete=True,
            error=None, calls=None, response=None, cost=0.01, metrics=None, extra_files=None):
        directory = self.root / "runs" / tag / f"{fixture}-{repeat}"
        (directory / "window-0").mkdir(parents=True)
        mf = cf.load_manifest(self.manifest)
        truth = mf["fixtures"][fixture]["entry"]["ground_truth"]
        measured = cf.harness.measure(request(), spans if complete else [], truth)
        summary = {
            "model": model,
            "policy": "promo_ad_breaks_v3",
            "thinking": "medium",
            "validation": {
                "complete": complete,
                "spans": spans if complete else [],
                "warnings": [error] if error and not complete else [],
                "notices": [],
            },
            "metrics": metrics if metrics is not None else measured,
            "calls": calls if calls is not None else [
                {"usage": GEMINI_USAGE, "latency_ms": 2000, "finish_reason": "STOP"}
            ],
            "error": error,
            "cost_usd": cost,
        }
        (directory / "summary.json").write_text(json.dumps(summary))
        (directory / "fixture.json").write_text(json.dumps({
            "fixture": {"name": fixture},
            "request_sha256": mf["fixtures"][fixture]["request_sha256"],
            "eval_binary_sha256": "ab" * 32,
        }))
        (directory / "window-0" / "response.json").write_text(
            json.dumps(response if response is not None else gemini_response(spans)))
        for name, doc in (extra_files or {}).items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(doc))
        return self.root / "runs" / tag


class CompareFrontierTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tree = Tree(Path(self.tmp.name))
        self.manifest = cf.load_manifest(self.tree.manifest)

    def tearDown(self):
        self.tmp.cleanup()

    def judged(self, tag):
        records = cf.discover(self.tree.root / "runs" / tag, self.manifest)
        return [cf.judge_run(r, self.manifest) for r in records]

    def test_clean_run_has_no_disqualifier(self):
        self.tree.run("c", "sn1094", 1, [span(3, 5), span(13, 15)])
        (run,) = self.judged("c")
        self.assertEqual(run["status"], "complete")
        self.assertEqual(run["whole_pod_misses"], [])
        self.assertEqual(run["false_skip_s"], 0)
        self.assertEqual(run["junk_zones"], [])
        self.assertTrue(run["metrics_match_archive"])
        self.assertTrue(run["request_sha256_match"])
        self.assertFalse(any(run["disqualifiers"].values()))

    def test_miss_junk_negative_and_overshoot(self):
        # Pod 13-15 missed; 9-11 (40-60 s) is junk; 13-17 would hit the
        # negative 80-100 s: use 15-17 (70-90 s) = 10 s on the negative.
        spans = [span(1, 5), span(9, 11), span(15, 17)]
        self.tree.run("c", "sn1094", 1, spans)
        (run,) = self.judged("c")
        self.assertEqual(run["status"], "complete")
        pods = {tuple(p["ids"]): p for p in run["pods"]}
        self.assertEqual(pods[(3, 5)]["start_overshoot_s"], 10.0)
        self.assertEqual(pods[(13, 15)]["coverage"], 0.5)  # 70-80 of 60-80
        self.assertEqual(run["whole_pod_misses"], [])
        self.assertEqual(len(run["junk_zones"]), 1)
        self.assertTrue(run["disqualifiers"]["junk_zone"])
        self.assertTrue(run["disqualifiers"]["negative_hit"])
        self.assertEqual(run["negative_overlap_s"], 10.0)
        # 0-10 s + 40-60 s junk + 80-90 s negative = 40 s outside pods/optional.
        self.assertEqual(run["false_skip_s"], 40.0)

    def test_whole_pod_miss_counts_complete_runs_only(self):
        self.tree.run("c", "sn1094", 1, [span(3, 5)])
        self.tree.run("c", "sn1094", 2, [], complete=False,
                      error="ad_analysis_incomplete: v3_break_duration:3-15")
        runs = self.judged("c")
        self.assertEqual([r["status"] for r in runs], ["complete", "incomplete"])
        self.assertEqual(runs[1]["issue_codes"], {"final:v3_break_duration": 1})
        self.assertEqual(runs[0]["whole_pod_misses"], [[13, 15]])
        self.assertEqual(runs[1]["whole_pod_misses"], [])
        row = cf.aggregate("c", runs)
        self.assertEqual(row["whole_pod_misses"], 1)
        self.assertEqual(row["complete_pct"], 50.0)
        self.assertIn("missed whole pods: sn1094 13-15 (1/1)", row["what_it_got_wrong"])
        self.assertIn("no result on 1/2 runs: sn1094 1/2 (v3_break_duration)", row["what_it_got_wrong"])

    def test_non_stop_malformed_leak(self):
        leaked = dict(span(3, 5), reason="extra")
        self.tree.run(
            "c", "sn1094", 1, [span(3, 5)],
            calls=[{"usage": GEMINI_USAGE, "latency_ms": 1000, "finish_reason": "MAX_TOKENS",
                    "answer_error": "Incomplete or refused Gemini output"}],
            response=gemini_response([leaked]),
        )
        (run,) = self.judged("c")
        self.assertEqual(run["disqualifiers"]["non_stop_finish"], ["MAX_TOKENS"])
        self.assertTrue(run["disqualifiers"]["malformed_output"])
        self.assertEqual(run["disqualifiers"]["schema_key_leak"], ["window-0: span ['reason']"])

    def test_malformed_code_in_initial_validation(self):
        self.tree.run("c", "sn1094", 1, [span(3, 5)], extra_files={
            "window-0/initial-validation.json": {"complete": False, "warnings": ["v3_malformed_model_json"]},
            "repair-0/validation.json": {"complete": True, "warnings": []},
        })
        (run,) = self.judged("c")
        self.assertTrue(run["disqualifiers"]["malformed_output"])
        self.assertEqual(run["repairs"], 1)
        self.assertEqual(run["issue_codes"], {"initial:v3_malformed_model_json": 1})

    def test_http_400_transport_and_aborted(self):
        body = '{"error": {"code": 400, "message": "bad", "status": "INVALID_ARGUMENT"}}'
        self.tree.run("c", "sn1094", 1, [], complete=False, error=body, calls=[])
        self.tree.run("c", "sn1094", 2, [], complete=False,
                      error="Reopen the ledger with its current authorized cap", calls=[])
        runs = self.judged("c")
        self.assertEqual([r["status"] for r in runs], ["transport", "aborted"])
        self.assertTrue(runs[0]["disqualifiers"]["http_400"])
        row = cf.aggregate("c", runs)
        self.assertEqual(row["runs"], 1)
        self.assertEqual(len(row["aborted"]), 1)
        self.assertEqual(row["disqualifiers"]["http_400"], 1)

    def test_archived_metrics_mismatch_is_flagged(self):
        self.tree.run("c", "sn1094", 1, [span(3, 5)], metrics={"pods": [], "zones": []})
        (run,) = self.judged("c")
        self.assertFalse(run["metrics_match_archive"])

    def test_costs_and_2027_doubling(self):
        self.tree.run("g", "sn1094", 1, [span(3, 5), span(13, 15)], cost=0.10)
        self.tree.run("g", "bugged-tiny", 1, [span(3, 5), span(13, 15)], cost=0.02)
        self.tree.run("g", cf.NEGATIVE_FIXTURE, 1, [], cost=5.0)  # excluded from $/episode
        row = cf.aggregate("g", self.judged("g"))
        per_call = budget.cost_usd("gemini-3.8-flash", GEMINI_USAGE)
        self.assertAlmostEqual(row["cost_per_episode_mean"], 0.06)
        self.assertAlmostEqual(row["cost_sn1094_max"], 0.10)
        self.assertAlmostEqual(row["cost_per_episode_uncached"], per_call)
        self.assertAlmostEqual(row["usd_per_day_today"], per_call * 50)
        self.assertAlmostEqual(row["usd_per_day_2027"], per_call * 100)
        self.assertAlmostEqual(row["cost_per_audio_hour"], 0.06)  # 3600 s per fixture
        self.tree.run("h", "sn1094", 1, [span(3, 5), span(13, 15)], model="claude-haiku-5-5", cost=0.01)
        haiku = cf.aggregate("h", self.judged("h"))
        self.assertAlmostEqual(haiku["usd_per_day_2027"], haiku["usd_per_day_today"])

    def test_cached_tokens_priced_at_input_rate_for_no_cache(self):
        cached = {**GEMINI_USAGE, "cached": 800}
        self.tree.run("c", "sn1094", 1, [span(3, 5), span(13, 15)],
                      calls=[{"usage": cached, "latency_ms": 1000, "finish_reason": "STOP"}],
                      cost=budget.cost_usd("gemini-3.8-flash", cached))
        row = cf.aggregate("c", self.judged("c"))
        self.assertLess(row["cost_per_episode_mean"], row["cost_per_episode_uncached"])
        self.assertAlmostEqual(
            row["cost_per_episode_uncached"], budget.cost_usd("gemini-3.8-flash", GEMINI_USAGE))
        self.assertAlmostEqual(row["cached_input_share"], 0.8)

    def test_complete_only_cost_and_full_pass_projection(self):
        call = {"usage": GEMINI_USAGE, "latency_ms": 1, "finish_reason": "STOP"}
        two_windows = {"window-1/response.json": gemini_response([])}
        self.tree.run("r", "sn1094", 1, [span(3, 5), span(13, 15)], calls=[call, call],
                      extra_files=two_windows)
        # Refused after its first of two planned windows.
        self.tree.run("r", "sn1094", 2, [], complete=False,
                      error="ad_analysis_incomplete: v3_evidence_mismatch:3-5", calls=[call])
        runs = self.judged("r")
        self.assertEqual([r["windows_called"] for r in runs], [2, 1])
        planned = cf.planned_windows(runs)
        self.assertEqual(planned, {"sn1094": 2})
        row = cf.aggregate("r", runs, planned=planned)
        per_call = budget.cost_usd("gemini-3.8-flash", GEMINI_USAGE)
        self.assertAlmostEqual(row["cost_per_episode_uncached"], 1.5 * per_call)
        self.assertAlmostEqual(row["cost_per_episode_complete_uncached"], 2 * per_call)
        self.assertAlmostEqual(row["cost_per_episode_projected_uncached"], 2 * per_call)
        self.assertEqual((row["episode_runs_complete"], row["episode_runs"]), (1, 2))
        cell = cf.complete_cost_cell(row)
        self.assertIn("(1/2); 1 refused run(s) stop early", cell)
        self.assertIn("(+33 % over the mean)", cell)
        # A run refused before any billed window cannot be projected.
        self.tree.run("q", "bugged-tiny", 1, [], complete=False,
                      error="ad_analysis_incomplete: context_exceeded", calls=[], cost=0.0)
        (q,) = self.judged("q")
        self.assertEqual(q["status"], "transport")
        qrow = cf.aggregate("q", [q], planned={"bugged-tiny": 2})
        self.assertEqual(qrow["projection_unpriced_fixtures"], ["bugged-tiny"])
        self.assertIn("no complete run on bugged-tiny", cf.complete_cost_cell(qrow))

    def test_bugged_tiny_jitter(self):
        self.tree.run("j", "bugged-tiny", 1, [span(3, 5), span(13, 15)])
        shifted = [dict(span(3, 5), start_time=12.0), span(13, 15)]
        self.tree.run("j", "bugged-tiny", 2, shifted)
        row = cf.aggregate("j", self.judged("j"))
        self.assertEqual(row["bugged_tiny_jitter"]["max_jitter_s"], 2.0)
        self.assertIn("jitter 2.0 s", row["what_it_got_wrong"])
        self.tree.run("k", "bugged-tiny", 1, [span(3, 5), span(13, 15)])
        self.tree.run("k", "bugged-tiny", 2, [span(3, 5)])
        row = cf.aggregate("k", self.judged("k"))
        self.assertFalse(row["bugged_tiny_jitter"]["same_span_count"])
        self.assertIsNone(row["bugged_tiny_jitter"]["max_jitter_s"])

    def test_latency_p95_nearest_rank(self):
        calls = [{"usage": GEMINI_USAGE, "latency_ms": ms, "finish_reason": "STOP"} for ms in (1000, 2000, 30000)]
        self.tree.run("p", "sn1094", 1, [span(3, 5), span(13, 15)], calls=calls)
        row = cf.aggregate("p", self.judged("p"))
        self.assertEqual(row["p95_call_s"], 30.0)
        self.assertEqual(row["requests_per_episode"], 3)

    def test_replay_reference_resolves_source_and_prices_calls(self):
        root = self.tree.root / "checkout" / "archive" / "tmp"
        source = root / "promo-v3" / "runs" / "r4" / "sn1094-1"
        source.mkdir(parents=True)
        (source / "summary.json").write_text(json.dumps({
            "model": "gemini-3.8-flash", "thinking": "medium",
            "calls": [{"usage": GEMINI_USAGE, "elapsed_s": 4.0}], "error": None,
        }))
        replay = root / "pcc-eval" / "replay" / "r4"
        replay.mkdir(parents=True)
        spans = [span(3, 5), span(13, 15)]
        (replay / "sn1094-1.json").write_text(json.dumps({
            "kind": "offline_revalidation_not_new_model_trial",
            "source": "../../archive/tmp/promo-v3/runs/r4/sn1094-1/summary.json",
            "eval_binary_sha256": "cd" * 32,
            "validation": {"complete": True, "spans": spans, "warnings": [], "notices": []},
            "metrics": cf.harness.measure(request(), spans, TRUTH),
        }))
        (run,) = [cf.judge_run(r, self.manifest) for r in cf.discover(replay, self.manifest)]
        self.assertTrue(run["replay"])
        self.assertEqual(run["latencies_s"], [4.0])
        self.assertAlmostEqual(run["cost_usd"], budget.cost_usd("gemini-3.8-flash", GEMINI_USAGE))
        self.assertEqual(run["eval_binary_sha256"], "cd" * 32)

    def test_main_writes_reports_incumbent_first(self):
        incumbent = self.tree.run("inc", "sn1094", 1, [span(3, 5), span(13, 15)])
        other = self.tree.run("oth", "sn1094", 1, [span(3, 5)], model="gpt-6-luna",
                              response={"output": [], "status": "completed"})
        out = self.tree.root / "reports"
        with contextlib.redirect_stdout(io.StringIO()):
            cf.main([
                "--manifest", str(self.tree.manifest),
                "--candidate", f"other={other}",
                "--candidate", f"incumbent={incumbent}",
                "--out-md", str(out / "COMPARISON.md"),
                "--out-json", str(out / "comparison.json"),
                "--frontier-md", str(out / "FRONTIER.md"),
            ])
        comparison = (out / "COMPARISON.md").read_text()
        self.assertIn("## other", comparison)
        self.assertIn("## incumbent", comparison)
        frontier = (out / "FRONTIER.md").read_text().splitlines()
        rows = [line for line in frontier if line.startswith("| other") or line.startswith("| incumbent")]
        self.assertTrue(rows[0].startswith("| other"))  # the first --candidate is the incumbent row
        sidecar = json.loads((out / "comparison.json").read_text())
        self.assertEqual([c["label"] for c in sidecar["candidates"]], ["other", "incumbent"])


if __name__ == "__main__":
    unittest.main()

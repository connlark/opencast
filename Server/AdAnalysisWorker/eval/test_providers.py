"""Lane A adapter tests: wire shapes, parsing, archives, paging, smoke, scan."""

import contextlib
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

import budget
import providers
import run
import secret_scan
from budget import PRICES, Ledger
from providers import MODELS, SUPPORTED_THINKING, adapter_for, adapter_recognizing, sanitize, systemone
from providers.base import ContextExceeded, RateLimiter, safe_error
from test_eval import GOLDEN_CANONICAL, FakeHTTP

CF_KEY = json.dumps(
    {"account_id": "acct0123456789", "api_token": "cf-token-SECRET-value-0001", "gateway_id": "ad-bakeoff"}
)
BRIDGE = run.WORKER / "target/debug/examples/eval_bridge"


def canonical():
    return json.loads(json.dumps(GOLDEN_CANONICAL))


def anthropic_doc(stop="end_turn", text='{"spans":[]}', thinking=True):
    content = ([{"type": "thinking", "thinking": "", "signature": "sig"}] if thinking else [])
    content.append({"type": "text", "text": text})
    return {
        "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
        "content": content, "stop_reason": stop, "stop_details": None,
        "usage": {"input_tokens": 700, "cache_read_input_tokens": 30, "cache_creation_input_tokens": 11,
                  "output_tokens": 40, "output_tokens_details": {"thinking_tokens": 25}},
    }


def chat_doc(finish="stop", content='{"spans":[]}', wrap=False):
    body = {
        "id": "c1", "object": "chat.completion", "model": "openai/gpt-6-luna",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": finish}],
        "usage": {"prompt_tokens": 800, "completion_tokens": 50, "prompt_tokens_details": {"cached_tokens": 100},
                  "completion_tokens_details": {"reasoning_tokens": 20}},
    }
    return {"success": True, "errors": [], "messages": [], "result": body} if wrap else body


def workers_doc(response, success=True):
    if not success:
        return {"success": False, "errors": [{"code": 5006, "message": "bad input"}], "result": None}
    return {"success": True, "errors": [], "messages": [],
            "result": {"response": response, "usage": {"prompt_tokens": 600, "completion_tokens": 30, "total_tokens": 630}}}


class RegistryTests(unittest.TestCase):
    def test_every_price_key_has_an_adapter_and_back(self):
        self.assertEqual(set(MODELS), set(PRICES))
        self.assertEqual(set(SUPPORTED_THINKING), set(PRICES))
        for model, adapter in MODELS.items():
            self.assertEqual(adapter.model, model)
            decision = getattr(adapter, "decision", False)
            self.assertEqual(decision, PRICES[model][3] == 0, model)
            if decision:
                self.assertEqual(adapter.supported_thinking, ("default",))
            self.assertNotIn("/", sanitize(model))
            self.assertNotIn("@", sanitize(model))

    def test_thinking_matrix(self):
        expect = {
            "gemini-3.8-flash": ("default", "low", "medium", "high"),
            "gemini-2.5-flash-lite": ("default", "none", "low", "medium", "high"),
            "claude-haiku-5-5": ("none", "low", "medium", "high"),
            "@cf/google/gemma-4-26b-a4b-it": ("default", "none", "low", "medium", "high"),
            "@cf/qwen/qwen3-30b-a3b-fp8": ("default", "none", "low", "medium", "high"),
            "@cf/openai/gpt-oss-120b": ("default", "low", "medium", "high"),
        }
        for model, values in expect.items():
            self.assertEqual(SUPPORTED_THINKING[model], values, model)
        self.assertIsNone(MODELS["@cf/google/gemma-4-26b-a4b-it"].provider_thinking("default"))
        self.assertEqual(MODELS["@cf/google/gemma-4-26b-a4b-it"].provider_thinking("none"), {"enable_thinking": False})
        self.assertEqual(MODELS["@cf/qwen/qwen3-30b-a3b-fp8"].provider_thinking("low"), {"enable_thinking": True})
        self.assertEqual(MODELS["@cf/openai/gpt-oss-120b"].provider_thinking("low"), {"reasoning_effort": "low"})
        self.assertEqual(MODELS["gemini-2.5-flash-lite"].provider_thinking("none"), {"thinkingBudget": 0})
        self.assertEqual(MODELS["gemini-3.1-flash-lite"].provider_thinking("high"), {"thinkingBudget": 16384})
        self.assertEqual(MODELS["gpt-6-luna"].provider_thinking("none"), {"effort": "none"})
        self.assertEqual(MODELS["gpt-6-luna"].provider_thinking("default"), {"effort": "low"})

    def main_exit(self, *argv):
        old = sys.argv
        sys.argv = ["run.py", *argv]
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit) as raised:
                run.main()
        finally:
            sys.argv = old
        return raised.exception.code, err.getvalue()

    def test_main_rejects_unsupported_combinations(self):
        common = ["--manifest", "m.json", "--out", "/nonexistent", "--tag", "t", "--key-file", "/nonexistent"]
        cases = [
            (["--model", "gemini-3.8-flash", "--policy", "promo_ad_breaks_v3", "--thinking", "none"], "supports --thinking"),
            (["--model", "claude-haiku-5-5", "--policy", "promo_ad_breaks_v3"], "supports --thinking"),
            (["--model", "@cf/openai/gpt-oss-120b", "--policy", "promo_ad_breaks_v3", "--thinking", "none"], "supports --thinking"),
            (["--model", "pplx-decider-latest", "--policy", "promo_ad_breaks_v3", "--repair"], "--repair does not apply"),
            (["--model", "typesafe/jev", "--policy", "promo_ad_breaks_v2"], "v3 policy only"),
            (["--model", "@cf/cloudflare/clef", "--policy", "promo_ad_breaks_v3"], "returns probabilities"),
        ]
        for argv, needle in cases:
            code, err = self.main_exit(*common, *argv)
            self.assertEqual(code, 2, argv)
            self.assertIn(needle, err, argv)
        code, err = self.main_exit("--smoke", "--model", "gpt-6-luna", "--tag", "x", "--out", "/nonexistent")
        self.assertIn("--smoke takes no", err)


class BuildTests(unittest.TestCase):
    def test_anthropic_wire(self):
        adapter = adapter_for("claude-haiku-5-5")
        wire = adapter.build(canonical(), "none", 4096)
        self.assertEqual(wire["model"], "claude-haiku-5-5")
        self.assertEqual(wire["max_tokens"], 4096)
        self.assertEqual(wire["system"], "rules")
        self.assertEqual([m["role"] for m in wire["messages"]], ["user", "assistant", "user"])
        self.assertEqual(wire["thinking"], {"type": "disabled"})
        self.assertEqual(wire["output_config"]["effort"], "low")
        self.assertEqual(wire["output_config"]["format"]["type"], "json_schema")
        schema = wire["output_config"]["format"]["schema"]
        self.assertFalse(schema["additionalProperties"])
        self.assertFalse(schema["properties"]["spans"]["items"]["additionalProperties"])
        for banned in ("temperature", "top_p", "top_k"):
            self.assertNotIn(banned, json.dumps(wire))
        self.assertEqual(adapter.build(canonical(), "medium", 4096)["thinking"], {"type": "adaptive"})
        self.assertEqual(adapter.build(canonical(), "medium", 4096)["output_config"]["effort"], "medium")
        # The canonical is not mutated by non-Gemini builds.
        payload = canonical()
        adapter.build(payload, "low", 10)
        self.assertEqual(payload, GOLDEN_CANONICAL)

    def test_gemini_lite_budget_and_level(self):
        wire = adapter_for("gemini-2.5-flash-lite").build(canonical(), "none", 2048)
        self.assertEqual(wire["generationConfig"]["thinkingConfig"], {"thinkingBudget": 0})
        self.assertIn("temperature", wire["generationConfig"])  # only 3.8 drops sampling
        self.assertIsNone(adapter_for("gemini-2.5-flash-lite").bridge_thinking("low"))
        self.assertEqual(adapter_for("gemini-3.8-flash").bridge_thinking("low"), "low")
        self.assertIsNone(adapter_for("gpt-6-luna").bridge_thinking("low"))

    def test_gpt6_luna_none_effort(self):
        self.assertEqual(adapter_for("gpt-6-luna").build(canonical(), "none", 100)["reasoning"], {"effort": "none"})
        self.assertEqual(adapter_for("gpt-5.6-luna").build(canonical(), "none", 100)["reasoning"], {"effort": "none"})

    def test_cloudflare_wires(self):
        chat = adapter_for("cf/openai/gpt-6-luna").build(canonical(), "default", 3000)
        self.assertEqual(chat["model"], "openai/gpt-6-luna")
        self.assertEqual(chat["messages"][0], {"role": "system", "content": "rules"})
        self.assertEqual(chat["response_format"]["json_schema"]["strict"], True)
        self.assertEqual(chat["max_completion_tokens"], 3000)
        self.assertEqual(chat["reasoning_effort"], "low")
        google = adapter_for("cf/google/gemini-3.8-flash").build(canonical(), "default", 3000)
        self.assertEqual((google["model"], google["max_tokens"]), ("google/gemini-3.8-flash", 3000))
        self.assertNotIn("reasoning_effort", google)
        self.assertFalse(adapter_for("cf/google/gemini-3.8-flash").strict_schema)
        gemma = adapter_for("@cf/google/gemma-4-26b-a4b-it").build(canonical(), "default", 3000)
        self.assertNotIn("model", gemma)
        self.assertEqual(gemma["response_format"]["json_schema"]["name"], "podcast_ad_breaks")
        self.assertNotIn("chat_template_kwargs", gemma)
        qwen = adapter_for("@cf/qwen/qwen3-30b-a3b-fp8").build(canonical(), "none", 3000)
        self.assertEqual(qwen["response_format"]["json_schema"]["strict"], True)
        self.assertEqual(qwen["chat_template_kwargs"], {"enable_thinking": False})
        oss = adapter_for("@cf/openai/gpt-oss-120b").build(canonical(), "low", 3000)
        self.assertEqual((oss["reasoning_effort"], oss["max_tokens"]), ("low", 3000))
        # max_tokens fitted to the context room.
        fitted = adapter_for("@cf/qwen/qwen3-30b-a3b-fp8").build(canonical(), "default", 40_000)
        self.assertLess(fitted["max_tokens"], 32_768)
        self.assertLessEqual(fitted["max_tokens"] + adapter_for("@cf/qwen/qwen3-30b-a3b-fp8").estimate(fitted), 32_768 + 2)
        self.assertEqual(adapter_for("@cf/qwen/qwen3-30b-a3b-fp8").reserved_output(fitted, 40_000), fitted["max_tokens"])
        messages = adapter_for("cf/anthropic/claude-haiku-5.5").build(canonical(), "none", 3000)
        self.assertEqual(messages["model"], "anthropic/claude-haiku-5.5")
        self.assertEqual(messages["thinking"], {"type": "disabled"})


class ParseTests(unittest.TestCase):
    def test_anthropic_end_turn_with_thinking_block(self):
        answer = adapter_for("claude-haiku-5-5").parse(anthropic_doc())
        self.assertEqual(answer.text_json, '{"spans":[]}')
        self.assertIsNone(answer.error)
        self.assertEqual(answer.finish_reason, "end_turn")
        self.assertEqual(answer.usage, {"input": 741, "cached": 30, "write": 11, "output": 40, "reasoning": 25})

    def test_anthropic_max_tokens_and_refusal(self):
        for stop in ("max_tokens", "refusal"):
            answer = adapter_for("claude-haiku-5-5").parse(anthropic_doc(stop=stop))
            self.assertIsNone(answer.text_json)
            self.assertIn(stop, answer.error)
            self.assertEqual(answer.finish_reason, stop)
            self.assertIsNotNone(answer.usage)  # billed even when refused
        with self.assertRaises(ValueError):
            run.answer_of("claude-haiku-5-5", anthropic_doc(stop="refusal"))

    def test_answer_of_sniffs_an_anthropic_doc(self):
        self.assertIs(adapter_recognizing(anthropic_doc()), MODELS["claude-haiku-5-5"])
        self.assertEqual(run.answer_of("claude-haiku-5-5", anthropic_doc()), {"spans": []})
        # An archived key unknown to MODELS is resolved by shape, not by name.
        self.assertEqual(run.answer_of("claude-haiku-9", anthropic_doc()), {"spans": []})
        self.assertEqual(run.usage_of("claude-haiku-9", anthropic_doc())["input"], 741)

    def test_workers_ai_str_dict_and_failure(self):
        adapter = adapter_for("@cf/google/gemma-4-26b-a4b-it")
        as_str = adapter.parse(workers_doc('{"spans":[]}'))
        as_dict = adapter.parse(workers_doc({"spans": []}))
        self.assertEqual(json.loads(as_str.text_json), json.loads(as_dict.text_json))
        self.assertEqual(as_str.usage, {"input": 600, "cached": 0, "write": 0, "output": 30, "reasoning": 0})
        failed = adapter.parse(workers_doc(None, success=False))
        self.assertIsNone(failed.text_json)
        self.assertIn("cloudflare_error", failed.error)
        self.assertIsNone(failed.usage)
        chat = adapter.parse({"success": True, "errors": [], "result": chat_doc()})
        self.assertEqual(chat.text_json, '{"spans":[]}')
        self.assertEqual(chat.usage["input"], 800)

    def test_gateway_google_bills_reasoning_beside_completion(self):
        doc = chat_doc()
        doc["usage"] = {"prompt_tokens": 419, "completion_tokens": 19, "total_tokens": 514,
                        "completion_tokens_details": {"reasoning_tokens": 76}}
        self.assertEqual(adapter_for("cf/google/gemini-3.8-flash").parse(doc).usage["output"], 95)
        doc["usage"] = {"prompt_tokens": 382, "completion_tokens": 54, "completion_tokens_details": {"reasoning_tokens": 26}}
        self.assertEqual(adapter_for("cf/openai/gpt-6-luna").parse(doc).usage["output"], 54)

    def test_workers_ai_answer_in_reasoning_content_when_content_null(self):
        answer = '{\n  "spans": []\n}'
        doc = {"success": True, "errors": [], "result": {
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": None, "reasoning": answer, "reasoning_content": answer}}],
            "usage": {"prompt_tokens": 1631, "completion_tokens": 114, "total_tokens": 1745}, "response": None}}
        parsed = adapter_for("@cf/qwen/qwen3-30b-a3b-fp8").parse(doc)
        self.assertEqual(json.loads(parsed.text_json), {"spans": []})
        self.assertEqual(parsed.channel, "message.reasoning_content")
        # A thinking chain (not JSON) in reasoning with empty content stays an error.
        doc["result"]["choices"][0]["message"]["reasoning_content"] = "Let me think about the sponsor."
        doc["result"]["choices"][0]["message"]["reasoning"] = "Let me think about the sponsor."
        broken = adapter_for("@cf/qwen/qwen3-30b-a3b-fp8").parse(doc)
        self.assertIsNone(broken.text_json)
        self.assertIsNone(broken.channel)
        # Normal content wins and records no channel.
        normal = adapter_for("@cf/qwen/qwen3-30b-a3b-fp8").parse({"success": True, "errors": [], "result": chat_doc()})
        self.assertIsNone(normal.channel)

    def test_chat_completions_stop_vs_length(self):
        adapter = adapter_for("cf/openai/gpt-6-luna")
        for wrap in (False, True):
            done = adapter.parse(chat_doc(wrap=wrap))
            self.assertEqual(done.text_json, '{"spans":[]}')
            self.assertEqual(done.usage, {"input": 800, "cached": 100, "write": 0, "output": 50, "reasoning": 20})
            cut = adapter.parse(chat_doc(finish="length", content='{"spa', wrap=wrap))
            self.assertIsNone(cut.text_json)
            self.assertIn("length", cut.error)
            self.assertEqual(cut.finish_reason, "length")

    def test_systemone_envelopes_normalise_identically(self):
        questions = systemone.check_questions(
            [{"id": "sponsor_read", "instructions": "a"}, {"id": "show_promo", "instructions": "b"}]
        )
        usage = {"input_tokens": 500, "output_tokens": 2}
        pplx = {"model": "pplx-decider-latest", "usage": usage,
                "answers": {"sponsor_read": {"type": "noul", "noul": 0.9}, "show_promo": {"type": "noul", "noul": 0.1}}}
        clef = {"success": True, "errors": [], "messages": [], "result": {**pplx, "model": "clef"}}
        jev = {"success": True, "errors": [], "messages": [],
               "result": {"state": "Completed", "result": {**pplx, "model": "jev-1.13.0"}}}
        openai = {"model": "gpt-6-luna", "usage": {**usage, "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0}},
                  "answers": [{"type": "predicate", "name": "sponsor_read", "probability": 0.9},
                              {"type": "predicate", "name": "show_promo", "probability": 0.1}]}
        results = [
            adapter_for(model).normalise(doc, questions)
            for model, doc in (("pplx-decider-latest", pplx), ("@cf/cloudflare/clef", clef),
                               ("typesafe/jev", jev), ("decisions/gpt-6-luna", openai))
        ]
        for answers, usage_, error in results:
            self.assertEqual(answers, {"sponsor_read": 0.9, "show_promo": 0.1})
            self.assertEqual(usage_["input"], 500)
            self.assertIsNone(error)
        refused = adapter_for("decisions/gpt-6-luna").normalise(
            {"answers": [{"type": "refusal", "name": "sponsor_read"}], "usage": usage}, questions[:1])
        self.assertEqual(refused[0], {"sponsor_read": None})
        failed = adapter_for("@cf/cloudflare/clef").normalise({"success": False, "errors": [{"code": 1}]}, questions)
        self.assertIsNone(failed[1])
        self.assertIn("cloudflare_error", failed[2])

    def test_archived_window_text_three_shapes(self):
        text = '{"segments":[{"id":1,"text":"a"}]}'
        self.assertEqual(run.archived_window_text(GOLDEN_CANONICAL), text)
        responses = adapter_for("gpt-5.6-luna").build(canonical(), "default", 100)
        self.assertEqual(run.archived_window_text(responses), text)
        self.assertEqual(run.archived_window_text({"kind": "systemone", "state": text, "questions": []}), text)
        with self.assertRaises(ValueError):
            run.archived_window_text({"messages": []})


class LimiterAndErrorTests(unittest.TestCase):
    def test_rate_limiter_patched_clock(self):
        now = [100.0]
        slept = []

        def sleep(seconds):
            slept.append(round(seconds, 6))
            now[0] += seconds

        limiter = RateLimiter(10, clock=lambda: now[0], sleep=sleep)
        waits = [limiter.wait() for _ in range(4)]
        self.assertEqual([round(w, 6) for w in waits], [0.0, 0.1, 0.1, 0.1])
        now[0] += 5  # idle refills at most one burst
        self.assertEqual(limiter.wait(), 0.0)
        self.assertAlmostEqual(limiter.wait(), 0.1)
        frozen = RateLimiter(4, clock=lambda: 0.0, sleep=lambda s: None)
        self.assertEqual([round(frozen.wait(), 6) for _ in range(3)], [0.0, 0.25, 0.5])

    def test_safe_error_redacts_every_credential(self):
        error = ValueError("bad token cf-token-SECRET-value-0001 for acct; pplx-abcdefghijklmnopqrstuvwxyz0123; AQ.abcdefghijklmnopqrstuv; model pplx-decider-flash-latest")
        text = safe_error(error, CF_KEY, ["cf-token-SECRET-value-0001"])
        self.assertNotIn("SECRET", text)
        self.assertNotIn("pplx-abcdef", text)
        self.assertIn("pplx-decider-flash-latest", text)
        self.assertNotIn("AQ.abcdef", text)
        self.assertEqual(safe_error(ValueError("plain"), "", []), "plain")


def ledger_in(tmp, cap=15):
    return Ledger(Path(tmp) / "ledger" / "budget-ledger.json", cap)


class StubbedCallTests(unittest.TestCase):
    def call(self, model, bodies, key, thinking, tmp, max_output=2048, payload=None):
        ledger = ledger_in(tmp)
        out = Path(tmp) / "runs" / "t" / "f-1" / "window-0"
        with FakeHTTP(bodies) as fake:
            output, details = run.call(model, payload or canonical(), key, ledger, out, {"w": 0}, max_output, thinking=thinking)
        return output, details, fake.requests, ledger, out

    def assert_archive(self, out, wire_sent):
        self.assertEqual(json.loads((out / "request.json").read_text())["contents"], GOLDEN_CANONICAL["contents"])
        self.assertEqual(json.loads((out / "request.json").read_text())["generationConfig"]["maxOutputTokens"], 2048)
        self.assertEqual(json.loads((out / "wire-request.json").read_text()), wire_sent)

    def test_anthropic_direct(self):
        with tempfile.TemporaryDirectory() as tmp:
            output, details, requests, ledger, out = self.call(
                "claude-haiku-5-5", [{"input_tokens": 741}, anthropic_doc()], "sk-ant-api-test-key-0000000000", "none", tmp)
            self.assertEqual(output, {"spans": []})
            self.assertEqual([r["url"] for r in requests], [
                "https://api.anthropic.com/v1/messages/count_tokens", "https://api.anthropic.com/v1/messages"])
            for r in requests:
                self.assertEqual(r["headers"], ["anthropic-version", "content-type", "x-api-key"])
            self.assertEqual(set(requests[0]["body"]), {"model", "system", "messages", "thinking", "output_config"})
            self.assert_archive(out, requests[1]["body"])
            entry = ledger.snapshot()["entries"][0]
            self.assertEqual((entry["input_bound"], entry["max_output"], entry["state"]), (741, 2048, "settled"))
            self.assertAlmostEqual(entry["actual_usd"], budget.cost_usd("claude-haiku-5-5", details["usage"]))
            self.assertEqual((details["provider"], details["route"], details["finish_reason"]), ("anthropic", "direct", "end_turn"))
            self.assertNotIn("input_estimated", details)

    def test_gateway_chat_and_messages(self):
        with tempfile.TemporaryDirectory() as tmp:
            output, details, requests, ledger, out = self.call("cf/openai/gpt-6-luna", [chat_doc(wrap=True)], CF_KEY, "default", tmp)
            self.assertEqual(output, {"spans": []})
            self.assertEqual(requests[0]["url"], "https://api.cloudflare.com/client/v4/accounts/acct0123456789/ai/v1/chat/completions")
            self.assertEqual(requests[0]["headers"], ["authorization", "cf-aig-collect-log", "cf-aig-gateway-id", "content-type"])
            self.assertTrue(details["input_estimated"])
            self.assertEqual(details["input_count"], adapter_for("cf/openai/gpt-6-luna").estimate(requests[0]["body"]))
            self.assert_archive(out, requests[0]["body"])
            self.assertEqual(ledger.snapshot()["entries"][0]["state"], "settled")
        with tempfile.TemporaryDirectory() as tmp:
            output, details, requests, ledger, out = self.call(
                "cf/anthropic/claude-haiku-5.5", [{"success": True, "errors": [], "result": anthropic_doc()}], CF_KEY, "low", tmp)
            self.assertEqual(output, {"spans": []})
            self.assertTrue(requests[0]["url"].endswith("/ai/v1/messages"))
            self.assertEqual(requests[0]["headers"], ["authorization", "cf-aig-collect-log", "cf-aig-gateway-id", "content-type"])
            entry = ledger.snapshot()["entries"][0]
            self.assertEqual(entry["input_bound"], details["input_count"] + 512 + -(-15 * details["input_count"] // 100))
            # STOP 3 smoke: estimate 3,051 vs billed 3,128; the margin covers it.
            self.assertGreater(3051 + 512 + -(-3051 * 15 // 100), 3128 * 1.1)

    def test_workers_ai_and_context_exceeded(self):
        with tempfile.TemporaryDirectory() as tmp:
            output, details, requests, ledger, out = self.call(
                "@cf/google/gemma-4-26b-a4b-it", [workers_doc({"spans": []})], CF_KEY, "default", tmp)
            self.assertEqual(output, {"spans": []})
            self.assertEqual(requests[0]["url"],
                             "https://api.cloudflare.com/client/v4/accounts/acct0123456789/ai/run/@cf/google/gemma-4-26b-a4b-it")
            self.assertEqual(requests[0]["headers"], ["authorization", "content-type"])
        big = canonical()
        big["contents"][0]["parts"][0]["text"] = "x" * 120_000
        with tempfile.TemporaryDirectory() as tmp:
            output, details, requests, ledger, out = self.call("@cf/qwen/qwen3-30b-a3b-fp8", [], CF_KEY, "default", tmp, payload=big)
            self.assertIsNone(output)
            self.assertEqual(details["transport_error"], "context_exceeded")
            self.assertEqual(requests, [])
            self.assertEqual(ledger.snapshot()["entries"], [])
            self.assertTrue((out / "request.json").exists())

    def test_definite_error_releases_and_redacts_cf_token(self):
        error = urllib.error.HTTPError("u", 401, "no", {}, io.BytesIO(b'{"errors":[{"code":10000,"message":"cf-token-SECRET-value-0001"}]}'))
        self.addCleanup(error.close)
        with tempfile.TemporaryDirectory() as tmp:
            ledger = ledger_in(tmp)
            out = Path(tmp) / "w"
            with FakeHTTP([error]), self.assertRaises(RuntimeError) as raised:
                run.call("@cf/google/gemma-4-26b-a4b-it", canonical(), CF_KEY, ledger, out, {}, 1000, thinking="default")
            self.assertNotIn("SECRET", str(raised.exception))
            self.assertNotIn("SECRET", (out / "error.json").read_text())
            self.assertEqual(ledger.snapshot()["entries"][0]["state"], "released")

    def test_secret_scan_clean_after_stubbed_calls(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.call("cf/openai/gpt-6-luna", [chat_doc()], CF_KEY, "default", tmp)
            keyfile = Path(tmp) / "keys" / "cf.json"
            keyfile.parent.mkdir()
            keyfile.write_text(CF_KEY)
            receipt = secret_scan.scan(Path(tmp) / "runs", [keyfile])
            self.assertTrue(receipt["passed"], receipt)
            self.assertEqual(receipt["exact_loaded_secrets_checked"], 1)  # account/gateway ids are public


class SecretScanTests(unittest.TestCase):
    def test_exact_values_patterns_and_no_model_name_false_positive(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, keys = Path(tmp) / "root", Path(tmp) / "keys"
            root.mkdir()
            keys.mkdir()
            (keys / "cf.json").write_text(CF_KEY)
            (keys / "pplx").write_text("pplx-RealLookingKeyValue0123456789abcdef\n")
            (root / "ledger.json").write_text(json.dumps({"model": "pplx-decider-flash-latest", "tag": "task-abcdefghijklmnopqrstu"}))
            (root / "ok.json").write_text(json.dumps({"account": "acct0123456789", "gateway": "ad-bakeoff"}))
            receipt = secret_scan.scan(root, [keys / "cf.json", keys / "pplx"])
            self.assertTrue(receipt["passed"], receipt)
            (root / "leak.txt").write_text("token cf-token-SECRET-value-0001 and AIzaSyA0123456789abcdefghijklmn")
            receipt = secret_scan.scan(root, [keys / "cf.json", keys / "pplx"])
            self.assertFalse(receipt["passed"])
            self.assertEqual(sorted(f["match"] for f in receipt["findings"]), ["exact_loaded_secret_1", "gemini_key_pattern"])
            self.assertNotIn("SECRET", (root / "secret-scan.json").read_text())


class SystemOneTests(unittest.TestCase):
    STATE = json.dumps({"policy": "promo_ad_breaks_v3", "segments": [{"id": 1, "text": "Harborline sponsors us."}]})

    def questions(self, n):
        return [{"id": f"q{i}", "instructions": f"Question {i}?"} for i in range(n)]

    def test_paging_by_question_cap_and_context(self):
        flash = systemone.build_decision_request(self.STATE, "pplx-decider-flash-latest", self.questions(3))
        self.assertEqual([len(p["questions"]) for p in flash], [1, 1, 1])
        big = systemone.build_decision_request(self.STATE, "pplx-decider-latest", self.questions(130))
        self.assertEqual([len(p["questions"]) for p in big], [128, 2])
        clef = systemone.build_decision_request(self.STATE, "@cf/cloudflare/clef", self.questions(65))
        self.assertEqual([len(p["questions"]) for p in clef], [64, 1])
        self.assertEqual(clef[0]["body"]["model"], "clef")
        self.assertEqual(set(clef[0]["body"]["questions"]["q0"]), {"type", "instructions"})
        jev = systemone.build_decision_request(self.STATE, "typesafe/jev", self.questions(1))
        self.assertEqual(set(jev[0]["body"]), {"model", "input"})
        self.assertEqual(jev[0]["body"]["input"]["state"], self.STATE)
        oa = systemone.build_decision_request(self.STATE, "decisions/gpt-6-luna", self.questions(2))
        self.assertEqual(oa[0]["body"]["questions"][0], {"type": "predicate", "name": "q0", "instructions": "Question 0?"})
        self.assertEqual(oa[0]["body"]["input"], self.STATE)
        long_state = json.dumps({"segments": [{"id": 1, "text": "y" * 30_000}]})
        # ~10K tokens: fits clef (65,536) in one page, overflows nothing.
        self.assertEqual(len(systemone.build_decision_request(long_state, "@cf/cloudflare/clef", self.questions(3))), 1)
        huge = json.dumps({"segments": [{"id": 1, "text": "y" * 100_000}]})
        with self.assertRaises(ContextExceeded):
            systemone.build_decision_request(huge, "typesafe/jev", self.questions(1))
        # Questions that overflow the context split across pages, each carrying the whole state.
        wide = [{"id": f"q{i}", "instructions": "z" * 6000} for i in range(10)]
        pages = systemone.build_decision_request(long_state, "@cf/cloudflare/clef-flash", wide)
        self.assertGreater(len(pages), 1)
        self.assertTrue(all(p["body"]["state"] == long_state for p in pages))

    def test_ask_reserves_calls_archives_settles(self):
        page = lambda ids: {"model": "pplx-decider-latest", "usage": {"input_tokens": 400, "output_tokens": len(ids)},
                            "answers": {i: {"type": "noul", "noul": 0.25} for i in ids}}
        with tempfile.TemporaryDirectory() as tmp:
            ledger = ledger_in(tmp)
            out = Path(tmp) / "decision" / "t" / "w0"
            with FakeHTTP([page(["q0"]), page(["q1"])]) as fake:
                result = systemone.ask("pplx-decider-flash-latest", self.STATE, self.questions(2),
                                       "pplx-test-key-abcdefghijklmnop", ledger, out, {"tag": "t"})
            self.assertEqual(result["answers"], {"q0": 0.25, "q1": 0.25})
            self.assertEqual((result["pages"], result["usage"]["input"]), (2, 800))
            self.assertAlmostEqual(result["cost_usd"], 800 * 0.01 / 1e6)
            self.assertEqual([r["url"] for r in fake.requests], ["https://api.perplexity.ai/v1/decisions"] * 2)
            self.assertEqual(fake.requests[0]["headers"], ["authorization", "content-type"])
            entries = ledger.snapshot()["entries"]
            self.assertEqual([e["state"] for e in entries], ["settled", "settled"])
            self.assertEqual([e["max_output"] for e in entries], [1, 1])
            response = json.loads((out / "response.json").read_text())
            self.assertEqual(response["kind"], "systemone")
            self.assertEqual(len(response["vendor"]), 2)
            self.assertEqual(json.loads((out / "request.json").read_text())["state"], self.STATE)
            self.assertEqual(run.archived_window_text(json.loads((out / "request.json").read_text())), self.STATE)
            report, ok = budget.verify(ledger.path, [Path(tmp) / "decision"])
            self.assertTrue(ok, report)
            with self.assertRaises(RuntimeError):  # no overwrite
                systemone.ask("pplx-decider-flash-latest", self.STATE, self.questions(1), "pplx-test-key-abcdefghijklmnop", ledger, out, {})

    def test_ask_stops_on_429_with_status(self):
        error = urllib.error.HTTPError("u", 429, "slow", {}, io.BytesIO(b'{"error":{"type":"too_many_requests"}}'))
        self.addCleanup(error.close)
        with tempfile.TemporaryDirectory() as tmp:
            ledger = ledger_in(tmp)
            with FakeHTTP([error]), self.assertRaises(systemone.ProviderHTTPError) as raised:
                systemone.ask("@cf/cloudflare/clef", self.STATE, self.questions(1), CF_KEY, ledger, Path(tmp) / "w", {})
            self.assertEqual(raised.exception.status, 429)
            self.assertEqual(ledger.snapshot()["entries"][0]["state"], "released")


@unittest.skipUnless(BRIDGE.exists(), "eval_bridge not built")
class SmokeTests(unittest.TestCase):
    def smoke(self, model, bodies, key, *extra):
        tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp, ignore_errors=True))
        keyfile = Path(tmp) / "key"
        keyfile.write_text(key)
        out = Path(tmp) / "runs"
        ledger = Path(tmp) / "ledger" / "budget-ledger.json"
        old = sys.argv
        sys.argv = ["run.py", "--smoke", "--model", model, "--key-file", str(keyfile), "--out", str(out),
                    "--ledger", str(ledger), "--max-spend", "15", *extra]
        try:
            with FakeHTTP(bodies) as fake, contextlib.redirect_stdout(io.StringIO()) as printed:
                run.main()
        finally:
            sys.argv = old
        return json.loads(printed.getvalue()), out, ledger, fake.requests, keyfile

    def test_generative_smoke_writes_no_fixture_dirs(self):
        line, out, ledger, requests, keyfile = self.smoke(
            "claude-haiku-5-5", [{"input_tokens": 900}, anthropic_doc()], "sk-ant-api-test-key-0000000000")
        self.assertEqual(sorted(p.name for p in out.iterdir()), ["smoke"])
        archive = Path(line["archive"])
        self.assertEqual(archive.parent.name, "claude-haiku-5-5")
        self.assertTrue((archive / "window-0" / "request.json").exists())
        self.assertTrue((archive / "window-0" / "wire-request.json").exists())
        self.assertTrue(line["parsed_ok"])
        self.assertEqual(line["count_or_estimate"], 900)
        self.assertEqual(line["provider_thinking"]["thinking"], {"type": "disabled"})  # lowest supported
        self.assertEqual(len(line["key_sha256_prefix"]), 8)
        self.assertNotIn("sk-ant", json.dumps(line))
        segments = json.loads(json.loads((archive / "window-0" / "request.json").read_text())["contents"][0]["parts"][0]["text"])["segments"]
        self.assertEqual(len(segments), 5)
        report, ok = budget.verify(ledger, [out])
        self.assertTrue(ok, report)
        self.assertTrue(secret_scan.scan(out, [keyfile])["passed"])

    def test_decision_smoke_two_questions(self):
        body = {"model": "clef", "usage": {"input_tokens": 300, "output_tokens": 2},
                "answers": {"sponsor_read": {"type": "noul", "noul": 0.97}, "show_promo": {"type": "noul", "noul": 0.02}}}
        line, out, ledger, requests, keyfile = self.smoke("@cf/cloudflare/clef", [{"success": True, "errors": [], "result": body}], CF_KEY)
        self.assertTrue(line["parsed_ok"])
        self.assertEqual(sorted(line["answers"]), ["show_promo", "sponsor_read"])
        self.assertEqual(Path(line["archive"]).parent.name, "_cf_cloudflare_clef")
        self.assertEqual(len(requests), 1)
        self.assertEqual(sorted(p.name for p in out.iterdir()), ["smoke"])
        self.assertTrue(budget.verify(ledger, [out])[1])


if __name__ == "__main__":
    unittest.main()

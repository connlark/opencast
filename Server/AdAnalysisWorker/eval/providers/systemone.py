"""Decision models ("System One" APIs): probabilities for questions about a state.

Plumbing only (Lane C owns the pipeline design). `state` is the exact v3
`input` JSON string the Worker sends Gemini for the window; questions are
`{"id", "instructions", "type": "noul"|"choice"|"score", "criteria"?}`.
Vendors and wire shapes (Step 0, 2026-10-18 docs and smokes):

- `@cf/cloudflare/clef`, `clef-flash`: `POST {api}/ai/run/@cf/cloudflare/<m>`
  `{model: "clef"|"clef-flash", state, questions{id: {type, instructions}}}`;
  context 65,536 / 24,576 tokens (an over-long state is silently truncated by
  the vendor, so this module refuses it instead), 64 questions per request.
- `typesafe/jev`: `POST {api}/ai/run` `{model, input: {state, questions{}}}`
  through the bakeoff gateway (cf-aig-gateway-id, unified billing); 32,000;
  the answer is double-enveloped (`result.state == "Completed"`, then
  `result.result{model, answers, usage}`).
- `pplx-decider-latest`, `-flash-latest`: `POST api.perplexity.ai/v1/decisions`
  `{model, state, questions{}}`, Bearer auth, 10 rps shared, 256K, 128
  questions (flash: one question per request, the vendor's advice).
- `decisions/gpt-6-luna`: `POST api.openai.com/v1/decisions` `{model:
  "gpt-6-luna", input: state, questions: [{type: predicate|choice|score,
  name, instructions, choices|levels}]}`; answers is an array.

Every vendor envelope is unwrapped to `{answers: {qid: p}, usage: {input,
...}}`: p is the yes-probability for noul/predicate, an option -> probability
map for choice/score, None for a refusal. It never synthesises spans or quotes.
"""

from __future__ import annotations

import copy
import json
import time
import urllib.error
from pathlib import Path

from . import cloudflare
from .base import Adapter, ContextExceeded, RateLimiter, http, safe_error

PPLX_URL = "https://api.perplexity.ai/v1/decisions"
OPENAI_URL = "https://api.openai.com/v1/decisions"
PPLX_LIMITER = RateLimiter(10)  # 10 requests/s per organization, both models
# Context allowances beyond bytes/3 of the body: Step 0 measured ~158 tokens
# per added OpenAI question (q1 2181 vs q20 5187), ~39 per pplx one, and Jev's
# docs sample bills 422 tokens for a ~400-byte body (a fixed prompt).
PER_QUESTION_TOKENS = {"clef": 128, "jev": 128, "pplx": 64, "openai": 256}
BASE_TOKENS = 512
# Decision rows bill no output, so a reservation has no output slack: an
# under-estimate would mark the shared ledger exceeded and stop every lane.
# Reserve twice the context estimate plus a floor (cost: fractions of a cent).
RESERVE_FACTOR = 2
RESERVE_FLOOR = 2048
DEFINITE_HTTP_ERRORS = (400, 401, 402, 403, 404, 413, 422, 429)
QUESTION_TYPES = ("noul", "choice", "score")


class ProviderHTTPError(RuntimeError):
    """A definite vendor refusal (status kept so callers can apply stop rules:
    429 and 402 stop the candidate)."""

    def __init__(self, detail, status):
        super().__init__(detail)
        self.status = status


class SystemOneAdapter(Adapter):
    decision = True
    supported_thinking = ("default",)
    strict_schema = True

    def __init__(self, model, vendor_model, *, kind, provider, route, context_limit, max_questions, limiter=None):
        super().__init__(model, vendor_model, route=route, context_limit=context_limit)
        self.kind, self.provider, self.max_questions = kind, provider, max_questions
        self.rate_limiter = limiter

    def credentials(self, key_text):
        if self.kind in ("clef", "jev"):
            return cloudflare.credentials(key_text)
        return super().credentials(key_text)

    # Request ---------------------------------------------------------------
    def render_questions(self, questions):
        if self.kind == "openai":
            rendered = []
            for q in questions:
                item = {
                    "type": "predicate" if q["type"] == "noul" else q["type"],
                    "name": q["id"],
                    "instructions": q["instructions"],
                }
                if q["type"] == "choice":
                    item["choices"] = [
                        {"value": k, "description": v or k} for k, v in q["criteria"].items()
                    ]
                elif q["type"] == "score":
                    item["levels"] = [
                        {"label": str(c), "description": str(c)} for c in q["criteria"]
                    ]
                rendered.append(item)
            return rendered
        rendered = {}
        for q in questions:
            item = {"type": q["type"], "instructions": q["instructions"]}
            if q.get("criteria") is not None:
                item["criteria"] = q["criteria"]
            rendered[q["id"]] = item
        return rendered

    def body(self, state, questions):
        rendered = self.render_questions(questions)
        if self.kind == "clef":
            return {"model": self.vendor_model, "state": state, "questions": rendered}
        if self.kind == "jev":
            return {"model": self.vendor_model, "input": {"state": state, "questions": rendered}}
        if self.kind == "pplx":
            return {"model": self.vendor_model, "state": state, "questions": rendered}
        return {"model": self.vendor_model, "input": state, "questions": rendered}

    def page_tokens(self, body, questions):
        """Pessimistic input tokens of one page (the context check)."""
        return self.estimate(body) + BASE_TOKENS + PER_QUESTION_TOKENS[self.kind] * len(questions)

    def reserve_tokens(self, body, questions):
        """Input tokens reserved for one page (see RESERVE_FACTOR)."""
        return RESERVE_FACTOR * self.page_tokens(body, questions) + RESERVE_FLOOR

    def url(self, creds):
        if self.kind == "clef":
            return cloudflare.base_url(creds) + "/run/" + self.model
        if self.kind == "jev":
            return cloudflare.base_url(creds) + "/run"
        return PPLX_URL if self.kind == "pplx" else OPENAI_URL

    def headers(self, creds):
        if self.kind == "clef":
            return cloudflare.headers(creds)
        if self.kind == "jev":
            return cloudflare.headers(creds, gateway=True)
        return {"authorization": f"Bearer {creds['api_key']}"}

    def call(self, wire, creds):
        return http(self.url(creds), wire, self.headers(creds))

    # Response --------------------------------------------------------------
    def normalise(self, raw, questions):
        """(answers {qid: p}, usage or None, error or None) for one page."""
        body, error = cloudflare.unwrap(raw)
        if error:
            return {}, None, error
        if isinstance(body, dict) and isinstance(body.get("result"), dict) and "state" in body:
            # Jev on /ai/run through the gateway: {result: {state: Completed, result: {...}}}.
            if body["state"] != "Completed":
                return {}, None, f"decision job state {body['state']!r}"
            body = body["result"]
        if not isinstance(body, dict):
            return {}, None, "decision response is not an object"
        u = body.get("usage") or {}
        usage = None
        if type(u.get("input_tokens")) is int:
            details = u.get("input_tokens_details") or {}
            cached = details.get("cached_tokens") or 0
            write = details.get("cache_write_tokens") or 0
            usage = {
                "input": u["input_tokens"],
                "cached": cached,
                "write": write,
                "output": u.get("output_tokens") or 0,
                "reasoning": (u.get("output_tokens_details") or {}).get("reasoning_tokens") or 0,
            }
        raw_answers = body.get("answers")
        if isinstance(raw_answers, list):
            raw_answers = {a.get("name"): a for a in raw_answers if isinstance(a, dict)}
        if not isinstance(raw_answers, dict):
            return {}, usage, "decision response has no answers"
        answers = {}
        for q in questions:
            a = raw_answers.get(q["id"])
            answers[q["id"]] = probability(a)
        missing = [q["id"] for q in questions if q["id"] not in raw_answers]
        return answers, usage, (f"missing answers: {missing}" if missing else None)

    def usage(self, raw):
        return self.normalise(raw, [])[1]

    def recognizes(self, doc):
        return isinstance(doc, dict) and doc.get("kind") == "systemone"


def probability(answer):
    """noul/predicate -> float; choice/score -> {option: float}; refusal -> None."""
    if not isinstance(answer, dict):
        return None
    kind = answer.get("type")
    if kind == "noul" and isinstance(answer.get("noul"), (int, float)):
        return float(answer["noul"])
    if kind == "predicate" and isinstance(answer.get("probability"), (int, float)):
        return float(answer["probability"])
    probs = answer.get("probabilities")
    if isinstance(probs, dict):
        return {str(k): float(v) for k, v in probs.items()}
    if isinstance(probs, list):
        return {str(p.get("value")): float(p.get("probability")) for p in probs if isinstance(p, dict)}
    return None


def check_questions(questions):
    ids = [q.get("id") for q in questions]
    if not questions or len(set(ids)) != len(ids) or not all(isinstance(i, str) and i for i in ids):
        raise ValueError("Questions need unique, non-empty string ids")
    for q in questions:
        if q.get("type", "noul") not in QUESTION_TYPES or not q.get("instructions"):
            raise ValueError(f"Bad question {q.get('id')!r}")
    return [{"type": "noul", **q} for q in questions]


def state_text(window_request):
    """The exact v3 `input` JSON string for a window: from a canonical payload
    (`contents`), from a window request (rendered by the Rust bridge), or the
    string itself."""
    if isinstance(window_request, str):
        return window_request
    if "contents" in window_request:
        return window_request["contents"][0]["parts"][0]["text"]
    import run  # the bridge renders the exact serving input; never re-serialise it

    windows = run.bridge(
        {"op": "prepare", "policy": "promo_ad_breaks_v3", "request": window_request, "thinking": None}
    )["windows"]
    if len(windows) != 1:
        raise ValueError("A window request must render exactly one v3 window")
    return windows[0]["payload"]["contents"][0]["parts"][0]["text"]


def build_decision_request(window_request, vendor, questions):
    """Vendor request bodies (pages) for one window and a question list.

    Pages split the questions by the vendor's per-request cap and context:
    every page carries the whole state, so a state that alone overflows the
    context raises ContextExceeded (never silent truncation).
    """
    from . import adapter_for

    adapter = adapter_for(vendor)
    state = state_text(window_request)
    questions = check_questions(questions)
    pages, current = [], []
    for q in questions:
        trial = current + [q]
        tokens = adapter.page_tokens(adapter.body(state, trial), trial)
        if current and (len(trial) > adapter.max_questions or tokens > adapter.context_limit):
            pages.append(current)
            current = [q]
        else:
            current = trial
    pages.append(current)
    bodies = []
    for page in pages:
        body = adapter.body(state, page)
        tokens = adapter.page_tokens(body, page)
        if tokens > adapter.context_limit:
            raise ContextExceeded(tokens, adapter.context_limit)
        bodies.append(body)
    return [{"questions": page, "body": body} for page, body in zip(pages, bodies)]


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def ask(model, state_text_or_request, questions, key_text, ledger, out_dir, context):
    """Reserve, call, archive and settle one window's questions on a decision model.

    Returns `{answers, usage, pages, latency_ms, reservations, cost_usd,
    errors}`. Archives `request.json` (`kind: systemone`, `state`, the
    questions), `wire-request.json` (the page bodies), `response.json`
    (`{kind: systemone, vendor: [raw per page], questions, answers}`) and
    `summary.json` (calls with reservations and usage, for budget --verify).
    A definite vendor refusal raises ProviderHTTPError (status kept); an
    uncertain dispatch or missing usage keeps its reservation and raises.
    """
    from budget import cost_usd

    from . import adapter_for

    adapter = adapter_for(model)
    if not getattr(adapter, "decision", False):
        raise ValueError(f"{model} is not a decision model")
    out_dir = Path(out_dir)
    if (out_dir / "response.json").exists() or (out_dir / "request.json").exists():
        raise RuntimeError(f"Decision archive exists, refusing overwrite: {out_dir}")
    creds = adapter.credentials(key_text)
    secrets = adapter.secrets(creds)
    questions = check_questions(copy.deepcopy(questions))
    state = state_text(state_text_or_request)
    pages = build_decision_request(state, model, questions)
    write(out_dir / "request.json", {"kind": "systemone", "model": model, "state": state, "questions": questions})
    write(out_dir / "wire-request.json", [p["body"] for p in pages])
    vendor, answers, calls, errors = [], {}, [], []
    total = {"input": 0, "cached": 0, "write": 0, "output": 0, "reasoning": 0}
    latency = 0.0

    def archive():
        write(out_dir / "response.json", {"kind": "systemone", "vendor": vendor, "questions": questions, "answers": answers})
        billed = [c for c in calls if c.get("usage")]
        write(
            out_dir / "summary.json",
            {
                "kind": "systemone",
                "model": model,
                **adapter.describe(),
                "context": context,
                "calls": calls,
                "pages": len(pages),
                "usage": total,
                "errors": errors,
                "cost_usd": round(sum(cost_usd(model, c["usage"]) for c in billed), 9),
            },
        )

    for index, page in enumerate(pages):
        tokens = adapter.reserve_tokens(page["body"], page["questions"])
        ident = ledger.reserve(model, tokens, 1, {**context, "page": index})
        if adapter.rate_limiter:
            adapter.rate_limiter.wait()
        start = time.monotonic()
        try:
            raw = adapter.call(page["body"], creds)
        except Exception as error:  # noqa: BLE001 - retain spend on any uncertain dispatch
            detail = safe_error(error, key_text, secrets)
            status = error.code if isinstance(error, urllib.error.HTTPError) else None
            definite = status in DEFINITE_HTTP_ERRORS
            ledger.finish(ident, "released" if definite else "ambiguous", error=detail)
            vendor.append({"error": detail, "status": status, "reservation": ident})
            errors.append(detail)
            archive()
            if definite:
                raise ProviderHTTPError(detail, status) from None
            raise RuntimeError(detail) from None
        elapsed = time.monotonic() - start
        latency += elapsed
        vendor.append(raw)
        page_answers, usage, error = adapter.normalise(raw, page["questions"])
        answers.update(page_answers)
        try:
            ledger.finish(ident, "settled" if usage else "ambiguous", usage=usage)
        except (ValueError, TypeError):
            ledger.finish(ident, "ambiguous", error="Invalid usage metadata")
            archive()
            raise
        calls.append(
            {
                "reservation": ident,
                "model": model,
                "page": index,
                "questions": [q["id"] for q in page["questions"]],
                "usage": usage,
                "input_estimated_bound": tokens,
                "latency_ms": round(elapsed * 1000),
                **({"answer_error": error} if error else {}),
            }
        )
        if error:
            errors.append(error)
        if not usage:
            archive()
            raise RuntimeError("Missing usage; reservation retained, stopping")
        for k in total:
            total[k] += usage.get(k, 0) or 0
        if any(e.get("reservation_exceeded") for e in ledger.snapshot()["entries"]):
            archive()
            raise RuntimeError("Provider exceeded reservation; stopping")
    archive()
    billed = [c for c in calls if c.get("usage")]
    return {
        "answers": answers,
        "usage": total,
        "pages": len(pages),
        "latency_ms": round(latency * 1000),
        "reservations": [c["reservation"] for c in calls],
        "cost_usd": round(sum(cost_usd(model, c["usage"]) for c in billed), 9),
        "errors": errors,
    }


ADAPTERS = [
    SystemOneAdapter("@cf/cloudflare/clef", "clef", kind="clef", provider="workers-ai", route="workers-ai",
                     context_limit=65_536, max_questions=64, limiter=cloudflare.WORKERS_AI_LIMITER),
    SystemOneAdapter("@cf/cloudflare/clef-flash", "clef-flash", kind="clef", provider="workers-ai", route="workers-ai",
                     context_limit=24_576, max_questions=64, limiter=cloudflare.WORKERS_AI_LIMITER),
    SystemOneAdapter("typesafe/jev", "typesafe/jev", kind="jev", provider="cloudflare-ai-gateway", route="ai-gateway",
                     context_limit=32_000, max_questions=64, limiter=cloudflare.GATEWAY_LIMITER),
    SystemOneAdapter("pplx-decider-latest", "pplx-decider-latest", kind="pplx", provider="perplexity", route="direct",
                     context_limit=256_000, max_questions=128, limiter=PPLX_LIMITER),
    SystemOneAdapter("pplx-decider-flash-latest", "pplx-decider-flash-latest", kind="pplx", provider="perplexity",
                     route="direct", context_limit=256_000, max_questions=1, limiter=PPLX_LIMITER),
    SystemOneAdapter("decisions/gpt-6-luna", "gpt-6-luna", kind="openai", provider="openai", route="direct",
                     context_limit=256_000, max_questions=128),
]

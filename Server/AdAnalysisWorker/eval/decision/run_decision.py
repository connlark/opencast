#!/usr/bin/env python3
"""Decision-model pipeline driver and archive (policy `decision_ad_breaks_v4_proto`).

Designs: `b_prime` (chunk noul + content facet), `c` (chunk choice), `d`
(two-stage: b' then per-segment refinement and one confirmation per span),
`d_c` (the same two-stage over the c localiser), `h1_c` (H1 over the c localiser),
`a` (per-segment local, +/-15 segments), `h1` (b' localiser + the unchanged
v3 generative path on neighbourhoods, see `hybrid.py`).

Probabilities only: spans carry `evidence_quote: ""` and a `decision` object.
The safety story that replaces quote receipts is in `decision/__init__.py`.

Archive per run (`<out>/<tag>/<fixture>-<n>/`): `fixture.json`,
`decision-w<k>/` (pure-decision calls, never `window-*`, which
compare_pcc_eval counts as generative windows), `refine-t<j>/`,
`confirm-s<j>/`, `window-<i>/` + `repair-<i>/` (hybrid generative calls
only), `probabilities.json`, `derivation.json`, `summary.json` in run.py's
shape. Paid calls go through Lane A's `providers.systemone.ask`, which
reserves, calls, archives and settles on the ONE shared ledger; this driver
never creates a ledger. `--stub oracle` answers from ground truth with no
network (the synthetic tree for compare_pcc_eval and the tests).
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import time
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "decision"  # noqa: A001

from . import chunking, questions  # noqa: E402
from .common import (  # noqa: E402
    POLICY,
    adapter_override,
    finite_probability,
    lane_a,
    latency,
    load_manifest,
    sha256_file,
    write,
)
from .derive import (  # noqa: E402
    DESIGNS,
    HYBRID,
    LOCALISER,
    DeriveParams,
    chunk_design as chunk_stage_design,
    confirm_key,
    derive,
    plan_confirmation,
    plan_refinement,
)

REFINE_CONTEXT_SEGMENTS = 10
CONFIRM_CONTEXT_SEGMENTS = 5
LOCAL_CONTEXT_SEGMENTS = 15  # design (a)
CONTEXT_FILL = 0.85  # never let a vendor truncate the state (Clef truncates silently)
TOKENS_PER_QUESTION_FLOOR = 40  # Step 0: ~39 tokens per added pplx question

# Fallbacks when providers.json has no value; the brief's numbers.
DEFAULT_LIMITS = {
    "pplx-decider-latest": {"vendor": "perplexity", "context_tokens": 256_000, "max_questions": 128},
    "pplx-decider-flash-latest": {"vendor": "perplexity", "context_tokens": 256_000, "max_questions": 128},
    "@cf/cloudflare/clef": {"vendor": "cloudflare", "context_tokens": 65_536, "max_questions": 64},
    "@cf/cloudflare/clef-flash": {"vendor": "cloudflare", "context_tokens": 24_576, "max_questions": 64},
    "typesafe/jev": {"vendor": "typesafe", "context_tokens": 32_000, "max_questions": 64},
    "decisions/gpt-6-luna": {"vendor": "openai", "context_tokens": 256_000, "max_questions": 64},
}
STUB_MODELS = {"oracle"}
# Two errored runs in a row stop the batch: an uncertain dispatch (e.g. the
# vendor gateway's 504 on an over-long request) keeps its reservation, so a
# systematic failure must not be repeated on every remaining fixture.
MAX_CONSECUTIVE_ERRORED_RUNS = 2


class AnswerError(ValueError):
    """A question without a usable probability: the episode fails closed."""


class VendorStop(RuntimeError):
    """429 / 402 / empty balance: stop this vendor, never work around it."""


# --- answers -------------------------------------------------------------


def _probability(value):
    if finite_probability(value):
        return float(value)
    if isinstance(value, dict):
        if value.get("type") == "refusal":
            raise AnswerError("refusal")
        for key in ("noul", "probability", "p", "yes"):
            if key in value and finite_probability(value[key]):
                return float(value[key])
    raise AnswerError("not a probability")


def _distribution(value, choices):
    if isinstance(value, dict) and value.get("type") == "refusal":
        raise AnswerError("refusal")
    probs = value.get("probabilities", value) if isinstance(value, dict) else value
    if isinstance(probs, list):
        probs = {
            item.get("value", item.get("id", item.get("choice"))): item.get("probability", item.get("p"))
            for item in probs
            if isinstance(item, dict)
        }
    if not isinstance(probs, dict):
        raise AnswerError("not a distribution")
    meta = {"type", "choice", "confidence", "name"}
    unknown = set(probs) - set(choices) - meta
    if unknown:
        raise AnswerError(f"unknown options {sorted(unknown)}")
    out = {}
    for choice in choices:
        p = probs.get(choice, 0.0)
        if not isinstance(p, (int, float)) or isinstance(p, bool) or not math.isfinite(p) or p < 0:
            raise AnswerError("bad option probability")
        out[choice] = float(p)
    total = sum(out.values())
    if total <= 0:
        raise AnswerError("empty distribution")
    return {k: v / total for k, v in out.items()}


def normalize(question_list, answers):
    """{qid: p} for noul, {qid: {option: p}} (sums to 1) for choice.

    Accepts the unwrapped `{qid: p}` Lane A returns and the raw vendor answer
    objects (pplx / Clef / Jev `{"type": "noul", "noul": p}`, choice
    `probabilities` as a map, OpenAI arrays `[{"name", "probability"}]` and
    choice `probabilities: [{"value", "probability"}]`). Saturated 0/1 answers
    are valid. Anything else raises `AnswerError`.
    """
    if isinstance(answers, list):
        answers = {a.get("name"): a for a in answers if isinstance(a, dict)}
    if not isinstance(answers, dict):
        raise AnswerError("answers is not a map")
    out = {}
    for question in question_list:
        qid = question["id"]
        if qid not in answers:
            raise AnswerError(f"missing:{qid}")
        try:
            if question["type"] == "choice":
                out[qid] = _distribution(answers[qid], list(question["criteria"]))
            else:
                out[qid] = _probability(answers[qid])
        except AnswerError as error:
            raise AnswerError(f"{qid}:{error}") from None
    return out


# --- limits and paging ---------------------------------------------------


def estimate_tokens(text):
    """Pessimistic local estimate (Lane A's rule): UTF-8 bytes / 3."""
    return math.ceil(len(text.encode()) / 3)


def question_tokens(question_list):
    return sum(
        max(TOKENS_PER_QUESTION_FLOOR, estimate_tokens(json.dumps(q, ensure_ascii=False)))
        for q in question_list
    )


def load_limits(model, providers_path=None):
    limits = dict(DEFAULT_LIMITS.get(model, {"vendor": "unknown", "context_tokens": 32_000, "max_questions": 64}))
    if providers_path and Path(providers_path).exists():
        rows = [r for r in json.loads(Path(providers_path).read_text()).get("rows", []) if r.get("model") == model]
        if rows:
            row = rows[0]
            limits["vendor"] = row.get("vendor") or limits["vendor"]
            if row.get("context_tokens"):
                limits["context_tokens"] = int(row["context_tokens"])
            if row.get("max_questions_per_request"):
                limits["max_questions"] = int(row["max_questions_per_request"])
            limits["status"] = row.get("status")
            limits["price_in_per_m"] = row.get("price_in_per_m")
    try:  # Lane A's adapter pages by these; window against the same numbers
        adapter = lane_a("providers").adapter_for(model)
        limits["context_tokens"] = min(limits["context_tokens"], int(adapter.context_limit))
        limits["max_questions"] = min(limits["max_questions"], int(adapter.max_questions))
    except Exception:  # noqa: BLE001 - stub models and absent adapters keep the table
        pass
    return limits


def plan_windows(request, chunks, design, wording, limits):
    """Contiguous chunk windows whose state + questions fit the context."""
    budget = limits["context_tokens"] * CONTEXT_FILL
    for count in range(1, len(chunks) + 1):
        size = math.ceil(len(chunks) / count)
        spans = [(a, min(a + size, len(chunks)) - 1) for a in range(0, len(chunks), size)]
        if all(
            estimate_tokens(
                questions.render_state(
                    request, chunks[a : b + 1], indices=(chunks[a].first, chunks[b].last)
                )
            )
            + question_tokens(questions.chunk_questions(chunks[a : b + 1], design, wording))
            <= budget
            for a, b in spans
        ):
            return spans
    raise ValueError("A single chunk does not fit the vendor context")


# --- askers --------------------------------------------------------------


class SystemOneAsker:
    """Lane A's `providers.systemone.ask` (reserve, call, archive, settle).

    One call record per vendor page (= HTTP request = ledger reservation),
    read from the per-ask `summary.json` that `ask` writes, so the run
    summary's `cost_usd` equals the cost of its own reserved calls
    (`budget.py --verify` dedupes by reservation id)."""

    def __init__(self, model, key_text, ledger):
        self.model, self.key_text, self.ledger = model, key_text, ledger
        self.ask = lane_a("providers.systemone").ask
        self.cost = lane_a("budget").cost_usd

    def __call__(self, stage, directory, state, question_list, context, hints):
        try:
            result = self.ask(self.model, state, question_list, self.key_text, self.ledger, directory, context)
        except Exception as error:  # noqa: BLE001 - classify, never retry here
            text = str(error)
            if getattr(error, "status", None) in (402, 429) or re.search(r"\b(429|402)\b|2021|insufficient|balance|quota", text, re.I):
                raise VendorStop(text[:400]) from None
            raise
        pages = json.loads((Path(directory) / "summary.json").read_text())["calls"]
        result["call_records"] = [
            {
                "model": self.model,
                "reservation": page["reservation"],
                "page": page["page"],
                "questions": len(page["questions"]),
                "usage": {k: int(page["usage"].get(k) or 0) for k in ("input", "cached", "write", "output", "reasoning")},
                "elapsed_s": round(page["latency_ms"] / 1000, 3),
                "cost_usd": round(self.cost(self.model, page["usage"]), 9),
            }
            for page in pages
            if page.get("usage")
        ]
        return result


def segment_truth(request, truth):
    """Ground truth per array index: 1.0 pods, 0.5 optional, 0.0 elsewhere."""
    positions = {s["id"]: i for i, s in enumerate(request["segments"])}
    values = [0.0] * len(request["segments"])
    for key, value in (("optional", 0.5), ("pods", 1.0)):
        for a, b in truth.get(key, []):
            for i in range(positions[a], positions[b] + 1):
                values[i] = max(values[i], value)
    return values


class OracleAsker:
    """Answers from ground truth (E0, the stub, the tests). Duration-weighted
    means stand in for calibrated chunk answers; the confirmation answer is
    one minus the passage's share of program (truth 0) seconds."""

    def __init__(self, request, truth, archive=False):
        self.segments = request["segments"]
        self.truth = segment_truth(request, truth)
        self.archive = archive

    def _mean(self, lo, hi, fn):
        weights = [max(1e-9, self.segments[i]["end"] - self.segments[i]["start"]) for i in range(lo, hi + 1)]
        return sum(w * fn(self.truth[lo + n]) for n, w in enumerate(weights)) / sum(weights)

    def answer(self, question, context):
        qid = question["id"]
        if qid == "span_confirm":
            lo, hi = context["passage"]
            return 1.0 - self._mean(lo, hi, lambda t: 1.0 if t == 0.0 else 0.0)
        kind, _, facet = qid.partition("_")
        index = int(kind[1:])
        if kind[0] == "s":
            return self.truth[index]
        chunk = context["chunks"][index]
        ad = self._mean(chunk.first, chunk.last, lambda t: t)
        if facet == "ad":
            return ad
        if facet == "content":
            return 1.0 - ad
        share = ad / 3
        return {"ad_read": share, "inserted_ad": share, "promo": share, "content": 1.0 - ad, "transition": 0.0}

    def __call__(self, stage, directory, state, question_list, context, hints):
        answers = {q["id"]: self.answer(q, hints) for q in question_list}
        tokens = estimate_tokens(state) + question_tokens(question_list)
        if self.archive:
            write(directory / "request.json", {"kind": "systemone", "model": "stub:oracle", "state": state, "questions": question_list, "context": context})
            write(directory / "response.json", {"kind": "systemone", "vendor": [], "questions": question_list, "answers": answers})
        return {"answers": answers, "usage": {"input": tokens, "cached": 0, "write": 0, "output": 0, "reasoning": 0}, "pages": 1, "latency_ms": 0, "cost_usd": 0.0}


# --- the pipeline --------------------------------------------------------


def _call_record(stage, tag, result, question_list, elapsed):
    usage = result.get("usage") or {}
    return {
        "stage": stage,
        "tag": tag,
        "questions": len(question_list),
        "pages": result.get("pages", 1),
        "usage": {
            "input": int(usage.get("input") or 0),
            "cached": 0,
            "write": 0,
            "output": 0,
            "reasoning": 0,
        },
        "elapsed_s": round(result.get("latency_ms", elapsed * 1000) / 1000, 3),
        "cost_usd": result.get("cost_usd", 0.0),
    }


def groups_of(question_list, size):
    """Consecutive groups of at most `size` questions (None: one group)."""
    if size is None:
        return [question_list]
    if size < 1:
        raise ValueError("questions per request must be >= 1")
    return [question_list[g : g + size] for g in range(0, len(question_list), size)]


def analyse(request, design, spec, params, wording, asker, limits, run_dir, context, calls, questions_per_request=None):
    """Ask, derive, guard; appends every call to `calls` as it happens (so an
    exception never loses a paid call's record). Returns (chunks, doc, derivation).

    `questions_per_request` N splits every decision-window and refinement
    question list into consecutive groups of N, one `ask` per group, archived
    as `decision-w<k>g<g>/` and `refine-t<j>g<g>/` (E4's joint-format check
    and any vendor grouping); None keeps one ask per window or region
    (`decision-w<k>/`, `refine-t<j>/`). The vendor adapter still pages each
    ask by its own `max_questions`."""
    segments = request["segments"]
    local = design == "a"
    chunks = chunking.make(segments, {"kind": "segments", "size": 1} if local else spec)
    chunking.check_tiling(chunks, len(segments))
    chunk_design = "b_prime" if design in ("d", "h1") else chunk_stage_design(design)
    doc = {"chunks": [None] * len(chunks), "refine": {}, "confirm": {}}

    def ask(stage, tag, state, question_list, extra):
        started = time.monotonic()
        hints = {"chunks": chunks, **extra}
        safe = {k: v for k, v in extra.items() if k != "chunks"}
        # `tag` stays the run tag (ledger cost attribution); `ask` names the archive dir.
        result = asker(stage, run_dir / tag, state, question_list, {**context, "stage": stage, "ask": tag, **safe}, hints)
        if "call_records" in result:
            calls.extend({"stage": stage, "tag": tag, **record} for record in result["call_records"])
        else:
            calls.append(_call_record(stage, tag, result, question_list, time.monotonic() - started))
        return normalize(question_list, result["answers"])

    def ask_grouped(stage, tag, state, question_list, extra):
        if questions_per_request is None:
            return ask(stage, tag, state, question_list, extra)
        answers = {}
        for g, group in enumerate(groups_of(question_list, questions_per_request)):
            answers.update(ask(stage, f"{tag}g{g}", state, group, {**extra, "group": g}))
        return answers

    if local:
        for i in range(len(segments)):
            lo, hi = max(0, i - LOCAL_CONTEXT_SEGMENTS), min(len(segments) - 1, i + LOCAL_CONTEXT_SEGMENTS)
            qs = questions.segment_question(i, wording)
            state = questions.render_state(request, indices=(lo, hi), labels=True, mark={i})
            answers = ask("decision", f"decision-w{i}", state, qs, {})
            doc["chunks"][i] = {"p_ad": answers[qs[0]["id"]], "p_content": None}
    else:
        for w, (a, b) in enumerate(plan_windows(request, chunks, chunk_design, wording, limits)):
            window = chunks[a : b + 1]
            qs = questions.chunk_questions(window, chunk_design, wording)
            state = questions.render_state(request, window, indices=(window[0].first, window[-1].last))
            answers = ask_grouped("decision", f"decision-w{w}", state, qs, {"window_chunks": [a, b]})
            for chunk in window:
                k = chunk.index
                if chunk_design == "c":
                    doc["chunks"][k] = {"choice": answers[f"c{k}_kind"]}
                else:
                    doc["chunks"][k] = {"p_ad": answers[f"c{k}_ad"], "p_content": answers[f"c{k}_content"]}
    if design in ("d", "d_c"):
        tag = 0
        for item in plan_refinement(request, chunks, doc, design, params):
            run = item["run"]
            run_lo, run_hi = chunks[run["first"]].first, chunks[run["last"]].last
            for lo, hi in item["regions"]:
                excerpt = (max(0, lo - REFINE_CONTEXT_SEGMENTS), min(len(segments) - 1, hi + REFINE_CONTEXT_SEGMENTS))
                mark = {i for i in range(run_lo, run_hi + 1) if excerpt[0] <= i <= excerpt[1]}
                qs = questions.refine_questions(range(lo, hi + 1), wording)
                state = questions.render_state(
                    request, indices=excerpt, labels=True, mark=mark, note=questions.WORDINGS[wording]["refine_note"]
                )
                answers = ask_grouped("refine", f"refine-t{tag}", state, qs, {"region": [lo, hi], "run": [run["first"], run["last"]]})
                for i in range(lo, hi + 1):
                    doc["refine"].setdefault(str(i), answers[f"s{i}_in"])
                tag += 1
        for j, item in enumerate(plan_confirmation(request, chunks, doc, params, design)):
            lo, hi = item["segments"]
            excerpt = (max(0, lo - CONFIRM_CONTEXT_SEGMENTS), min(len(segments) - 1, hi + CONFIRM_CONTEXT_SEGMENTS))
            qs = questions.confirm_question(wording)
            state = questions.render_state(
                request, indices=excerpt, labels=True, mark=set(range(lo, hi + 1)), note=questions.WORDINGS[wording]["confirm_note"]
            )
            answers = ask("confirm", f"confirm-s{j}", state, qs, {"passage": [lo, hi]})
            doc["confirm"][confirm_key(lo, hi)] = answers["span_confirm"]
    derivation = derive(request, chunks, doc, LOCALISER.get(design, design), params)
    return chunks, doc, derivation


def probabilities_doc(request, chunks, doc, design, spec):
    return {
        "design": design,
        "chunking": spec,
        "segment_ids": [s["id"] for s in request["segments"]],
        "chunk_ranges": [c.as_dict() for c in chunks],
        **doc,
    }


def summarise(*, model_label, model_key, design, spec, params, wording, request, fixture, derivation, calls, elapsed, error, extra=None):
    run = lane_a("run")
    validation = derivation["validation"]
    installed = validation["spans"] if validation["complete"] and not error else []
    return {
        "model": model_label,
        "model_key": model_key,
        "policy": POLICY,
        "design": design,
        "thinking": "default",
        "question_set": questions.question_set(wording),
        "chunking": {**spec, "id": chunking.spec_id(spec)},
        "derive_params": {**params.as_dict(), "sha256": params.sha256()},
        "raw_spans": derivation["raw_spans"],
        "validation": validation,
        "guards": derivation["guards"],
        "metrics": run.measure(request, installed, fixture["ground_truth"]),
        "calls": calls,
        "elapsed_s": round(elapsed, 3),
        "requests_total": len(calls),
        "pages_total": sum(c.get("pages", 1) for c in calls),
        "input_tokens_total": sum(c["usage"]["input"] for c in calls),
        "cost_usd": round(sum(c.get("cost_usd", 0.0) for c in calls), 9),
        "cost_by_stage": {
            stage: round(sum(c.get("cost_usd", 0.0) for c in calls if c.get("stage") == stage), 9)
            for stage in sorted({c.get("stage") for c in calls if c.get("stage")})
        },
        "latency": latency([c.get("elapsed_s") for c in calls]),
        "audio_duration_s": (request.get("transcript") or {}).get("audio_duration"),
        "error": error,
        **(extra or {}),
    }


def run_fixture(*, fixture, request, request_path, manifest_sha, design, spec, params, wording, asker, limits, run_dir, model_label, model_key, repeat, tag, hybrid_runner=None, questions_per_request=None, vendor_override=None):
    if run_dir.exists():
        raise RuntimeError(f"Run exists, refusing overwrite: {run_dir}")
    run_dir.mkdir(parents=True)
    write(
        run_dir / "fixture.json",
        {
            "fixture": fixture,
            "request_sha256": sha256_file(request_path),
            "manifest_sha256": manifest_sha,
            "question_set_sha256": questions.question_set(wording)["sha256"],
            "question_set": questions.question_set(wording),
            "derive_params_sha256": params.sha256(),
            "design": design,
            "chunking": {**spec, "id": chunking.spec_id(spec)},
            "model": model_label,
            "questions_per_request": questions_per_request,
            "vendor_override": vendor_override,
        },
    )
    started = time.monotonic()
    context = {"tag": tag, "fixture": fixture["name"], "repeat": repeat}
    error = None
    extra = {"questions_per_request": questions_per_request, "vendor_override": vendor_override}
    if design in HYBRID:
        extra["localiser"] = LOCALISER[design]
    calls = []
    stop = None
    try:
        chunks, doc, derivation = analyse(
            request, design, spec, params, wording, asker, limits, run_dir, context, calls, questions_per_request
        )
        write(run_dir / "probabilities.json", probabilities_doc(request, chunks, doc, design, spec))
        if design in HYBRID:
            derivation, hybrid_extra = hybrid_runner(request, chunks, doc, derivation, run_dir, context, calls)
            extra.update(hybrid_extra)
    except Exception as exc:  # noqa: BLE001 - archive failures, fail closed
        error = f"{type(exc).__name__}: {exc}"[:1600]
        stop = exc if isinstance(exc, VendorStop) else None
        derivation = {
            "raw_spans": [],
            "guards": {},
            "validation": {"complete": False, "spans": [], "warnings": [f"decision_error:{type(exc).__name__}"], "notices": []},
        }
    write(run_dir / "derivation.json", derivation)
    summary = summarise(
        model_label=model_label, model_key=model_key, design=design, spec=spec, params=params, wording=wording,
        request=request, fixture=fixture, derivation=derivation, calls=calls,
        elapsed=time.monotonic() - started, error=error, extra=extra,
    )
    write(run_dir / "summary.json", summary)
    if stop is not None:
        raise stop
    return summary


def vendor_override_record(model, max_questions, evidence):
    """The archived record of an in-process adapter paging override: the
    vendor, the adapter's own cap, the cap used, and the probe archive that
    shows the vendor accepts that many questions in one request."""
    if max_questions is None:
        return None
    if max_questions < 1:
        raise ValueError("--vendor-max-questions must be >= 1")
    probe = Path(evidence or "") / "probe.json"
    if not evidence or not probe.exists():
        raise ValueError("--vendor-max-questions needs --vendor-override-evidence DIR holding the probe's probe.json")
    doc = json.loads(probe.read_text())
    if doc.get("model") != model or doc.get("pages") != 1 or doc.get("errors"):
        raise ValueError("The evidence probe is for another model, was paged, or failed")
    adapter = lane_a("providers").adapter_for(model)
    return {
        "model": model,
        "vendor": getattr(adapter, "provider", None),
        "adapter_max_questions": int(adapter.max_questions),
        "max_questions": int(max_questions),
        "evidence": str(Path(evidence)),
        "evidence_questions_in_one_request": doc.get("questions_in_one_request"),
        "evidence_usage_input": (doc.get("usage") or {}).get("input"),
        "scope": "in-process adapter copy (common.adapter_override); Lane A's adapter unchanged",
    }


def sanitize(model):
    return re.sub(r"[/@]", "_", model)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--model", required=True, help="systemone model key, or the stub name with --stub")
    parser.add_argument("--stub", choices=sorted(STUB_MODELS), help="offline answers, no network, cost 0")
    parser.add_argument("--key-file", type=Path)
    parser.add_argument("--ledger", type=Path, help="the ONE shared ledger (must already exist)")
    parser.add_argument("--max-spend", type=float, help="the ledger's current cap")
    parser.add_argument("--providers", type=Path, help="ROOT/providers.json for context and question limits")
    parser.add_argument("--design", choices=DESIGNS, required=True)
    parser.add_argument("--chunking", default="seg10")
    parser.add_argument("--wording", default="w1", choices=sorted(questions.WORDINGS))
    parser.add_argument("--derive-params", default="{}", help="JSON overrides of DeriveParams")
    parser.add_argument("--fixtures", nargs="*")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--h1-model")
    parser.add_argument("--h1-key-file", type=Path)
    parser.add_argument("--h1-thinking", default="low")
    parser.add_argument("--repair", action="store_true")
    parser.add_argument(
        "--questions-per-request", type=int, metavar="N",
        help="split each window's (and refinement region's) questions into asks of N (archived decision-w<k>g<g>)",
    )
    parser.add_argument(
        "--vendor-max-questions", type=int, metavar="N",
        help="page the vendor at N questions per request (in-process adapter copy; needs --vendor-override-evidence)",
    )
    parser.add_argument("--vendor-override-evidence", type=Path, help="probe archive dir showing the vendor accepts N questions")
    args = parser.parse_args(argv)
    if args.questions_per_request is not None and args.questions_per_request < 1:
        parser.error("--questions-per-request must be >= 1")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.tag) or not 1 <= args.repeats <= 10:
        parser.error("Unsafe tag or repeats")
    spec = {"kind": "segments", "size": 1} if args.design == "a" else chunking.parse_spec(args.chunking)
    params = DeriveParams().with_(**json.loads(args.derive_params))
    manifest = load_manifest(args.manifest)
    manifest_sha = sha256_file(args.manifest)
    names = args.fixtures or list(manifest)
    if set(names) - set(manifest):
        parser.error("Unknown fixture")
    if args.vendor_max_questions is not None and args.stub:
        parser.error("--vendor-max-questions applies to paid models only")
    try:
        vendor_override = vendor_override_record(args.model, args.vendor_max_questions, args.vendor_override_evidence)
    except (ValueError, KeyError) as error:
        parser.error(str(error))
    with adapter_override(args.model, args.vendor_max_questions):
        _run(args, parser, spec, params, manifest, manifest_sha, names, vendor_override)


def _run(args, parser, spec, params, manifest, manifest_sha, names, vendor_override):
    limits = load_limits(args.model, args.providers)
    ledger = None
    if args.stub:
        model_label, model_key = f"stub:{args.stub}", f"stub:{args.stub}"
    else:
        if not (args.key_file and args.ledger and args.max_spend):
            parser.error("--key-file, --ledger and --max-spend are required for paid models")
        if not args.ledger.exists():
            parser.error("The shared ledger must already exist; this driver never creates one")
        ledger = lane_a("budget").Ledger(args.ledger, args.max_spend)
        key_text = args.key_file.read_text().strip()
        model_label, model_key = f"{limits['vendor']}:{args.model}", args.model
    hybrid_runner = None
    if args.design in HYBRID:
        from . import hybrid

        hybrid_runner = hybrid.runner(
            model=args.h1_model, key_file=args.h1_key_file, ledger=ledger, thinking=args.h1_thinking,
            repair=args.repair, stub=args.stub, truth_of={n: manifest[n][0]["ground_truth"] for n in names},
        )
    errored = 0
    for name in names:
        fixture, request, request_path = manifest[name]
        for repeat in range(1, args.repeats + 1):
            asker = OracleAsker(request, fixture["ground_truth"], archive=True) if args.stub else SystemOneAsker(args.model, key_text, ledger)
            run_dir = args.out / args.tag / f"{name}-{repeat}"
            summary = run_fixture(
                fixture=fixture, request=request, request_path=request_path, manifest_sha=manifest_sha,
                design=args.design, spec=spec, params=params, wording=args.wording, asker=asker, limits=limits,
                run_dir=run_dir, model_label=model_label, model_key=model_key, repeat=repeat, tag=args.tag,
                hybrid_runner=hybrid_runner, questions_per_request=args.questions_per_request,
                vendor_override=vendor_override,
            )
            print(json.dumps({
                "run": str(run_dir), "complete": summary["validation"]["complete"],
                "pods": [round(p["coverage"], 3) for p in summary["metrics"]["pods"]],
                "false_skip_s": summary["metrics"]["false_skip_s"], "requests": summary["requests_total"],
                "cost_usd": summary["cost_usd"], "error": summary["error"],
                "budget": ledger.snapshot()["totals"] if ledger else None,
            }), flush=True)
            errored = errored + 1 if summary["error"] else 0
            if errored >= MAX_CONSECUTIVE_ERRORED_RUNS:
                raise SystemExit(f"{errored} consecutive errored runs (last: {summary['error'][:200]}); batch stopped")


if __name__ == "__main__":
    main()

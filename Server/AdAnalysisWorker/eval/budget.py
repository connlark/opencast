"""Atomic, pessimistic model-spend ledger. Standard text inference only.

Rows are (input, cached input, cache write, output) USD per million tokens.
The six 2026-09 rows were verified 2026-09-10 against
https://developers.openai.com/api/docs/pricing and
https://ai.google.dev/gemini-api/docs/pricing . The 2026-10 bakeoff rows were
verified 2026-10-17/18 against the vendor pages recorded per model in the
bakeoff's providers.json (`price_source_url`): ai.google.dev pricing,
developers.openai.com pricing and /guides/decisions,
platform.claude.com/docs/en/about-claude/pricing,
developers.cloudflare.com/workers-ai/platform/pricing/ and the model pages
(models/clef/, ai/models/typesafe/jev/), docs.perplexity.ai decisions.

Cached/write conventions: Gemini 0.1x / 1x, OpenAI and Anthropic 0.1x /
1.25x, Workers AI and the decision models flat (one rate for every input
token) except where the vendor page states otherwise (Jev: cached $0.00).
Decision models bill input only (output 0). Reconciled 2026-10-18 against
providers.json: clef-flash is $0.038 (the plan's 0.24 was clef's), Jev's
cached input is $0.00; every other row matched.

Workers AI bills neurons ($0.011 per 1,000 neurons); its rows are Cloudflare's
published per-token equivalents, so the ledger meters tokens, not neurons.
AI Gateway unified billing charges a 5 % fee on credit purchase; that fee is
outside this ledger (reported separately), and the `cf/*` rows are the
providers' list prices passed through without markup.

The 2026-10-23 frontier rows were verified that day:
`claude-opus-5-5` against platform.claude.com/docs/en/about-claude/pricing
($4 input, $5 5-minute cache write, $0.20 cache hit = 0.05x, $20 output; the
full 1M context bills at standard rates, no long-context tier) and
`gpt-6.1-sol` against developers.openai.com/api/docs/pricing ($2 input,
$0.10 cached = 0.05x, $2.50 cache write, $10 output; its long-context tier
is the generic OpenAI rule below). `gpt-6-astra` was re-verified unchanged
on the same page the same day.

Gemini 3.x promotional rates expire 2026-12-31 (they double 2027-01-01):
every `gemini-3.` key refuses to price after that date. No search/tools,
regional endpoint, batch, or audio pricing.
"""

from __future__ import annotations

import contextlib
import datetime
import fcntl
import json
import math
import os
import tempfile
import uuid
from pathlib import Path

MAX_AUTHORIZED_CAP = 50

PRICES = {
    # input, cached input, cache write, output; per million tokens
    "gemini-3.5-flash": (1.5, 0.15, 1.5, 9),
    "gemini-3.8-flash": (0.75, 0.075, 0.75, 3.75),
    "gpt-6-astra": (10, 1, 12.5, 50),
    # 2026-10-23 frontier rows, direct; see the docstring.
    "gpt-6.1-sol": (2, 0.10, 2.5, 10),
    "claude-opus-5-5": (4, 0.20, 5, 20),
    "gpt-5.6-sol": (4, 0.4, 5, 20),
    "gpt-5.6-terra": (2, 0.2, 2.5, 12),
    "gpt-5.6-luna": (0.2, 0.02, 0.25, 1.2),
    # 2026-10 bakeoff: cheap generative models, direct.
    "gemini-3.1-flash-lite": (0.25, 0.025, 0.25, 1.5),
    "gemini-2.5-flash-lite": (0.10, 0.01, 0.10, 0.40),
    "gpt-6-luna": (0.10, 0.01, 0.125, 0.50),
    "claude-haiku-5-5": (0.10, 0.01, 0.125, 0.50),
    # Same models through AI Gateway unified billing, at list price.
    "cf/openai/gpt-6-luna": (0.10, 0.01, 0.125, 0.50),
    "cf/anthropic/claude-haiku-5.5": (0.10, 0.01, 0.125, 0.50),
    "cf/google/gemini-3.8-flash": (0.75, 0.075, 0.75, 3.75),
    # Workers AI (token equivalents of neuron pricing), flat input.
    "@cf/google/gemma-4-26b-a4b-it": (0.10, 0.10, 0.10, 0.30),
    "@cf/qwen/qwen3-30b-a3b-fp8": (0.051, 0.051, 0.051, 0.335),
    "@cf/openai/gpt-oss-120b": (0.35, 0.35, 0.35, 0.75),
    # Decision models: input only.
    "@cf/cloudflare/clef": (0.24, 0.24, 0.24, 0),
    "@cf/cloudflare/clef-flash": (0.038, 0.038, 0.038, 0),
    # Jev's page: cached input $0.00 per M (reconciled from providers.json).
    "typesafe/jev": (0.042, 0.0, 0.042, 0),
    "pplx-decider-latest": (0.02, 0.02, 0.02, 0),
    "pplx-decider-flash-latest": (0.01, 0.01, 0.01, 0),
    "decisions/gpt-6-luna": (0.10, 0.10, 0.10, 0),
}


def _long_context_tiers():
    tiers = {}
    for model, row in PRICES.items():
        # OpenAI long-context tier: input classes x2, output x1.5 above 272K.
        if model.startswith(("gpt-", "cf/openai/gpt-", "decisions/gpt-")):
            tiers[model] = (272_000, (*[x * 2 for x in row[:3]], row[3] * 1.5))
    # Haiku 5.5: prompts above 100,000 tokens bill the whole call at 5x.
    for model in ("claude-haiku-5-5", "cf/anthropic/claude-haiku-5.5"):
        tiers[model] = (100_000, (0.50, 0.05, 0.625, 2.50))
    return tiers


# model -> (input tokens above which the tier applies, tier row)
LONG_CONTEXT_TIERS = _long_context_tiers()
GEMINI_3_PRICE_EXPIRY = datetime.date(2026, 12, 31)


def rates(model, tokens):
    if "gemini-3." in model and datetime.datetime.now(
        datetime.UTC
    ).date() > GEMINI_3_PRICE_EXPIRY:
        raise ValueError("Refresh expired Gemini 3.x pricing before inference")
    result = PRICES[model]
    tier = LONG_CONTEXT_TIERS.get(model)
    if tier and tokens > tier[0]:
        result = tier[1]
    return result


def cost_usd(model, usage):
    """Billed USD for one call's usage (the ledger's settlement formula)."""
    price = rates(model, usage["input"])
    return (
        (usage["input"] - usage["cached"] - usage["write"]) * price[0]
        + usage["cached"] * price[1]
        + usage["write"] * price[2]
        + usage["output"] * price[3]
    ) / 1_000_000


def price_snapshot():
    return {
        "prices": {k: list(v) for k, v in PRICES.items()},
        "tiers": {k: [t, list(row)] for k, (t, row) in LONG_CONTEXT_TIERS.items()},
    }


class BudgetExceeded(RuntimeError):
    pass


class Ledger:
    def __init__(self, path: Path, cap: float):
        if not math.isfinite(cap) or not 0 < cap <= MAX_AUTHORIZED_CAP:
            raise ValueError(
                f"This bake-off requires a finite cap in (0, ${MAX_AUTHORIZED_CAP}]"
            )
        self.path, self.cap = path, cap
        path.parent.mkdir(parents=True, exist_ok=True)
        snapshot = price_snapshot()
        with self.locked() as doc:
            if not doc:
                doc.update(cap_usd=cap, **snapshot, entries=[])
            elif (
                doc["cap_usd"] != cap
                or doc["prices"] != snapshot["prices"]
                or doc.get("tiers") != snapshot["tiers"]
            ):
                raise ValueError(
                    "Ledger cap or prices changed; do not bypass existing reservations"
                )

    def authorize_increase(self, new_cap: float, authorization: str):
        """Record an explicitly authorized increase, never reset prior spend."""
        if (
            not math.isfinite(new_cap)
            or not self.cap < new_cap <= MAX_AUTHORIZED_CAP
            or not authorization.strip()
        ):
            raise ValueError(
                f"Supply an authorized increase within the ${MAX_AUTHORIZED_CAP} ceiling"
            )
        with self.locked() as doc:
            if doc["cap_usd"] != self.cap:
                raise ValueError("Ledger cap changed concurrently")
            if any(e["state"] == "reserved" for e in doc["entries"]):
                raise ValueError("Finish active inference before changing the cap")
            doc.setdefault("cap_authorizations", []).append(
                {
                    "previous_cap_usd": self.cap,
                    "new_cap_usd": new_cap,
                    "authorization": authorization,
                    "at": datetime.datetime.now(datetime.UTC).isoformat(),
                }
            )
            doc["cap_usd"] = new_cap
        self.cap = new_cap

    @contextlib.contextmanager
    def locked(self):
        with self.path.with_suffix(".lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            doc = json.loads(self.path.read_text()) if self.path.exists() else {}
            yield doc
            doc["totals"] = self.totals(doc)
            with tempfile.NamedTemporaryFile(
                mode="w", dir=self.path.parent, delete=False
            ) as tmp:
                json.dump(doc, tmp, indent=2)
                tmp.write("\n")
                tmp.flush()
                os.fsync(tmp.fileno())
                name = tmp.name
            os.replace(name, self.path)

    @staticmethod
    def totals(doc):
        actual = sum(
            e.get("actual_usd", 0)
            for e in doc.get("entries", [])
            if e["state"] == "settled"
        )
        reserved = sum(
            e["reserved_usd"]
            for e in doc.get("entries", [])
            if e["state"] in ("reserved", "ambiguous")
        )
        return {
            "confirmed_usd": round(actual, 9),
            "reserved_usd": round(reserved, 9),
            "committed_usd": round(actual + reserved, 9),
            "remaining_usd": round(doc.get("cap_usd", 0) - actual - reserved, 9),
        }

    def reserve(self, model, input_tokens, max_output, context):
        if (
            type(input_tokens) is not int
            or input_tokens < 0
            or type(max_output) is not int
            or max_output <= 0
        ):
            raise ValueError("Invalid token bounds")
        price = rates(model, input_tokens)
        amount = (input_tokens * max(price[:3]) + max_output * price[3]) / 1_000_000
        with self.locked() as doc:
            if doc["cap_usd"] != self.cap:
                raise ValueError("Reopen the ledger with its current authorized cap")
            if any(e.get("reservation_exceeded") for e in doc["entries"]):
                raise BudgetExceeded(
                    "A provider exceeded its reservation; review the ledger before any more calls"
                )
            if self.totals(doc)["committed_usd"] + amount > self.cap:
                raise BudgetExceeded(
                    f"Next call reserves ${amount:.4f}, exceeding remaining budget"
                )
            ident = uuid.uuid4().hex
            doc["entries"].append(
                {
                    "id": ident,
                    "model": model,
                    "input_bound": input_tokens,
                    "max_output": max_output,
                    "reserved_usd": amount,
                    "state": "reserved",
                    "context": context,
                    "at": datetime.datetime.now(datetime.UTC).isoformat(),
                }
            )
        return ident

    def finish(self, ident, state, usage=None, error=None):
        with self.locked() as doc:
            entry = next(e for e in doc["entries"] if e["id"] == ident)
            if entry["state"] != "reserved":
                raise ValueError("Attempt already settled")
            if state not in ("settled", "ambiguous", "released"):
                raise ValueError("Invalid state")
            if state == "settled":
                if not usage or any(
                    type(usage.get(k)) is not int or usage[k] < 0
                    for k in ("input", "cached", "write", "output")
                ):
                    raise ValueError("Unconfirmed usage must retain reservation")
                if usage["cached"] + usage["write"] > usage["input"]:
                    raise ValueError("Invalid usage categories")
                amount = cost_usd(entry["model"], usage)
                entry.update(actual_usd=amount, usage=usage)
                if amount > entry["reserved_usd"] + 1e-9:
                    # Record the billed amount and stop future calls, never hide it.
                    entry["reservation_exceeded"] = True
            entry["state"] = state
            if error:
                entry["error"] = error

    def snapshot(self):
        with self.locked() as doc:
            return json.loads(json.dumps(doc))


USAGE_FIELDS = ("input", "cached", "write", "output", "reasoning")
VERIFY_TOLERANCE_USD = 0.01


def verify(ledger_path, roots):
    """Reconcile archived summary.json usage and cost with the ledger.

    Every `summary.json` under the roots contributes its `calls` (deduplicated
    by reservation id, so a pipeline summary that nests per-call summaries is
    not double counted). Per summary, `cost_usd` must equal the cost of its
    own calls; per model and overall, the archived calls must equal the
    ledger's settled entries. Returns (report, ok).
    """
    doc = json.loads(Path(ledger_path).read_text())
    settled = {e["id"]: e for e in doc.get("entries", []) if e["state"] == "settled"}
    archived = {}
    summary_issues = []
    files = 0
    for root in roots:
        for path in sorted(Path(root).rglob("summary.json")):
            try:
                summary = json.loads(path.read_text())
            except ValueError:
                summary_issues.append({"summary": str(path), "issue": "unreadable"})
                continue
            if not isinstance(summary, dict) or "calls" not in summary:
                continue
            files += 1
            own = 0.0
            for call in summary.get("calls") or []:
                usage, ident = call.get("usage"), call.get("reservation")
                if not usage or not ident:
                    continue
                model = call.get("model") or summary.get("model")
                own += cost_usd(model, usage)
                archived.setdefault(ident, (model, usage, str(path)))
            if "cost_usd" in summary and abs(summary["cost_usd"] - own) > 1e-6:
                summary_issues.append(
                    {
                        "summary": str(path),
                        "issue": "cost_usd differs from its calls",
                        "cost_usd": summary["cost_usd"],
                        "calls_usd": round(own, 9),
                    }
                )

    def tally(rows):
        out = {}
        for model, usage in rows:
            item = out.setdefault(
                model, {"calls": 0, "usd": 0.0, **{k: 0 for k in USAGE_FIELDS}}
            )
            item["calls"] += 1
            item["usd"] += cost_usd(model, usage)
            for k in USAGE_FIELDS:
                item[k] += usage.get(k, 0) or 0
        for item in out.values():
            item["usd"] = round(item["usd"], 9)
        return out

    ledger_models = tally((e["model"], e["usage"]) for e in settled.values())
    archive_models = tally((m, u) for m, u, _ in archived.values())
    per_model = {}
    ok = not summary_issues
    for model in sorted(set(ledger_models) | set(archive_models)):
        a = ledger_models.get(model, {"usd": 0.0, "calls": 0})
        b = archive_models.get(model, {"usd": 0.0, "calls": 0})
        diff = round(b["usd"] - a["usd"], 9)
        usage_match = all(a.get(k, 0) == b.get(k, 0) for k in ("input", "cached", "write", "output"))
        agrees = abs(diff) <= VERIFY_TOLERANCE_USD and usage_match
        ok = ok and agrees
        per_model[model] = {"ledger": a, "archives": b, "diff_usd": diff, "agrees": agrees}
    ledger_total = round(sum(e.get("actual_usd", 0) for e in settled.values()), 9)
    archive_total = round(sum(cost_usd(m, u) for m, u, _ in archived.values()), 9)
    overall = round(archive_total - ledger_total, 9)
    ok = ok and abs(overall) <= VERIFY_TOLERANCE_USD
    report = {
        "ledger": str(ledger_path),
        "roots": [str(r) for r in roots],
        "summaries_with_calls": files,
        "ledger_settled_usd": ledger_total,
        "archived_usd": archive_total,
        "diff_usd": overall,
        "tolerance_usd": VERIFY_TOLERANCE_USD,
        "ledger_totals": doc.get("totals"),
        "unarchived_settled_reservations": sorted(set(settled) - set(archived)),
        "archived_reservations_not_settled": sorted(set(archived) - set(settled)),
        "summary_issues": summary_issues,
        "per_model": per_model,
        "ok": ok,
    }
    return report, ok


if __name__ == "__main__":
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        description="Record an authorized cap increase, or --verify archives against the ledger"
    )
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--roots", type=Path, nargs="+")
    parser.add_argument("--previous-cap", type=float)
    parser.add_argument("--new-cap", type=float)
    parser.add_argument("--authorization")
    args = parser.parse_args()
    if args.verify:
        if not args.roots:
            parser.error("--verify needs --roots DIR [DIR ...]")
        report, ok = verify(args.ledger, args.roots)
        print(json.dumps(report, indent=2))
        sys.exit(0 if ok else 1)
    if args.previous_cap is None or args.new_cap is None or not args.authorization:
        parser.error("--previous-cap, --new-cap and --authorization are required")
    ledger = Ledger(args.ledger, args.previous_cap)
    ledger.authorize_increase(args.new_cap, args.authorization)
    print(json.dumps(ledger.snapshot()["totals"]))

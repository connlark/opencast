"""Atomic, pessimistic model-spend ledger. Standard text inference only.

Prices verified 2026-09-10: https://developers.openai.com/api/docs/pricing and
https://ai.google.dev/gemini-api/docs/pricing . Gemini 3.8 promotional rates
expire 2026-12-31. No search/tools, regional endpoint, batch, or audio pricing.
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

MAX_AUTHORIZED_CAP = 25

PRICES = {
    # input, cached input, cache write, output; per million tokens
    "gemini-3.5-flash": (1.5, 0.15, 1.5, 9),
    "gemini-3.8-flash": (0.75, 0.075, 0.75, 3.75),
    "gpt-6-astra": (10, 1, 12.5, 50),
    "gpt-5.6-sol": (4, 0.4, 5, 20),
    "gpt-5.6-terra": (2, 0.2, 2.5, 12),
    "gpt-5.6-luna": (0.2, 0.02, 0.25, 1.2),
}


def rates(model, tokens):
    if model == "gemini-3.8-flash" and datetime.datetime.now(
        datetime.UTC
    ).date() > datetime.date(2026, 12, 31):
        raise ValueError("Refresh expired Gemini 3.8 pricing before inference")
    result = PRICES[model]
    if model.startswith("gpt-") and tokens > 272_000:
        result = (*[x * 2 for x in result[:3]], result[3] * 1.5)
    return result


class BudgetExceeded(RuntimeError):
    pass


class Ledger:
    def __init__(self, path: Path, cap: float):
        if not math.isfinite(cap) or not 0 < cap <= MAX_AUTHORIZED_CAP:
            raise ValueError("This bake-off requires a finite cap in (0, $25]")
        self.path, self.cap = path, cap
        path.parent.mkdir(parents=True, exist_ok=True)
        with self.locked() as doc:
            if not doc:
                doc.update(
                    cap_usd=cap,
                    prices={k: list(v) for k, v in PRICES.items()},
                    entries=[],
                )
            elif doc["cap_usd"] != cap or doc["prices"] != {
                k: list(v) for k, v in PRICES.items()
            }:
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
            raise ValueError("Supply an authorized increase within the $25 ceiling")
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
                price = rates(entry["model"], usage["input"])
                amount = (
                    (usage["input"] - usage["cached"] - usage["write"]) * price[0]
                    + usage["cached"] * price[1]
                    + usage["write"] * price[2]
                    + usage["output"] * price[3]
                ) / 1_000_000
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


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Record an authorized cap increase")
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--previous-cap", type=float, required=True)
    parser.add_argument("--new-cap", type=float, required=True)
    parser.add_argument("--authorization", required=True)
    args = parser.parse_args()
    ledger = Ledger(args.ledger, args.previous_cap)
    ledger.authorize_increase(args.new_cap, args.authorization)
    print(json.dumps(ledger.snapshot()["totals"]))

"""Shared helpers: paths, hashing, archive writes, lazy imports of Lane A code.

`run`, `budget` and `providers` belong to Lane A and change under this package
while it is being built, so they are imported lazily (inside functions) and a
missing `providers` package is reported, never papered over.
"""

from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib
import json
import math
import statistics
import sys
from pathlib import Path

EVAL = Path(__file__).resolve().parents[1]
WORKER = EVAL.parent
SRC = WORKER / "src"
POLICY = "decision_ad_breaks_v4_proto"

if str(EVAL) not in sys.path:
    sys.path.insert(0, str(EVAL))


def lane_a(module):
    """Import a Lane A module (`run`, `budget`, `providers.systemone`, ...)."""
    return importlib.import_module(module)


@contextlib.contextmanager
def adapter_override(model, max_questions):
    """Temporarily register a copy of `model`'s adapter with another per-request
    question cap (this process only); restores the registry on exit."""
    if max_questions is None:
        yield None
        return
    providers = lane_a("providers")
    original = providers.MODELS[model]
    grouped = copy.copy(original)
    grouped.max_questions = int(max_questions)
    providers.MODELS[model] = grouped
    try:
        yield grouped
    finally:
        providers.MODELS[model] = original


def lane_a_available(module):
    try:
        lane_a(module)
    except ImportError:
        return False
    return True


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256_json(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def read(path):
    return json.loads(Path(path).read_text())


def percentile(values, fraction):
    """Nearest-rank percentile, the same rule as compare_pcc_eval.percentile."""
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round(fraction * len(ordered) + 0.5)) - 1))
    return ordered[index]


def latency(values):
    values = [v for v in values if v is not None]
    if not values:
        return {"p50": None, "p95": None, "max": None}
    return {
        "p50": round(statistics.median(values), 3),
        "p95": round(percentile(values, 0.95), 3),
        "max": round(max(values), 3),
    }


def finite_probability(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and 0.0 <= value <= 1.0
    )


def load_manifest(path):
    """{name: (fixture, request, request_path)}; refuses a request whose bytes
    no longer match the manifest's `request_sha256`."""
    path = Path(path)
    doc = read(path)
    out = {}
    for fixture in doc["fixtures"]:
        request_path = path.parent / fixture["request"]
        digest = sha256_file(request_path)
        if digest != fixture["request_sha256"]:
            raise ValueError(f"Fixture {fixture['name']} request hash drifted from the manifest")
        out[fixture["name"]] = (fixture, read(request_path), request_path)
    return out


WAVE1 = (
    "bugged-tiny",
    "sn1085",
    "audio-illusion",
    "sn1094",
    "blunderbuss-exact",
    "upfirst-economic-warfare",
    "searchengine-the-chosen-one",
    "serial-s01e01-the-alibi",
    "synthetic-promo-carousel",
    "synthetic-paid-feed-and-ad-session",
    "sn1085-fortinet-negative",
)
WAVE2 = ("bugged-txt", "sn1085-long-window-derived")

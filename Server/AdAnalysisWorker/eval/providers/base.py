"""Provider adapter interface shared by every model route (stdlib only).

An adapter turns the Gemini-shaped canonical payload the Rust bridge renders
(`systemInstruction`, `contents`, `generationConfig.responseJsonSchema`) into
one vendor's wire body, counts or estimates its input, dispatches it, and
normalises the vendor response into `Answer`. `run.call()` owns the ledger,
the archive and the stop rules; adapters never touch either.
"""

from __future__ import annotations

import json
import math
import re
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass

TIMEOUT_S = 180
# Recognisable credential shapes, redacted from any error text even when the
# exact value is unknown: OpenAI/Anthropic `sk-`, Google `AIza` and `AQ.`,
# Perplexity `pplx-` (one alphanumeric run, so `pplx-decider-flash-latest`
# survives).
KEY_PATTERN = re.compile(
    r"(?:sk-|AIza)[A-Za-z0-9_-]{16,}|pplx-[A-Za-z0-9]{24,}|AQ\.[A-Za-z0-9_.-]{16,}"
)
MAX_ANSWER_BYTES = 100_000


def http(url, payload, headers):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"content-type": "application/json", **headers},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
        return json.load(response)


def safe_error(error, key, secrets=()):
    """Error text with the key, every listed credential value and every
    recognisable key shape removed. An empty value never redacts anything."""
    detail = (
        error.read().decode(errors="replace")
        if isinstance(error, urllib.error.HTTPError)
        else str(error)
    )
    for value in sorted({key, *secrets} - {None, ""}, key=len, reverse=True):
        detail = detail.replace(value, "[REDACTED]")
    detail = KEY_PATTERN.sub("[REDACTED]", detail)
    return detail[:1600]


class ContextExceeded(RuntimeError):
    """The counted (or estimated) input does not fit the route's context."""

    def __init__(self, tokens, limit):
        super().__init__(f"context_exceeded: {tokens} > {limit}")
        self.tokens, self.limit = tokens, limit


class RateLimiter:
    """Token bucket, one request per 1/rps seconds after a burst of `burst`.

    `clock` and `sleep` are injectable so tests run without real waiting.
    """

    def __init__(self, rps, burst=1, clock=time.monotonic, sleep=time.sleep):
        if not rps > 0 or burst < 1:
            raise ValueError("Invalid rate limit")
        self.rate, self.capacity = float(rps), float(burst)
        self.tokens = self.capacity
        self.clock, self.sleep = clock, sleep
        self.last = clock()
        self.lock = threading.Lock()

    def wait(self):
        """Block until one request may go; return the seconds waited."""
        with self.lock:
            now = self.clock()
            self.tokens = min(self.capacity, self.tokens + (now - self.last) * self.rate)
            self.last = now
            waited = 0.0
            if self.tokens < 1:
                waited = (1 - self.tokens) / self.rate
                self.sleep(waited)
                self.tokens = 1.0
                self.last = now + waited
            self.tokens -= 1
            return waited


@dataclass
class Answer:
    """A normalised vendor response.

    `text_json` is the single answer text (JSON expected, not yet parsed);
    `usage` is `{input, cached, write, output, reasoning}` or None when the
    vendor did not report billable usage; `error` explains a refused,
    truncated or shapeless answer (the runner records it as `answer_error`).
    """

    text_json: str | None
    usage: dict | None
    finish_reason: str | None
    error: str | None = None
    # Set when the answer came from a non-default response field.
    channel: str | None = None


def single_text(texts):
    texts = [text for text in texts if text.strip()]
    if len(texts) != 1 or len(texts[0].encode()) > MAX_ANSWER_BYTES:
        raise ValueError("Expected exactly one bounded answer")
    return texts[0]


def close_objects(schema):
    """Copy of a JSON schema with `additionalProperties: false` on every object
    (strict-mode vendors require it; the v3 schema already carries it)."""
    schema = json.loads(json.dumps(schema))

    def visit(node):
        if isinstance(node, dict):
            if node.get("type") == "object":
                node.setdefault("additionalProperties", False)
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(schema)
    return schema


def canonical_turns(canonical):
    """(instructions or None, [(role user|assistant, text)]) from the canonical."""
    instructions = (
        canonical["systemInstruction"]["parts"][0]["text"]
        if "systemInstruction" in canonical
        else None
    )
    turns = [
        ("assistant" if m["role"] == "model" else "user", m["parts"][0]["text"])
        for m in canonical["contents"]
    ]
    return instructions, turns


class Adapter:
    """One model on one route. Subclasses override the wire-specific parts."""

    provider = "base"
    route = "direct"
    # Values of the --key-file JSON that identify rather than authenticate;
    # everything else in the credentials is treated as secret.
    public_fields = frozenset({"account_id", "gateway_id"})
    supported_thinking = ("default",)
    # True when the provider enforces the response schema while decoding.
    strict_schema = True

    def __init__(self, model, vendor_model=None, *, route=None, context_limit=None, rps=None):
        self.model = model
        self.vendor_model = vendor_model or model
        if route:
            self.route = route
        self.context_limit = context_limit
        self.rate_limiter = RateLimiter(rps) if rps else None

    # Credentials ---------------------------------------------------------
    def credentials(self, key_text):
        key = key_text.strip()
        if not key:
            raise ValueError("Empty key file")
        return {"api_key": key}

    def secrets(self, creds):
        return [
            value
            for name, value in creds.items()
            if isinstance(value, str) and value and name not in self.public_fields
        ]

    # Thinking ------------------------------------------------------------
    def bridge_thinking(self, thinking):
        """The `thinking` the bridge's prepare op bakes into the canonical."""
        return None

    def provider_thinking(self, thinking):
        """What this route actually sends for --thinking (summary.json)."""
        return None

    # Request -------------------------------------------------------------
    def build(self, canonical, thinking, max_output):
        raise NotImplementedError

    def count(self, wire, creds):
        """Provider token count for `wire`, or None when the route has none."""
        return None

    def estimate(self, wire):
        """Pessimistic local fallback: one token per three bytes of the wire."""
        return math.ceil(len(json.dumps(wire).encode()) / 3)

    def schema_allowance(self, wire):
        """Extra input tokens reserved beyond count/estimate (schema prompts)."""
        return 0

    def reserved_output(self, wire, max_output):
        """Output tokens to reserve: the cap actually sent in `wire`."""
        return max_output

    def check_context(self, tokens):
        if self.context_limit and tokens > self.context_limit:
            raise ContextExceeded(tokens, self.context_limit)

    def archived_request(self, canonical, wire):
        """(request.json, wire-request.json or None) for one window."""
        return canonical, (None if wire == canonical else wire)

    def call(self, wire, creds):
        raise NotImplementedError

    # Response ------------------------------------------------------------
    def usage(self, raw):
        raise NotImplementedError

    def answer_text(self, raw):
        """The single answer text; raises ValueError/KeyError/TypeError."""
        raise NotImplementedError

    def finish_reason(self, raw):
        return None

    def answer_channel(self, raw):
        """Name of a non-default field the answer was read from, else None."""
        return None

    def parse(self, raw):
        try:
            text, error = self.answer_text(raw), None
        except (ValueError, KeyError, TypeError, AttributeError, IndexError) as exc:
            text, error = None, str(exc)
        try:
            usage = self.usage(raw)
        except (KeyError, TypeError, AttributeError, IndexError):
            usage = None
        try:
            finish = self.finish_reason(raw)
        except (KeyError, TypeError, AttributeError, IndexError):
            finish = None
        try:
            channel = self.answer_channel(raw) if text is not None else None
        except (KeyError, TypeError, AttributeError, IndexError):
            channel = None
        return Answer(text, usage, finish, error, channel)

    def answer(self, raw):
        """Parsed JSON answer (the historical `answer_of` contract)."""
        return json.loads(self.answer_text(raw))

    def recognizes(self, doc):
        return False

    def describe(self):
        return {
            "provider": self.provider,
            "route": self.route,
            "vendor_model": self.vendor_model,
        }

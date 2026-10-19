"""Gemini `generateContent` (Google AI Studio key). Moved from run.py verbatim."""

from __future__ import annotations

from .base import Adapter, http, single_text

BASE = "https://generativelanguage.googleapis.com/v1beta/models/"
# Lite models take a token budget, not a level (none/low/medium/high).
THINKING_BUDGETS = {"none": 0, "low": 1024, "medium": 4096, "high": 16384}


def usage_of(response):
    u = response.get("usageMetadata", {})
    # Missing billed output metadata is ambiguous, even for safety refusals.
    if "promptTokenCount" not in u or "candidatesTokenCount" not in u:
        return None
    return {
        "input": u["promptTokenCount"],
        "cached": u.get("cachedContentTokenCount", 0),
        "write": 0,
        "output": u["candidatesTokenCount"] + u.get("thoughtsTokenCount", 0),
        "reasoning": u.get("thoughtsTokenCount", 0),
    }


def answer_texts(response):
    candidates = response.get("candidates", [])
    if len(candidates) != 1 or candidates[0].get("finishReason") != "STOP":
        raise ValueError("Incomplete or refused Gemini output")
    return [
        p["text"]
        for p in candidates[0].get("content", {}).get("parts", [])
        if not p.get("thought") and "text" in p
    ]


class GeminiAdapter(Adapter):
    provider = "gemini"
    supported_thinking = ("default", "low", "medium", "high")

    def __init__(self, model, vendor_model=None, *, thinking_budget=False, **kwargs):
        super().__init__(model, vendor_model, **kwargs)
        # Lite models: thinkingBudget tokens; 3.x Flash: thinkingLevel.
        self.thinking_budget = thinking_budget
        if thinking_budget:
            self.supported_thinking = ("default", "none", "low", "medium", "high")

    def bridge_thinking(self, thinking):
        # The bridge renders thinkingLevel; lite models get their budget in build().
        if self.thinking_budget or thinking == "default":
            return None
        return thinking

    def provider_thinking(self, thinking):
        if thinking == "default":
            return None
        if self.thinking_budget:
            return {"thinkingBudget": THINKING_BUDGETS[thinking]}
        return {"thinkingLevel": thinking}

    def build(self, canonical, thinking, max_output):
        payload = canonical
        payload["generationConfig"]["maxOutputTokens"] = max_output
        if self.model == "gemini-3.8-flash":
            payload["generationConfig"].pop("temperature", None)
            payload["generationConfig"].pop("topP", None)
        if thinking != "default":
            payload["generationConfig"]["thinkingConfig"] = (
                {"thinkingBudget": THINKING_BUDGETS[thinking]}
                if self.thinking_budget
                else {"thinkingLevel": thinking}
            )
        return payload

    def headers(self, creds):
        return {"x-goog-api-key": creds["api_key"]}

    def count(self, wire, creds):
        count = http(
            BASE + self.vendor_model + ":countTokens",
            {"generateContentRequest": {"model": f"models/{self.vendor_model}", **wire}},
            self.headers(creds),
        )
        return count.get("totalTokens")

    def archived_request(self, canonical, wire):
        # The Gemini wire IS the canonical shape (the historical request.json).
        return wire, None

    def call(self, wire, creds):
        return http(BASE + self.vendor_model + ":generateContent", wire, self.headers(creds))

    def usage(self, raw):
        return usage_of(raw)

    def answer_text(self, raw):
        return single_text(answer_texts(raw))

    def finish_reason(self, raw):
        candidates = raw.get("candidates") or []
        return candidates[0].get("finishReason") if len(candidates) == 1 else None

    def recognizes(self, doc):
        return isinstance(doc, dict) and ("candidates" in doc or "usageMetadata" in doc)

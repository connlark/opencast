"""OpenAI Responses API (`/v1/responses`). Moved from run.py verbatim."""

from __future__ import annotations

from .base import Adapter, http, single_text

BASE = "https://api.openai.com/v1/responses"


def usage_of(response):
    u = response.get("usage")
    if not u:
        return None
    d = u.get("input_tokens_details") or {}
    return {
        "input": u["input_tokens"],
        "cached": d.get("cached_tokens", 0),
        "write": d.get("cache_write_tokens", 0),
        "output": u["output_tokens"],
        "reasoning": (u.get("output_tokens_details") or {}).get("reasoning_tokens", 0),
    }


def answer_texts(response):
    if (
        response.get("status") != "completed"
        or response.get("error")
        or response.get("incomplete_details")
    ):
        raise ValueError("Incomplete or refused OpenAI output")
    return [
        p["text"]
        for m in response.get("output", [])
        if m.get("type") == "message" and m.get("status") == "completed"
        for p in m.get("content", [])
        if p.get("type") == "output_text"
    ]


def responses_payload(model, payload, effort, max_output):
    schema = payload["generationConfig"]["responseJsonSchema"]
    schema["additionalProperties"] = False
    schema["properties"]["spans"]["items"]["additionalProperties"] = False
    result = {
        "model": model,
        "input": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": payload["contents"][0]["parts"][0]["text"],
                    }
                ],
            }
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "podcast_ad_breaks",
                "strict": True,
                "schema": schema,
            }
        },
        "reasoning": {"effort": effort},
        "max_output_tokens": max_output,
        "tools": [],
        "store": False,
        "background": False,
        "service_tier": "default",
        "prompt_cache_options": {"mode": "explicit"},
    }
    if "systemInstruction" in payload:
        result["instructions"] = payload["systemInstruction"]["parts"][0]["text"]
    for message in payload["contents"][1:]:
        result["input"].append(
            {
                "role": "assistant" if message["role"] == "model" else "user",
                "content": message["parts"][0]["text"],
            }
        )
    return result


class OpenAIResponsesAdapter(Adapter):
    provider = "openai"
    supported_thinking = ("default", "none", "low", "medium", "high")

    def __init__(self, model, vendor_model=None, *, none_effort=None, thinking=None, **kwargs):
        super().__init__(model, vendor_model, **kwargs)
        # gpt-6-luna: the effort `none` maps to (Step 0 smoke); None = send "none".
        self.none_effort = none_effort
        # Models whose docs exclude an effort (gpt-6.1-sol: no `none`/`minimal`)
        # register an allowlist so run.py rejects it before any count or call.
        if thinking is not None:
            self.supported_thinking = tuple(thinking)

    def effort(self, thinking):
        if thinking == "default":
            return "low"
        if thinking == "none" and self.none_effort:
            return self.none_effort
        return thinking

    def provider_thinking(self, thinking):
        return {"effort": self.effort(thinking)}

    def build(self, canonical, thinking, max_output):
        return responses_payload(self.vendor_model, canonical, self.effort(thinking), max_output)

    def headers(self, creds):
        return {"authorization": f"Bearer {creds['api_key']}"}

    def count(self, wire, creds):
        count = http(
            BASE + "/input_tokens",
            {
                k: v
                for k, v in wire.items()
                if k in ("model", "input", "instructions", "text", "tools")
            },
            self.headers(creds),
        )
        return count.get("input_tokens")

    def call(self, wire, creds):
        return http(BASE, wire, self.headers(creds))

    def usage(self, raw):
        return usage_of(raw)

    def answer_text(self, raw):
        return single_text(answer_texts(raw))

    def finish_reason(self, raw):
        details = raw.get("incomplete_details") or {}
        return details.get("reason") or raw.get("status")

    def recognizes(self, doc):
        return isinstance(doc, dict) and (
            doc.get("object") == "response"
            or ("output" in doc and isinstance(doc.get("output"), list) and "status" in doc)
        )

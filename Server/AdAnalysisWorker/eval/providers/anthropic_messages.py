"""Anthropic Messages API (`/v1/messages`) with JSON-schema structured output.

Wire facts from the Step 0 smoke (2026-10-18, `claude-haiku-5-5`):
`output_config.format = {type: json_schema, schema}` with `thinking: {type:
disabled}` returned `stop_reason: end_turn`; `count_tokens` matches billed
input only when it carries `output_config` and `thinking` (507 without, 741
with); usage itemises `output_tokens_details.thinking_tokens`. Sampling
parameters (`temperature`, `top_p`) are never sent: Haiku 5.5 rejects
non-default values.
"""

from __future__ import annotations

from .base import Adapter, canonical_turns, close_objects, http, single_text

BASE = "https://api.anthropic.com/v1/messages"
VERSION = "2023-06-01"
COUNT_FIELDS = ("model", "system", "messages", "thinking", "output_config")


class AnthropicMessagesAdapter(Adapter):
    provider = "anthropic"
    supported_thinking = ("none", "low", "medium", "high")
    usage_notes = (
        "input = input_tokens + cache_read + cache_creation; reasoning from "
        "output_tokens_details.thinking_tokens when present (0 otherwise), already in output_tokens"
    )

    def __init__(self, model, vendor_model=None, *, thinking=None, **kwargs):
        super().__init__(model, vendor_model, **kwargs)
        # Models that reject `thinking: disabled` (Opus 5.5) register without "none".
        if thinking is not None:
            self.supported_thinking = tuple(thinking)

    def provider_thinking(self, thinking):
        if thinking == "none":
            return {"thinking": {"type": "disabled"}, "effort": "low"}
        return {"thinking": {"type": "adaptive"}, "effort": thinking}

    def build(self, canonical, thinking, max_output):
        instructions, turns = canonical_turns(canonical)
        wire = {"model": self.vendor_model, "max_tokens": max_output}
        if instructions is not None:
            wire["system"] = instructions
        wire["messages"] = [{"role": role, "content": text} for role, text in turns]
        chosen = self.provider_thinking(thinking)
        wire["thinking"] = chosen["thinking"]
        wire["output_config"] = {
            "format": {
                "type": "json_schema",
                "schema": close_objects(canonical["generationConfig"]["responseJsonSchema"]),
            },
            "effort": chosen["effort"],
        }
        return wire

    def headers(self, creds):
        return {"x-api-key": creds["api_key"], "anthropic-version": VERSION}

    def count(self, wire, creds):
        count = http(
            BASE + "/count_tokens",
            {k: wire[k] for k in COUNT_FIELDS if k in wire},
            self.headers(creds),
        )
        return count.get("input_tokens")

    def call(self, wire, creds):
        return http(BASE, wire, self.headers(creds))

    def usage(self, raw):
        u = raw.get("usage")
        if not u or "input_tokens" not in u or "output_tokens" not in u:
            return None
        cached = u.get("cache_read_input_tokens") or 0
        write = u.get("cache_creation_input_tokens") or 0
        return {
            # Anthropic's input_tokens excludes cache reads and writes.
            "input": u["input_tokens"] + cached + write,
            "cached": cached,
            "write": write,
            # output_tokens already includes thinking tokens.
            "output": u["output_tokens"],
            "reasoning": (u.get("output_tokens_details") or {}).get("thinking_tokens", 0) or 0,
        }

    def answer_text(self, raw):
        if raw.get("stop_reason") != "end_turn":
            raise ValueError(
                f"Incomplete or refused Anthropic output ({raw.get('stop_reason')})"
            )
        return single_text(
            [
                block["text"]
                for block in raw.get("content", [])
                if block.get("type") == "text" and "text" in block
            ]
        )

    def finish_reason(self, raw):
        return raw.get("stop_reason")

    def recognizes(self, doc):
        return (
            isinstance(doc, dict)
            and doc.get("type") == "message"
            and "content" in doc
            and "stop_reason" in doc
        )

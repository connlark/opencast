"""Workers AI text generation: `POST {api}/accounts/{id}/ai/run/{model}`.

Chat `messages` in, `{success, errors, result}` out; `result` is either the
classic `{response: str | object, usage}` or an OpenAI chat.completion
(`choices[].message.content`, `usage.prompt_tokens/completion_tokens`).
`response_format: json_schema` is not guaranteed strict on these models, so
every route here is validator-only. Gemma takes the OpenAI-style
`json_schema: {name, schema, strict}` wrapper; qwen and gpt-oss take the raw
schema under `json_schema`. No count endpoint: input is estimated (bytes / 3)
and checked against the model's context; `max_tokens` is fitted to the room
left so a long window is not rejected for its output budget (gpt-oss defaults
to 256 otherwise).

Thinking (Step 0, 2026-10-18): gemma-4 and qwen3 think by default (gemma's
default spent a 512-token budget on reasoning and stopped at `length`) and
honour `chat_template_kwargs.enable_thinking`; `none` sends false, low /
medium / high send true, default sends nothing. gpt-oss-120b takes
`reasoning_effort` low / medium / high (default omitted = medium). Usage
`completion_tokens` includes reasoning on these routes; `neurons` is ignored.

qwen3 with `enable_thinking: false` and the v3 schema returned the JSON
answer in `message.reasoning_content` with `content: null` (STOP 3 smoke,
2026-10-18). When `content` is empty and the reasoning field holds one JSON
object, that object is the answer; the call records `answer_channel`.
"""

from __future__ import annotations

import json

from . import cloudflare
from .base import Adapter, canonical_turns, close_objects, http, single_text

MIN_OUTPUT = 1024


class WorkersAIAdapter(Adapter):
    provider = "workers-ai"
    route = "workers-ai"
    strict_schema = False

    def __init__(self, model, *, schema_style, thinking_style, context_limit, **kwargs):
        super().__init__(model, model, context_limit=context_limit, **kwargs)
        self.schema_style = schema_style
        self.thinking_style = thinking_style
        self.supported_thinking = (
            ("default", "none", "low", "medium", "high")
            if thinking_style == "template"
            else ("default", "low", "medium", "high")
        )
        self.rate_limiter = cloudflare.WORKERS_AI_LIMITER

    def thinking_fields(self, thinking):
        if thinking == "default":
            return {}
        if self.thinking_style == "template":
            return {"chat_template_kwargs": {"enable_thinking": thinking != "none"}}
        return {"reasoning_effort": thinking}

    def provider_thinking(self, thinking):
        fields = self.thinking_fields(thinking)
        if "chat_template_kwargs" in fields:
            return fields["chat_template_kwargs"]
        return fields or None

    def credentials(self, key_text):
        return cloudflare.credentials(key_text)

    def build(self, canonical, thinking, max_output):
        instructions, turns = canonical_turns(canonical)
        messages = [{"role": "system", "content": instructions}] if instructions else []
        messages += [{"role": role, "content": text} for role, text in turns]
        schema = close_objects(canonical["generationConfig"]["responseJsonSchema"])
        response_format = (
            {"type": "json_schema", "json_schema": {"name": "podcast_ad_breaks", "strict": True, "schema": schema}}
            if self.schema_style == "openai"
            else {"type": "json_schema", "json_schema": schema}
        )
        wire = {
            "messages": messages,
            "response_format": response_format,
            "max_tokens": max_output,
            **self.thinking_fields(thinking),
        }
        room = self.context_limit - self.estimate(wire)
        if room < max_output:
            wire["max_tokens"] = max(MIN_OUTPUT, room)
        return wire

    def reserved_output(self, wire, max_output):
        return wire.get("max_tokens", max_output)

    def check_context(self, tokens):
        # Leave at least MIN_OUTPUT tokens for the answer.
        super().check_context(tokens + MIN_OUTPUT)

    def call(self, wire, creds):
        return http(cloudflare.base_url(creds) + "/run/" + self.model, wire, cloudflare.headers(creds))

    def usage(self, raw):
        body, _ = cloudflare.unwrap(raw)
        u = (body or {}).get("usage") if isinstance(body, dict) else None
        if not u:
            return None
        if "prompt_tokens" in u and "completion_tokens" in u:
            inp, out = u["prompt_tokens"], u["completion_tokens"]
            cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
            reasoning = (u.get("completion_tokens_details") or {}).get("reasoning_tokens") or 0
        elif "input_tokens" in u and "output_tokens" in u:
            inp, out = u["input_tokens"], u["output_tokens"]
            cached = (u.get("input_tokens_details") or {}).get("cached_tokens") or 0
            reasoning = (u.get("output_tokens_details") or {}).get("reasoning_tokens") or 0
        else:
            return None
        if type(inp) is not int or type(out) is not int:
            # Workers AI schemas declare usage as `number`; whole floats are fine.
            if float(inp).is_integer() and float(out).is_integer():
                inp, out = int(inp), int(out)
            else:
                return None
        return {"input": inp, "cached": int(cached), "write": 0, "output": out, "reasoning": int(reasoning)}

    def answer_text(self, raw):
        body, error = cloudflare.unwrap(raw)
        if error:
            raise ValueError(error)
        if not isinstance(body, dict):
            raise ValueError("Workers AI result is not an object")
        if isinstance(body.get("choices"), list):
            choices = body["choices"]
            if len(choices) != 1:
                raise ValueError("Expected one Workers AI choice")
            if choices[0].get("finish_reason") not in (None, "stop"):
                raise ValueError(f"Incomplete Workers AI output ({choices[0].get('finish_reason')})")
            message = choices[0].get("message") or {}
            content = message.get("content")
            if isinstance(content, (dict, list)):
                return json.dumps(content)
            if not (content or "").strip() and self.reasoning_answer(message) is not None:
                return self.reasoning_answer(message)
            return single_text([content or ""])
        if isinstance(body.get("output"), list):
            texts = [
                p.get("text", "")
                for m in body["output"]
                if m.get("type") == "message"
                for p in m.get("content", [])
                if p.get("type") == "output_text"
            ]
            return single_text(texts)
        if "response" in body:
            response = body["response"]
            if isinstance(response, (dict, list)):
                return json.dumps(response)
            if response is None:
                raise ValueError("Empty Workers AI response")
            return single_text([str(response)])
        raise ValueError("Unrecognized Workers AI result")

    @staticmethod
    def reasoning_answer(message):
        """The reasoning field's text when it is exactly one JSON object."""
        for field in ("reasoning_content", "reasoning"):
            text = message.get(field)
            if isinstance(text, str) and text.strip():
                try:
                    if isinstance(json.loads(text), dict):
                        return single_text([text])
                except ValueError:
                    return None
        return None

    def answer_channel(self, raw):
        body, _ = cloudflare.unwrap(raw)
        choices = (body or {}).get("choices") or []
        if len(choices) == 1:
            message = choices[0].get("message") or {}
            content = message.get("content")
            if not isinstance(content, (dict, list)) and not (content or "").strip():
                return "message.reasoning_content"
        return None

    def finish_reason(self, raw):
        body, error = cloudflare.unwrap(raw)
        if error or not isinstance(body, dict):
            return None
        if isinstance(body.get("choices"), list) and body["choices"]:
            return body["choices"][0].get("finish_reason")
        return body.get("finish_reason") or body.get("status")

    def recognizes(self, doc):
        return isinstance(doc, dict) and "success" in doc and "result" in doc

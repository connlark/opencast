"""Third-party models through Cloudflare AI Gateway on unified billing.

Routes (2026-10 docs; `/compat/chat/completions` is deprecated): OpenAI
chat completions at `POST {api}/accounts/{id}/ai/v1/chat/completions` for
`openai/*` and `google/*`, Anthropic Messages at `.../ai/v1/messages` for
`anthropic/*`. No provider key: the gateway (cf-aig-gateway-id) bills
Cloudflare credits. The `/ai/v1/*` routes return plain vendor bodies (no
`{success, result}` envelope; unwrap tolerates one). Step 0: the OpenAI
route needs `max_completion_tokens` (`max_tokens` is 400 code 7003); the
Google route's `completion_tokens` excludes reasoning; Haiku through the
gateway reported usage identical to direct (741 / 26). `openai/*` gets strict json_schema; `google/*` and
`anthropic/*` pass the schema through unverified, so they are validator-only
(a malformed answer takes the existing v3_malformed_model_json repair path).
No count endpoint: input is estimated (bytes / 3).
"""

from __future__ import annotations

from . import cloudflare
from .anthropic_messages import AnthropicMessagesAdapter
from .base import Adapter, canonical_turns, close_objects, http, single_text

GATEWAY = "cloudflare-ai-gateway"


class CFGatewayChatAdapter(Adapter):
    provider = GATEWAY
    route = "ai-gateway"

    def __init__(
        self,
        model,
        vendor_model,
        *,
        strict_schema,
        thinking,
        default_effort=None,
        completion_includes_reasoning=True,
        **kwargs,
    ):
        super().__init__(model, vendor_model, **kwargs)
        self.strict_schema = strict_schema
        self.completion_includes_reasoning = completion_includes_reasoning
        self.usage_notes = (
            "output = completion_tokens (includes reasoning_tokens)"
            if completion_includes_reasoning
            else "output = completion_tokens + completion_tokens_details.reasoning_tokens "
            "(the gateway's Google translation excludes reasoning from completion_tokens)"
        )
        self.supported_thinking = thinking
        # The effort sent for --thinking default (None = omit the field).
        self.default_effort = default_effort
        self.rate_limiter = cloudflare.GATEWAY_LIMITER

    def credentials(self, key_text):
        return cloudflare.credentials(key_text)

    def effort(self, thinking):
        return self.default_effort if thinking == "default" else thinking

    def provider_thinking(self, thinking):
        effort = self.effort(thinking)
        return {"reasoning_effort": effort} if effort else None

    def build(self, canonical, thinking, max_output):
        instructions, turns = canonical_turns(canonical)
        messages = [{"role": "system", "content": instructions}] if instructions else []
        messages += [{"role": role, "content": text} for role, text in turns]
        wire = {
            "model": self.vendor_model,
            "messages": messages,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "podcast_ad_breaks",
                    "strict": True,
                    "schema": close_objects(canonical["generationConfig"]["responseJsonSchema"]),
                },
            },
            ("max_completion_tokens" if self.vendor_model.startswith("openai/") else "max_tokens"): max_output,
        }
        effort = self.effort(thinking)
        if effort:
            wire["reasoning_effort"] = effort
        return wire

    def call(self, wire, creds):
        return http(
            cloudflare.base_url(creds) + "/v1/chat/completions",
            wire,
            cloudflare.headers(creds, gateway=True),
        )

    def usage(self, raw):
        body, _ = cloudflare.unwrap(raw)
        u = (body or {}).get("usage")
        if not u or "prompt_tokens" not in u or "completion_tokens" not in u:
            return None
        cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
        reasoning = (u.get("completion_tokens_details") or {}).get("reasoning_tokens") or 0
        output = u["completion_tokens"]
        # OpenAI semantics: completion_tokens includes reasoning. Google through
        # the gateway reports reasoning separately; a reasoning count above the
        # completion count can only mean the same, so bill both then too.
        if not self.completion_includes_reasoning or reasoning > output:
            output += reasoning
        return {"input": u["prompt_tokens"], "cached": cached, "write": 0, "output": output, "reasoning": reasoning}

    def answer_text(self, raw):
        body, error = cloudflare.unwrap(raw)
        if error:
            raise ValueError(error)
        choices = body.get("choices") or []
        if len(choices) != 1 or choices[0].get("finish_reason") != "stop":
            raise ValueError(
                "Incomplete or refused gateway output ("
                + str(choices[0].get("finish_reason") if choices else "no choices")
                + ")"
            )
        message = choices[0].get("message") or {}
        if message.get("refusal"):
            raise ValueError("Refused gateway output")
        content = message.get("content")
        if isinstance(content, list):
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        return single_text([content or ""])

    def finish_reason(self, raw):
        body, _ = cloudflare.unwrap(raw)
        choices = (body or {}).get("choices") or []
        return choices[0].get("finish_reason") if choices else None

    def recognizes(self, doc):
        body, _ = cloudflare.unwrap(doc) if isinstance(doc, dict) else (None, None)
        return isinstance(body, dict) and isinstance(body.get("choices"), list)


class CFGatewayMessagesAdapter(AnthropicMessagesAdapter):
    """Anthropic Messages through the gateway (`anthropic/*` model ids)."""

    provider = GATEWAY
    route = "ai-gateway"
    strict_schema = False
    # Structured-output system prompt + thinking config the estimate cannot see
    # (Step 0: count_tokens 507 without output_config, 741 with).
    SCHEMA_ALLOWANCE = 512
    # Anthropic's tokenizer is denser than bytes/3 on this wire: the STOP 3
    # smoke estimated 3,051 and was billed 3,128. A 15 % margin keeps the
    # reservation (and the >100,000-token tier choice) above the bill.
    ESTIMATE_MARGIN_PERCENT = 15

    def __init__(self, model, vendor_model, **kwargs):
        super().__init__(model, vendor_model, **kwargs)
        self.rate_limiter = cloudflare.GATEWAY_LIMITER

    def credentials(self, key_text):
        return cloudflare.credentials(key_text)

    def count(self, wire, creds):
        return None

    def schema_allowance(self, wire):
        estimate = self.estimate(wire)
        return self.SCHEMA_ALLOWANCE + -(-estimate * self.ESTIMATE_MARGIN_PERCENT // 100)

    def call(self, wire, creds):
        # Step 0: no anthropic-version header on this route.
        return http(cloudflare.base_url(creds) + "/v1/messages", wire, cloudflare.headers(creds, gateway=True))

    def usage(self, raw):
        body, _ = cloudflare.unwrap(raw)
        return super().usage(body or {})

    def answer_text(self, raw):
        body, error = cloudflare.unwrap(raw)
        if error:
            raise ValueError(error)
        return super().answer_text(body)

    def finish_reason(self, raw):
        body, _ = cloudflare.unwrap(raw)
        return (body or {}).get("stop_reason")

    def recognizes(self, doc):
        return False  # archived docs sniff as plain Anthropic messages

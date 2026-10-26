"""Model registry: every `budget.PRICES` key maps to one adapter instance.

`MODELS[key]` is the adapter bound to that key's vendor model string and
route. `adapter_for(key)` looks one up; `adapter_recognizing(doc)` sniffs an
archived response; `SUPPORTED_THINKING[key]` lists the accepted --thinking
values (see eval/README.md for the matrix).
"""

from __future__ import annotations

from . import systemone
from .anthropic_messages import AnthropicMessagesAdapter
from .base import Adapter, Answer, ContextExceeded, RateLimiter, http, safe_error
from .cf_gateway_chat import CFGatewayChatAdapter, CFGatewayMessagesAdapter
from .gemini import GeminiAdapter
from .openai_responses import OpenAIResponsesAdapter
from .workers_ai import WorkersAIAdapter

_ADAPTERS = [
    GeminiAdapter("gemini-3.5-flash"),
    GeminiAdapter("gemini-3.8-flash"),
    GeminiAdapter("gemini-3.1-flash-lite", thinking_budget=True),
    GeminiAdapter("gemini-2.5-flash-lite", thinking_budget=True),
    OpenAIResponsesAdapter("gpt-6-astra"),
    # 2026-10-23: id confirmed from GET /v1/models; the model page lists efforts
    # low..max with `none` and `minimal` unsupported; context 1,050,000.
    OpenAIResponsesAdapter(
        "gpt-6.1-sol", thinking=("default", "low", "medium", "high"), context_limit=1_050_000
    ),
    OpenAIResponsesAdapter("gpt-5.6-sol"),
    OpenAIResponsesAdapter("gpt-5.6-terra"),
    OpenAIResponsesAdapter("gpt-5.6-luna"),
    # Step 0: gpt-6-luna rejects "minimal" (400); it accepts none..max.
    OpenAIResponsesAdapter("gpt-6-luna", context_limit=922_000),
    AnthropicMessagesAdapter("claude-haiku-5-5", context_limit=1_000_000),
    # 2026-10-23: Opus 5.5 returns 400 for `thinking: disabled`
    # at every effort, so `none` is not offered; adaptive + effort only.
    AnthropicMessagesAdapter(
        "claude-opus-5-5", context_limit=1_000_000, thinking=("low", "medium", "high")
    ),
    # AI Gateway unified billing (Cloudflare REST, cf-aig-gateway-id).
    CFGatewayChatAdapter(
        "cf/openai/gpt-6-luna",
        "openai/gpt-6-luna",
        strict_schema=True,
        thinking=("default", "none", "low", "medium", "high"),
        default_effort="low",
        context_limit=922_000,
    ),
    CFGatewayMessagesAdapter(
        "cf/anthropic/claude-haiku-5.5", "anthropic/claude-haiku-5.5", context_limit=1_000_000
    ),
    CFGatewayChatAdapter(
        "cf/google/gemini-3.8-flash",
        "google/gemini-3.8-flash",
        strict_schema=False,
        thinking=("default", "low", "medium", "high"),
        context_limit=1_000_000,
        # Step 0: Google's completion_tokens excludes reasoning (19 + 76 = total - prompt).
        completion_includes_reasoning=False,
    ),
    # Workers AI (contexts from the model pages via providers.json).
    WorkersAIAdapter(
        "@cf/google/gemma-4-26b-a4b-it", schema_style="openai", thinking_style="template", context_limit=256_000
    ),
    WorkersAIAdapter(
        "@cf/qwen/qwen3-30b-a3b-fp8", schema_style="openai", thinking_style="template", context_limit=32_768
    ),
    WorkersAIAdapter(
        "@cf/openai/gpt-oss-120b", schema_style="openai", thinking_style="effort", context_limit=128_000
    ),
    # Decision models (probabilities only; see providers/systemone.py).
    *systemone.ADAPTERS,
]

MODELS = {adapter.model: adapter for adapter in _ADAPTERS}
SUPPORTED_THINKING = {key: adapter.supported_thinking for key, adapter in MODELS.items()}


def adapter_for(model):
    try:
        return MODELS[model]
    except KeyError:
        raise KeyError(f"No provider adapter for model {model!r}") from None


def adapter_recognizing(doc):
    """The first adapter whose response shape matches an archived doc."""
    for adapter in _ADAPTERS:
        if adapter.recognizes(doc):
            return adapter
    return None


def sanitize(model):
    """Model key safe for an archive path segment (`/` and `@` become `_`)."""
    return model.replace("/", "_").replace("@", "_")


__all__ = [
    "Adapter",
    "Answer",
    "ContextExceeded",
    "MODELS",
    "RateLimiter",
    "SUPPORTED_THINKING",
    "adapter_for",
    "adapter_recognizing",
    "http",
    "safe_error",
    "sanitize",
]

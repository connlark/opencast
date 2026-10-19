"""Cloudflare account plumbing shared by Workers AI, AI Gateway and Clef/Jev.

Credentials come from `keys/cloudflare-ai-bakeoff.json`:
`{"account_id", "api_token", "gateway_id", "gateway_token" (optional)}`.
Every `/accounts/{id}/ai/*` route authenticates with `Authorization: Bearer
<api_token>` (the token needs Workers AI Read; an AI Gateway-only token gets
401/10000). Third-party models route through the gateway named by the
`cf-aig-gateway-id` header (unified billing); `cf-aig-collect-log: false`
keeps the request out of gateway logs.
"""

from __future__ import annotations

import json

from .base import RateLimiter

API = "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai"
# Workers AI text generation: 300 requests/minute per account.
WORKERS_AI_LIMITER = RateLimiter(5)
# The ad-bakeoff gateway was created with a 60/minute rate limit.
GATEWAY_LIMITER = RateLimiter(1)


def credentials(key_text):
    doc = json.loads(key_text)
    if not isinstance(doc, dict):
        raise ValueError("Cloudflare key file must be a JSON object")
    for field in ("account_id", "api_token"):
        if not isinstance(doc.get(field), str) or not doc[field].strip():
            raise ValueError(f"Cloudflare key file lacks {field}")
    return {
        "account_id": doc["account_id"].strip(),
        "api_token": doc["api_token"].strip(),
        "gateway_id": (doc.get("gateway_id") or "ad-bakeoff").strip(),
        **(
            {"gateway_token": doc["gateway_token"].strip()}
            if isinstance(doc.get("gateway_token"), str) and doc["gateway_token"].strip()
            else {}
        ),
    }


def base_url(creds):
    return API.format(account_id=creds["account_id"])


def headers(creds, gateway=False):
    result = {"authorization": f"Bearer {creds['api_token']}"}
    if gateway:
        result["cf-aig-gateway-id"] = creds["gateway_id"]
        result["cf-aig-collect-log"] = "false"
    return result


def unwrap(raw):
    """(body, error) from a `{success, errors, result}` envelope or a bare body."""
    if isinstance(raw, dict) and "success" in raw and ("result" in raw or "errors" in raw):
        if not raw.get("success"):
            return None, "cloudflare_error: " + json.dumps(raw.get("errors"))[:400]
        return raw.get("result"), None
    return raw, None

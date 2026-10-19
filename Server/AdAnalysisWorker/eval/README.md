# Ad-break evaluation

The native Rust bridge renders the **same prompt, windows, schema, and validation**
used by the Worker. Python only handles providers, a shared spend ledger, and
segment/time scoring. No Worker credentials, private podcast captures, or model
answers are included. `fixtures/promo-carousel.json` is original synthetic text,
not an independent real-episode benchmark.

From this directory's parent, build and test before any paid run:

```sh
cargo build --locked --example eval_bridge
python3 -m unittest discover -s eval -p 'test_*.py'
```

Example (substitute a local secret file; output should be private/ignored):

```sh
python3 eval/run.py --manifest eval/fixtures/manifest.json \
  --out /private/tmp/my-ad-eval --key-file /path/to/gemini-secret \
  --model gemini-3.8-flash --policy promo_ad_breaks_v3 --thinking medium \
  --repair --repeats 3 --tag carousel-v3 --max-spend 15
```

Use **one ledger for the whole experiment**, including other providers,
retries, smokes, decision-model calls and staging calls. `--ledger PATH`
(default `<out>/budget-ledger.json`) lets several output roots share it: the
2026-10 bakeoff passes `--ledger ROOT/ledger/budget-ledger.json` to every
generative run (`--out ROOT/runs`), smoke and decision pipeline
(`ROOT/decision`). Never reset the ledger or open a second one to bypass its cap.
Reservations cover counted input and maximum output (including reasoning).
Ambiguous dispatches retain their full reservation. Prices are frozen and must
be reverified before reuse; Gemini 3.8 promotional prices expire 2026-12-31.
The default $15 cap is an experiment limit, not a production quota. The current
authorized maximum is $50 (`budget.MAX_AUTHORIZED_CAP`, raised from $25 for the
2026-10 ad-analysis bakeoff). Increasing an existing ledger requires an explicit
authorization recorded atomically, not a fresh ledger. For an authorized change:

```sh
python3 eval/budget.py --ledger /private/tmp/my-ad-eval/budget-ledger.json \
  --previous-cap 15 --new-cap 50 --authorization 'Quote the explicit approval'
```

Continue every runner/probe/smoke with `--max-spend 50` after that migration.
All prior charges and ambiguous reservations remain counted. Cap increases are
rejected while calls are actively reserved; a stale-cap process cannot reserve.

Raw requests, responses, initial/repaired validation, fixture hashes, native
binary hash, token usage, latency, and installed results are archived per run.
The runner refuses stale/replaced native binaries and output overwrites. Do not
edit Worker source during a paid batch. Input text is sent to the selected
provider; OpenAI uses standard tier, no tools, `store: false`. Prices: see the
`budget.py` docstring (2026-10 rows reconciled to the bakeoff's
providers.json); Workers AI rows are token equivalents of neuron pricing and
the AI Gateway unified-billing 5 % credit fee sits outside the ledger.

## Providers (`eval/providers/`)

Every `budget.PRICES` key maps to one adapter (`providers.MODELS`), which
builds the vendor wire from the bridge's Gemini-shaped canonical payload,
counts (or estimates, bytes / 3, `input_estimated: true`) its input, checks
the route's context (`transport_error: context_exceeded`, no reservation),
dispatches and normalises usage `{input, cached, write, output, reasoning}`.
Per window the archive keeps `request.json` = the canonical payload (what the
Worker would send Gemini), `wire-request.json` = the body actually sent when
it differs, `response.json` = the raw vendor body. `summary.json` adds
`provider, route, vendor_model, provider_thinking, schema_enforcement, prices,
input_estimated_calls, cost_usd`; each call adds `provider, route,
vendor_model, input_count, latency_ms, finish_reason`.

| Model keys | Route | Wire | Schema |
|---|---|---|---|
| `gemini-3.5-flash`, `gemini-3.8-flash`, `gemini-3.1-flash-lite`, `gemini-2.5-flash-lite` | direct, `x-goog-api-key` | `generateContent`, `countTokens` | `responseJsonSchema` |
| `gpt-6-astra`, `gpt-5.6-*`, `gpt-6-luna` | direct, Bearer | Responses, `/responses/input_tokens` | strict `json_schema` |
| `claude-haiku-5-5` | direct, `x-api-key` + `anthropic-version` | `/v1/messages`, `count_tokens` (with `output_config` + `thinking`) | `output_config.format` json_schema |
| `cf/openai/gpt-6-luna`, `cf/google/gemini-3.8-flash` | AI Gateway unified billing: `api.cloudflare.com/.../ai/v1/chat/completions`, Bearer + `cf-aig-gateway-id` | chat completions, estimated | strict (openai) / validator-only (google) |
| `cf/anthropic/claude-haiku-5.5` | same gateway, `.../ai/v1/messages` | Anthropic Messages, estimated | validator-only |
| `@cf/google/gemma-4-26b-a4b-it`, `@cf/qwen/qwen3-30b-a3b-fp8`, `@cf/openai/gpt-oss-120b` | Workers AI `.../ai/run/{model}`, Bearer (postpaid, no gateway) | chat `messages` + `json_schema {name, strict, schema}`, estimated, `max_tokens` fitted to context (256,000 / 32,768 / 128,000) | validator-only |
| `@cf/cloudflare/clef`, `clef-flash`, `typesafe/jev`, `pplx-decider-latest`, `pplx-decider-flash-latest`, `decisions/gpt-6-luna` | Workers AI / gateway / Perplexity / OpenAI | `providers.systemone` decision APIs | probabilities only |

Validator-only means the existing path: a non-JSON answer is `answer_error`,
the bridge returns `v3_malformed_model_json`, and `--repair` spends one turn.

Thinking matrix (`--thinking`; anything else is rejected before any call):

| Route | default | none | low / medium / high |
|---|---|---|---|
| Gemini 3.x Flash | model default | rejected | `thinkingLevel` |
| Gemini lite (3.1, 2.5) | model default | `thinkingBudget: 0` | `thinkingBudget` 1024 / 4096 / 16384 |
| OpenAI Responses | `reasoning.effort: low` | `effort: none` (gpt-6-luna rejects `minimal`) | `effort` |
| Anthropic (direct and gateway) | rejected | `thinking: disabled` + `effort: low` | `thinking: adaptive` + `output_config.effort` |
| Gateway `openai/*` | `reasoning_effort: low` | `reasoning_effort: none` | `reasoning_effort` |
| Gateway `google/*` | omitted | rejected | `reasoning_effort` |
| Workers AI gemma-4 / qwen3 | model default (thinks; `provider_thinking: null`) | `chat_template_kwargs.enable_thinking: false` | `enable_thinking: true` |
| Workers AI gpt-oss-120b | model default (medium) | rejected | `reasoning_effort` |
| Decision models | only value | rejected | rejected |

Usage notes: Anthropic `input` = `input_tokens + cache_read + cache_creation`,
`reasoning` from `output_tokens_details.thinking_tokens` (already inside
`output_tokens`); OpenAI chat and Workers AI `completion_tokens` include
reasoning; the gateway's Google route excludes it, so its output is
`completion_tokens + reasoning_tokens` (Step 0, 2026-10-18).

Credentials (`--key-file`, absolute paths): a bare key file for Gemini,
OpenAI (Responses and Decisions), Anthropic and Perplexity; the Cloudflare
JSON `{"account_id", "api_token", "gateway_id", "gateway_token"?}` for every
Workers AI, gateway, Clef and Jev route. Errors redact every credential value
and every `sk-`, `AIza`, `AQ.`, `pplx-` shape.

### Decision models (`providers.systemone`)

Plumbing only: `systemone.ask(model, state, questions, key_text, ledger,
out_dir, context)` reserves (twice the estimate: decision rows have no output
slack), calls, archives and settles one window; `state` is the exact v3
`input` JSON string (or a canonical payload / window request, rendered by the
bridge), questions are `{id, instructions, type: noul|choice|score,
criteria?}`. Pages split by the vendor's question cap (Clef/Jev 64, pplx and
OpenAI 128, pplx flash 1) and context (Clef 65,536, clef-flash 24,576, Jev
32,000, pplx and OpenAI 256K); a state that alone overflows raises
`ContextExceeded` (Clef would truncate it silently). `response.json` is
`{"kind": "systemone", "vendor": [raw per page], "questions", "answers"}`,
the one documented deviation from a raw body; `answers` maps question id to
the yes-probability (noul/predicate), an option map (choice/score) or None
(refusal). A 402/429 raises `ProviderHTTPError` with its status. Decision
models are rejected by `run.py` manifest runs, `--repair` and the v2 policy.

### Smoke, verify, secret scan

```sh
python3 eval/run.py --smoke --model gpt-6-luna --key-file /abs/keys/openai_ad_bakeoff \
  --out ROOT/runs --ledger ROOT/ledger/budget-ledger.json --max-spend 15
python3 eval/budget.py --verify --ledger ROOT/ledger/budget-ledger.json --roots ROOT/runs ROOT/decision
python3 eval/secret_scan.py --root ROOT --key-file /abs/keys/<each key file>
```

`--smoke` sends one fixed five-segment synthetic window (original text in
`run.SMOKE_REQUEST`; two noul questions for decision models) through the
same metered path, archives under `<out>/smoke/<model, / and @ -> _>/<utc>/`
(never a fixture directory), and prints one JSON line: model, route,
`count_or_estimate`, usage, latency, finish reason, `parsed_ok`,
`key_sha256_prefix`, budget totals. Without `--thinking` it uses the route's
lowest supported value. `--verify` reconciles every `summary.json` call
(deduplicated by reservation) with the ledger's settled entries per model and
overall, and each summary's `cost_usd` with its own calls; it exits 1 beyond
one cent. `secret_scan.py` exact-matches every key file value (every string
of a JSON key file except `account_id` / `gateway_id`) plus the recognisable
key patterns and writes `<root>/secret-scan.json`; run it before any archive
leaves the evidence root.

## Apple Private Cloud Compute (`--model pcc`)

`pcc` sends the same v3 instructions, window, schema, and one-round repair turn
to Apple's `PrivateCloudComputeLanguageModel` through a **signed, PCC-entitled
helper executable** supplied with `--pcc-helper` (the entitlement is a managed
capability granted per developer account, so the helper is not part of this
tree). No `--key-file` is needed. The helper contract is one JSON file in, one
JSON report out:

- Input (`pcc-request.json`, built by `pcc_input`): `label`, `instructions`,
  `messages` (`[{role: user|model, text}]`, ending with a user turn; earlier
  turns are replayed as the session transcript so the repair reaches the model
  as a second turn of the same conversation), ordered `schema` (properties as
  `[name, schema]` pairs), `max_output_tokens`.
- Flags: `--in`, `--out`, `--reasoning light|moderate|deep` (from `--thinking`
  low/medium/high; `default`/`none` omit it), `--fit-context 1` (cap the
  response budget to the context left after the on-device token count).
- Report: `runs[-1]` with `ok`, `elapsed_s`, `usage` (`input_total`,
  `input_cached`, `output_total`, `output_reasoning`), `raw_json`, `quota_after`,
  or `error.kind` (`rateLimited`, `refusal`, `guardrailViolation`,
  `contextSizeExceeded`, `pcc.quotaLimitReached`, ...).

PCC has no monetary price and an unpublished per-user daily quota, so PCC calls
never touch the spend ledger; the runner journals every attempt (tokens, quota
status, rate limits) to `pcc-usage.json` in the output root. A `rateLimited`
window is retried after 30/90/180 s; transport-class failures make the run
`ad_analysis_incomplete: pcc_<kind>` (the serving path would fall back, not
repair), model-class failures take the normal repair turn, and a reached quota
stops the batch. The 32K context means v3's 16,384 `maxOutputTokens` is capped
per call to what remains; the report records `max_output_effective`.

Manifest ground truth uses inclusive **segment IDs**, not array indexes:

- `pods`: required uninterrupted ad cores.
- `optional`: mixed/ambiguous boundaries or optional house promos, excluded
  from false-skip penalties. These are **not guaranteed safe audio**.
- `negatives`: explicit editorial intervals that must not be skipped.

Score unioned installed spans at the app's confidence floor (0.8) and one-second
zone merge. Report missed ad seconds, false-skip seconds outside allowed regions,
negative overlap, and zones per pod—not just ad count. V2 installs surviving
spans after validation losses; v3 installs nothing on unresolved validation.
`complete` means structurally valid, **not certified semantic recall**. A model
can still omit an entire ad or emit a plausible wrong boundary without warning.

Private corpora should freeze labels before inference and record provenance,
audio/transcript hashes, mixed-boundary uncertainty, and revisions. Alternative
ASR transcripts of one recording and concatenated long-window tests are not
additional independent episodes. Never grade against a newly fetched dynamic-ad
audio variant and call it a replay of the listener's bytes.

`boundary_probe.py` is an exploratory, **non-serving** follow-up: a case file
supplies a request path, one proposed interval, and scoring labels. The model
sees only the two boundary neighborhoods and the fallible proposal, never the
labels. This measures review of known candidates, not independent discovery or
held-out accuracy. It shares the same ledger and provider adapter as `run.py`.
`--blind-proposal` withholds the candidate IDs and uses explicit two-sided
transition instructions. This combined variant does not isolate proposal bias
alone, and its neighborhoods are still selected from known candidates.

`recall_audit.py` independently scans the entire transcript for promotional
occurrences using a separate cue-discovery prompt. Neither the primary detector's
spans nor ground truth enter its input. It validates each cue against its exact
source segment; cue anchors are leads to inspect, **not skip boundaries**, and
are never automatically installed. This measures incremental missed-promotion
discovery, not human ground truth or guaranteed completeness. It shares the
same ledger, including when audits and detector runs execute concurrently.

`staging_smoke.py` exercises async submit/poll/cache against an explicitly
confirmed staging host (`--staging-host`, matched exactly against `--url`).
Operators must confirm that the host is not production. It reserves the entire bounded Worker retry ladder and retains that
amount because HTTP response usage cannot prove whether a timed-out upstream
attempt was also billed. It never targets the production hostname.

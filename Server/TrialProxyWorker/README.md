# OpenCast Trial Proxy Worker

Self-hostable Rust Cloudflare Worker behind the analysis trial: listeners
without their own provider key get a bounded number of on-device ad-detection
and Chapters & Summary runs paid for by the deployer. The app builds the exact
Gemini `generateContent` request on the device and sends it here; the Worker
checks it, rebuilds every chargeable field from the embedded analysis policy
bundle, reserves the worst-case cost, forwards it to Google with the deployer's
key, settles the reservation from the reply's usage, and answers with the
provider's status and body. It keeps no request or reply content: storage, the
D1 mirror and the logs hold numbers, closed enums and hashes only.

This public copy contains no deployed Worker names, live routes, D1 IDs, zone
IDs, Gemini credentials, bearer tokens or alert credentials.

The app reaches the proxy at the `trial.endpoint` of the signed analysis
policy bundle it carries and verifies (see the Model Gateway Worker's README).
A self-hosted deployment generates and signs its own bundle so that endpoint
names its own host, and builds the app against the matching public key.

## Setup

Install dependencies and copy the disabled public configuration template:

```sh
yarn install
cp wrangler.example.toml wrangler.toml
```

Replace every `REPLACE_WITH_...` value and every `your-...` resource name with
values from your Cloudflare and Apple accounts. Create one D1 database per
lane, keep the `TrialLedger` Durable Object export intact, and replace the
`trial-proxy.example.com` production route with your own domain. Vars are not
inherited by named environments, so every lane sets every var.

Keep `TRIAL_PROXY_ENABLED` set to `false` on every lane until that lane's D1
database, secrets and App Attest identifiers are in place; while it is off,
every route but `/health` answers `trial_disabled`.

Set the secrets with Wrangler; never commit their values:

```sh
yarn wrangler secret put GEMINI_API_KEY
yarn wrangler secret put TRIAL_BEARER_TOKEN
yarn wrangler secret put PUSHOVER_APP_TOKEN
yarn wrangler secret put PUSHOVER_USER_KEY
yarn wrangler secret put CHALLENGE_SOURCE_HASH_KEY
```

The development lane has a built-in `CHALLENGE_SOURCE_HASH_KEY` fallback; the
prod-staging and production lanes refuse to serve without one. Repeat the
secret commands with `--env prod-staging` or `--env production` when
configuring those lanes. Apply the D1 schema separately because
`wrangler deploy` does not run migrations:

```sh
yarn wrangler d1 migrations apply TRIAL_DB --remote
```

## Routes

| Method | Path | Auth | |
| --- | --- | --- | --- |
| GET | `/health` | none | `{"message":"ok","bundle_version":N,"trial_model":"…"}` |
| POST | `/v1/app-attest/challenge` | none (rate-limited) | `{install_id, purpose:"register"}` → `{challenge_id, challenge}` |
| POST | `/v1/app-attest/register` | challenge | registers an App Attest key with this service |
| POST | `/v1/trial/analyze` | App Attest envelope, or the ops bearer | the forward |
| POST | `/v1/trial/status` | App Attest envelope (payload `{}`), or the ops bearer | status |
| GET | `/v1/trial/status` | ops bearer only | status |

Every other path is 404; a known path with another method is 405.

## Auth

The App Attest envelope is AppAttestCore's: a JSON body `{install_id, key_id,
payload, assertion}` where `payload` is the inner body as JSON text and the
assertion signs `POST\n<path>\n<sha256 hex of payload>`. Keys are registered
per service, so a key registered with another worker is `unknown_key` here.
Every counter is keyed on the authenticated install id (hashed), which the app
keeps when it rotates keys.

Identifiers are checked before anything is looked up or stored, so no
identifier column can hold text a client chose. On the challenge and
register routes the install id must be a UUID string (`8-4-4-4-12` hex,
either case), the key id base64 of 32 bytes, and the challenge id and
challenge exactly the URL-safe base64 this worker issues; anything else is
`request_invalid`. On the envelope the install id gets the same UUID check
(`request_invalid`); a malformed key id keeps AppAttestCore's own 401 codes
(`invalid_attestation_format` when it is not base64, `invalid_key_id` when it
is not 32 bytes), refused before any lookup. A POST with neither a bearer
nor a body is `invalid_json`.

An `authorization: Bearer <TRIAL_BEARER_TOKEN>` header selects the ops lane
(operator tooling and development builds): no lifetime units, its own daily
caps, the same global gates. A request with an `x-goog-api-key` header or any
query string is refused (`request_invalid`) before routing and without a log
line: no route takes a query, and Workers Logs attaches the request URL to
every event a request logs.

## Request contract (`POST /v1/trial/analyze`)

```json
{"feature":"ad_detection|chapters_summary","run_id":"<1-64 [A-Za-z0-9_-]>","window_index":0,"request":{…},"timeout_seconds":120}
```

- `timeout_seconds` is optional and can only shorten the budget (the model
  entry's per-call timeout, or 300 s for an escalated Chapters call). The
  proxy plans count, admission, forward and settlement to finish one second
  before it, so it releases the window before the device gives up.
- `request` keys: `contents` (required), `systemInstruction`,
  `generationConfig`, `model` (ignored: the URL carries the bundle's model).
  Anything else, `tools` and `cachedContent` included, is `request_invalid`.
- Turns are `{role: user|model, parts}`; parts are `{text}` only.
- `generationConfig` may carry `temperature` (0-2) and `topP` (0-1), kept as
  sent; `maxOutputTokens`, `thinkingConfig`, `responseMimeType` and
  `responseJsonSchema` are replaced by the bundle entry for `feature`. The
  thinking level is the entry's, except that Chapters keeps `high` when it
  asks for it (the pipeline's escalation level). Any other key is refused.
- The inner body is capped at `TRIAL_BODY_MAX_BYTES` (1,572,864); the
  envelope at twice that plus 16 KiB.

The forward goes to `providers.google.base_url + generate_path` of the
embedded bundle, with exactly `content-type: application/json` and
`x-goog-api-key`, redirects refused, no retry. The reply's status and body
come back unchanged with its `content-type` and a sanitized `retry-after`
(whole seconds, at most 30); every other provider header is dropped.

## Refusals

The proxy's own answers are `{"error":"<code>"}` with a string `error`
(Gemini's `error` is an object). No proxy-generated error answers 500; a
provider 500 passes through with its body, by the forward contract:

| Code | Status | Meaning |
| --- | --- | --- |
| `trial_exhausted` | 403 | trial mode: the install has used its lifetime units |
| `trial_run_bound` | 403 | the run would exceed `TRIAL_RUN_MAX_WINDOWS` windows or `TRIAL_RUN_MAX_INPUT_TOKENS` reserved input tokens |
| `trial_busy` | 409 | another window of this install is in flight; `retry_after_seconds` (≤ 10) and `retry-after` |
| `trial_paused` | 503 | the month's ceiling (trial mode), the daily backstop (open mode) or no price for the model |
| `bearer_limited` | 429 | the ops lane's daily caps |
| `request_invalid` | 400 | shape, forbidden key, an `x-goog-api-key` header or any query string (refused unlogged), a challenge or register identifier or an envelope install id not of the app's shape |
| `payload_too_large` | 413 | body cap |
| `unauthorized` | 401 | ops bearer wrong or missing |
| AppAttestCore codes | 400/401/413 | kept as AppAttestCore answers them: `invalid_json` (400, also a bodyless POST), `payload_too_large` (413), and 401 `missing_assertion`, `unknown_key`, `invalid_key_id`, `invalid_attestation_format`, `invalid_app_id`, `invalid_environment`, `invalid_counter`, `invalid_signature` and the other assertion codes |
| `missing_challenge_source` | 400 | the challenge request carried no client address |
| `trial_disabled` | 503 | `TRIAL_PROXY_ENABLED` is not `true` |
| `trial_unavailable` | 503 | config error (a missing or blank `CHALLENGE_SOURCE_HASH_KEY` outside development included), ledger unreachable, a lost admission, any unexpected failure, or the token count failed (then with `retry_after_seconds` 10 and `retry-after`: nothing was reserved or forwarded) |
| `provider_timeout` | 504 | the forward ran out of budget |
| `provider_unreachable` | 502 | the forward failed |
| `provider_body_too_large` | 502 | the reply passed 2 MiB |

## Status

`{"mode":"open"|"trial","units_remaining":N,"starts_at":"<TRIAL_MODE_STARTS_AT>","month_paused":bool}`.
Before `TRIAL_MODE_STARTS_AT` every install has its full lifetime count and
nothing is paused. After it, `month_paused` is the ceiling gate's own answer
for the cheaper feature's window admitted now (its per-window constant, priced
over the lock its default call would hold, the month that lock reaches into
included): true exactly when admission would refuse that window.

## Accounting

One SQLite-backed Durable Object, `TrialLedger` named `global`, admits and
settles every window inside `transactionSync` (a failed statement rolls the
operation back); it never waits on a provider. The state machine is
`src/ledger.rs`, tested on fake clocks over an in-memory store and the
production SQL on SQLite.

- **Reservation**: the model's documented maximum input (`max_input_tokens`
  in its `TRIAL_PRICE_TABLE` row) × input price + the entry's maximum output
  × output price, at the highest price in force until the reservation's
  deadline: a constant per window. It rests on Google's documented limits,
  not on any premise about tokenization: a prompt above the model's context
  limit is rejected unbilled, and output (thinking included) is capped by
  `maxOutputTokens`. A reservation settles to usage within its window, so
  the cost is room: trial mode pauses when less than one window's constant
  is left under the ceiling, and each window in flight holds the constant.
  A reservation whose deadline reaches into the next month is charged to
  both months. A count above `max_input_tokens` is refused
  (`trial_run_bound`) before anything is reserved.
- **Count**: Google `countTokens` on the rebuilt body is what the run bound,
  the daily backstop, the ops caps and the telemetry measure; it is never
  what is reserved. When it fails the window is refused
  (`trial_unavailable`, retry after 10 s) with nothing reserved or forwarded.
- **Settlement**: a 2xx with `promptTokenCount` and `totalTokenCount` settles
  to usage (output = answer + thinking), never above the reservation. Usage
  above it (only a documented limit or the price table being wrong can cause
  it) is recorded as the month's overrun, counts at the ceiling gate and
  raises the overrun alert that day. Provider 400, 401, 403, 404 and 429
  settle to zero. Everything else (5xx, timeouts, a lost reply, a 2xx without
  usage, any other status) keeps the whole reservation. Settlement is
  idempotent.
- **Locks**: one open reservation per install (one window per run and one
  run per install); on the ops lane, one per run. A reservation not settled
  by its forward budget plus 60 s expires charged in full and frees its lock.
- **Units** (trial mode): a run id's first admission takes a unit, including
  a run started before the flip; a resumed run id takes none. Runs that took a
  unit are kept for good.
- **Open mode**: no units; the global daily backstop applies, and runs that
  trial mode would have refused are counted (`trial_day.would_refuse_runs`).
- **Ceiling** (trial mode): checked on every reservation; the window in
  flight completes; a new UTC month starts from zero and releases nothing.

The object's alarm (at the earliest open deadline, at most an hour out)
expires lapsed reservations, flushes the mirror, prunes and retries pending
alerts. Every admission and settlement ends by storing it (there is always
housekeeping due); one that cannot still answers, logs `alarm_rearm_failed`
and retries in the background three times a second apart, and the next
entry point tries again. When the alarm itself cannot store its successor it
fails, so the runtime retries it.

D1 (`TRIAL_DB`) holds the App Attest tables and a write-behind mirror for ops
readback (`trial_install`, `trial_run`, `trial_month`, `trial_day`); the
object's storage is the truth and admission never waits on D1.

Alerts go to Pushover with the deployer's app token and user key: the ceiling
(once a month), the backstop and a missing price (once a day), provider
failures (5xx, timeouts, unreachable: at least 5 and at least 20 % of
forwards over six hours, once per window), five consecutive mirror failures,
and a settlement above its reservation (once a day).

## Embedded bundle

`build.rs` embeds the highest `Server/ModelGatewayWorker/manifests/analysis-policy/vN.json`.
The Worker reads only the trial model, its start date and lifetime units, the
Google endpoint, and each feature's entry for the trial model and response
schema. **A bundle publish that changes a trial entry is followed by a deploy
of this Worker.** Until then the stale Worker keeps sending its own entry; a
model Google no longer serves fails closed there (a 404 the device reads as
`model_unavailable`), never as extra spend. `cargo test` checks the embedded
entries against the file and every lane's vars against the bundle.

## Configuration

Vars in the template (every lane sets every var; named environments inherit
none):

| Var | dev | prod-staging | production |
| --- | --- | --- | --- |
| `APPLE_TEAM_ID` / `APPLE_BUNDLE_ID` | your App Attest identifiers | same | same |
| `APP_ATTEST_ENVIRONMENT` | `development` | `production` | `production` |
| `TRIAL_PROXY_ENABLED` | `false` until the lane is ready | same | same |
| `TRIAL_ALERT_LANE` | `dev` | `prod-staging` | `production` |
| `TRIAL_MODE_STARTS_AT` | `2027-01-01T00:00:00Z` | same | same |
| `TRIAL_LIFETIME_UNITS` | `5` (must equal the bundle's) | same | same |
| `TRIAL_MONTHLY_CEILING_USD` | `5` | `5` | `50` |
| `TRIAL_OPEN_DAILY_REQUESTS` | `60` | `60` | `300` |
| `TRIAL_OPEN_DAILY_INPUT_TOKENS` | `1600000` | `1600000` | `8000000` |
| `TRIAL_BEARER_DAILY_REQUESTS` / `_INPUT_TOKENS` | `40` / `2000000` | same | same |
| `TRIAL_RUN_MAX_WINDOWS` / `TRIAL_RUN_MAX_INPUT_TOKENS` | `12` / `400000` | same | same |
| `TRIAL_BODY_MAX_BYTES` | `1572864` | same | same |
| `TRIAL_PRICE_TABLE` | gemini-3.8-flash $0.75 / $3.75 per million from 2026-01-01, $1.50 / $7.50 from 2027-01-01, each row `max_input_tokens` 1048576 | same | same |

Each lane has its own ledger, so the non-production lanes get a small share
(a $5 ceiling holds about two windows in flight at list price).
`max_input_tokens` is the model's documented input limit: gemini-3.8-flash
takes 1,048,576 input and 65,536 output tokens (Google's model page,
https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash). A row without
it is a config error, and so is a limit above 100,000,000 tokens, a row whose
largest reservation would not fit the ledger's integers (2⁵³), or a
configuration whose worst month would not (31 days at the larger daily
request cap, each window at the table's largest reservation, plus a spill
month: `trial_config_error {field: TRIAL_PRICE_TABLE, reason:
month_out_of_range}`); update it with the model.

**Price rows are appended with a new `effective_from`, never edited in
place.** A replayed admission forwards only when its stored input rate,
output rate and amount are exactly what this version reserves for the same
window now; an in-place edit (or an earlier version's smaller amount) makes
the replay of a reservation made under the old row a refusal
(`trial_unavailable`, nothing forwarded), and the reservation expires as
usual.

A settlement whose reported usage would carry a month's amounts past what
storage holds keeps its accounting saturated at that bound, pauses the
month (no window is admitted into it in either mode) and raises the ceiling
alert, instead of rolling back.

Invocation logs are off on every lane, but Workers Logs still attaches the
request URL, path and method to each of the Worker's own log lines; that is
why a query string is refused unlogged, and why every failure, even an
unexpected one, answers `trial_unavailable` with one static line instead of
reaching the runtime as an exception.

## Local checks

```sh
cargo fmt --check
cargo test --locked
cargo clippy --locked --all-targets
cargo check --locked --target wasm32-unknown-unknown --lib
yarn workspace @opencast/trial-proxy-worker test:integration
yarn workspace @opencast/trial-proxy-worker deploy:dry-run
yarn workspace @opencast/trial-proxy-worker deploy:dry-run:prod-staging
yarn workspace @opencast/trial-proxy-worker deploy:dry-run:production
```

`cargo test` reads whichever of `wrangler.toml` and `wrangler.example.toml`
the checkout carries and holds the template to its disabled posture. The
integration suite builds the wasm Worker and drives it in workerd with local
D1 and the ledger object; Gemini is stubbed by replacing the isolate's
`fetch`, so no deployable setting can point the key anywhere else. Public CI
copies the template over `wrangler.toml` and switches on only the
development lane before running it.

## Deploy order

Per lane: create the D1 database and set its id in `wrangler.toml`, apply the
migrations, set the secrets, deploy, then check `/health` and the bearer
status.

```sh
yarn workspace @opencast/trial-proxy-worker exec wrangler d1 migrations apply TRIAL_DB --remote --env <lane>
yarn workspace @opencast/trial-proxy-worker exec wrangler secret put GEMINI_API_KEY --env <lane>
yarn workspace @opencast/trial-proxy-worker run deploy:<lane>
```

(The dev lane is the top-level config: drop `--env` and use `deploy`.) Dev
first, then prod-staging, then production. The production deploy carries
`TRIAL_MODE_STARTS_AT` from the first deploy, so the flip is a date, not a
deploy. Durable Object code updates land up to five minutes after a deploy
(`code_update_strategy` deferred); check object behaviour after that.

## Rollback

- Stop the trial without a code change: set `TRIAL_PROXY_ENABLED = "false"`
  for the lane and deploy; every route but `/health` answers `trial_disabled`.
- Roll back code: `wrangler rollback <version-id> --env <lane>`
  (`wrangler deployments list --name <worker>` lists versions, oldest first).
  The ledger's storage survives deploys and rollbacks; every settlement is
  idempotent by reservation id.

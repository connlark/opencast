# OpenCast Ad Analysis Worker

Self-hostable Cloudflare Worker code for detecting ad breaks from episode
transcripts. The Worker uses App Attest for public clients, D1 for challenge
state, Durable Objects for usage limits and asynchronous jobs, and a
deployer-provided Gemini API key. Yarn is the command surface for Wrangler.

This public copy does not include deployed Worker names, routes, D1 IDs,
Gemini credentials, bearer tokens, Cloudflare resources, or physical-device
App Attest captures.

## Setup

Install dependencies and copy the public config template:

```sh
yarn install
cp wrangler.example.toml wrangler.toml
```

Create your own D1 database, replace every `REPLACE_WITH_...` value, and keep
`PUBLIC_AD_ANALYSIS_ENABLED` set to `false` until App Attest, D1 migrations,
the Durable Object, Gemini, and abuse controls are ready.

`AD_ANALYSIS_POLICY` selects the serving policy bundle — a pinned
prompt, validator, and model. `promo_ad_breaks_v3` is the recall-first bundle
and pins its own model, ignoring `AD_ANALYSIS_GEMINI_MODEL`; any absent or
unrecognized value serves v2, which reads that model override. Changing the
policy also changes the cache namespace.

v3 sizes each Gemini call's timeout from the job's 570-second wall budget:
120 seconds for up to four transcript windows, 91 for five to eight, and 60
for nine. v2 keeps a 60-second cap.

Set required secrets with Wrangler; never commit their values:

```sh
yarn wrangler secret put GEMINI_API_KEY
yarn wrangler secret put CHALLENGE_SOURCE_HASH_KEY
```

The bearer-token endpoint is only for a private DEBUG or proof environment. If
you deliberately operate one, set its token with:

```sh
yarn wrangler secret put AD_ANALYSIS_CLIENT_TOKEN
```

Repeat secret commands with `--env prod-staging` or `--env production` when
configuring those environments.

Apply the schema to your D1 database:

```sh
yarn wrangler d1 migrations apply your-ad-analysis-db --remote
```

## Commands

```sh
yarn test
yarn typecheck
yarn test:integration
yarn deploy:dry-run
```

Run locally after creating `wrangler.toml`:

```sh
yarn dev
```

## Monitoring

`scripts/watch_ad_analysis.py` prints a read-only JSON snapshot of the
production and prod-staging Workers: `/health` plus Workers Observability
attempt, latency, and accounting counts. It never submits a job and prints no
raw log rows. It also counts accounting exchange errors, unavailable job reads,
alarm errors, storage resets and `exceededWallTime` outcomes; platform error
text is matched, never printed. It reads `CLOUDFLARE_ACCOUNT_ID` and
`CLOUDFLARE_API_TOKEN` from an env file; `--help` lists the arguments.

```sh
python3 scripts/watch_ad_analysis.py --credentials-env-file /path/to/operator.env \
  --production-worker your-ad-analysis-worker-production \
  --staging-worker your-ad-analysis-worker-prod-staging \
  --production-health-url https://ad-analysis.example.com/health \
  --staging-health-url https://ad-analysis-staging.example.com/health
python3 -B -m unittest discover -s scripts
```

## Result retention

A completed analysis is readable for 24 hours from durable completion; a failed
record keeps a 30-minute lifetime. The stored expiry is authoritative: polls,
cached submissions and content-proven subject joins never extend it, and a read
past expiry returns 404 even if the cleanup alarm is late. An explicit
submission may start a new run. The response schema carries no expiry field.

## Transient failures

If the job Durable Object throws instead of answering a submit or poll (for
example, a storage operation that times out and resets the object), the Worker
answers 503 `{"error":"job_unavailable"}`, not a plain-text 500. The body
deliberately carries no `failure` category: a failed read is not a job outcome,
and the job's durable record is unaffected. The app keeps polling the same job
handle on a bounded backoff instead of resubmitting.

Each exchange with the usage limiter has five seconds. A timeout, a failed
fetch, or a response that does not decode carries no limiter decision, so the
exchange is tried once more after 250 ms through a fresh stub. Decoded limiter
refusals (caps, identity errors) are never retried. A retried dispatch refused
as `attempt_already_dispatched` proves the first try committed, so the Gemini
call still runs exactly once. Two failed tries end the run with
`usage_limiter_error`.

These paths log structured events, with platform error text truncated to 200
characters:

- `ad_analysis_job_unavailable`: `op` (submit or poll) and the error.
- `ad_analysis_accounting_error`: `op`, `kind` (timeout, transport, decode, or
  status), the HTTP `status` and limiter `code` when present, `attempt` (0 or
  1), `elapsed_ms`, `run_id`, and `policy_revision`.
- `ad_analysis_alarm_error`: `op` and the error, for alarm storage failures
  that return to the Worker. A storage operation that hangs until the platform
  resets the object never returns, so it appears only as the platform's
  exception row and an `exceededWallTime` outcome.

## Security Defaults

- Keep App Attest on public write endpoints.
- Keep Gemini credentials and optional bearer tokens server-side.
- Keep public analysis disabled until the deployment is complete.
- Preserve request-size limits, transcript validation, challenge limits, and
  the Durable Object usage limiter.
- Do not commit API keys, bearer tokens, D1 exports, App Attest key IDs,
  install IDs, token hashes, private feeds, or real-device proof fixtures.

The checked-in tests are synthetic. Generate and retain any physical-device
App Attest fixture only in a private environment.

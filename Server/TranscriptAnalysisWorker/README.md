# OpenCast Transcript Analysis Worker

Self-hostable Rust Cloudflare Worker for generating episode chapters and a
summary from a completed transcript. The Worker sends transcript text—not
audio—to a deployer-configured Gemini model, authenticates public clients with
App Attest, stores challenge and billing state in D1, and uses Durable Objects
for asynchronous jobs and usage limits.

This public copy contains no deployed Worker names, live routes, D1 IDs,
Gemini credentials, bearer tokens, Cloudflare resources, or physical-device
App Attest captures.

## Setup

Install dependencies and copy the disabled public configuration template:

```sh
yarn install
cp wrangler.example.toml wrangler.toml
```

Replace every `REPLACE_WITH_...` value and every `your-...` resource name with
values from your Cloudflare and Apple accounts. Create one D1 database per
environment, keep the two Durable Object exports intact, and replace the
`transcript-analysis.example.com` production route with your own domain.

Keep both `PUBLIC_TRANSCRIPT_ANALYSIS_ENABLED` and `BILLING_REQUIRED` set to
`false` until App Attest, D1 migrations, Gemini, job limits, and the credit
policy are ready. The prod-staging and production templates bind a
deployer-owned PurchaseWorker; update those service names before enabling
billing. The development lane has no PurchaseWorker binding and uses its local
D1 credit backend only when billing is deliberately enabled.

Set required secrets with Wrangler; never commit their values:

```sh
yarn wrangler secret put GEMINI_API_KEY
yarn wrangler secret put CHALLENGE_SOURCE_HASH_KEY
```

The bearer-token route is for a private DEBUG or proof environment only. If
you deliberately operate one, set its token with:

```sh
yarn wrangler secret put TRANSCRIPT_ANALYSIS_CLIENT_TOKEN
```

Repeat the secret commands with `--env prod-staging` or `--env production`
when configuring those environments. Apply the D1 schema separately because
`wrangler deploy` does not run migrations:

```sh
yarn wrangler d1 migrations apply your-transcript-analysis-db --remote
```

## Commands

The real-device App Attest fixture is intentionally absent from the public
repository. This host-test command runs every fixture-independent target:

```sh
cargo test --locked \
  --lib \
  --test app_attest_migrations \
  --test coalescing \
  --test gemini_retry \
  --test job_state \
  --test prompt \
  --test routing \
  --test validation
cargo check --locked --target wasm32-unknown-unknown
```

For local workerd tests, enable `PUBLIC_TRANSCRIPT_ANALYSIS_ENABLED` only in
the development block of your untracked `wrangler.toml`, then run:

```sh
yarn test:integration
yarn test:billing
yarn test:purchase
yarn deploy:dry-run
```

`test:purchase` also compiles the sibling PurchaseWorker test bundle. Run the
Worker locally with `yarn dev`.

## API

- `GET /health` reports service availability.
- `POST /v1/app-attest/challenge`, `POST /v1/app-attest/register`, and
  `POST /v1/install/delete` manage App Attest identity state.
- `POST /v1/transcript-analysis/transcript` validates and submits transcript
  analysis. Asynchronous requests return a job identifier and poll delay.
- `POST /v1/transcript-analysis/jobs/{job_id}` polls an authorized job.
- `POST /v1/transcript-analysis/account/bootstrap` links an App Attest install
  to the configured credit authority.

## Security and Privacy Defaults

- Keep public analysis and billing disabled until deployment is complete.
- Keep App Attest on every public write route; the bearer lane is never a
  production authentication substitute.
- Keep Gemini and challenge-key material in Worker secrets.
- Preserve request-size, transcript-length, per-install, per-host, and global
  usage caps; preserve job membership and content-possession checks.
- Preserve fail-closed credit-backend validation and the reserve/settle/release
  lifecycle when billing is enabled.
- Do not log transcript or model text, feed URLs, account/install identifiers,
  job history, or D1 exports.

The checked-in integration fixtures use synthetic identities. Generate and
retain any physical-device App Attest capture only in a private environment.

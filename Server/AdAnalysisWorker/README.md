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

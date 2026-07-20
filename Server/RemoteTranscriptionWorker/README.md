# OpenCast Remote Transcription Worker

Self-hostable Cloudflare Worker code for server-side podcast transcription.
It combines App Attest, D1, Durable Objects, private R2 staging, Workers AI,
the service-bound media worker, and an optional service-bound purchase worker.
Yarn is the command surface for Wrangler.

The checked-in `wrangler.toml` is a disabled public template. It contains no
deployed names, routes, resource IDs, account identifiers, or credentials.
Replace every `REPLACE_WITH_...` value and every `your-...` resource name with
resources from your own Cloudflare and Apple accounts.

## Setup

Install dependencies and create isolated D1 databases and private R2 buckets
for every lane you intend to run:

```sh
yarn install
yarn wrangler d1 migrations apply your-remote-transcription-db --remote
```

Set required secrets with Wrangler; never commit their values:

```sh
yarn wrangler secret put CHALLENGE_SOURCE_HASH_KEY
yarn wrangler secret put URL_ENCRYPTION_KEY
yarn wrangler secret put R2_S3_ACCESS_KEY_ID
yarn wrangler secret put R2_S3_SECRET_ACCESS_KEY
```

The bearer lane is only for an isolated development environment. If you
deliberately enable it, set its token there and nowhere else:

```sh
yarn wrangler secret put DEV_BEARER_TOKEN
```

Configure and deploy `PurchaseWorker` and `TranscriptionMediaWorker` before
enabling their service bindings. Keep `PUBLIC_REMOTE_TRANSCRIPTION_ENABLED`
and `PURCHASES_ENABLED` false until App Attest, storage, secrets, migrations,
spend limits, and abuse controls are all ready. Cron templates are empty by
default.

## Commands

```sh
yarn test
yarn typecheck
yarn test:integration
yarn test:production
yarn deploy:dry-run
```

The provisioning scripts are fail-closed helpers. Review their placeholder
resource names before running them against your account.

## Security Defaults

Preserve App Attest on write endpoints, encrypted enclosure URLs, strict
origin-fetch SSRF/redirect/wall limits, duration and source-size caps,
per-account admission limits, global inference concurrency and spend caps,
and the container's R2-only egress posture. Development bearer/probe surfaces
must remain impossible outside the development lane. Never commit Worker
secrets, D1/R2 exports, job histories, enclosure URLs, install identifiers,
or App Attest proof material.

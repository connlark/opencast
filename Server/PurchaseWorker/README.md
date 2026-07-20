# OpenCast Purchase Worker

Self-hostable private Cloudflare Worker code for remote-transcription credit
accounting and Apple in-app purchase verification. It is service-bound only:
the public template exposes neither routes nor workers.dev endpoints.

The checked-in `wrangler.toml` uses disabled schedules and placeholder D1,
bundle, and Worker values. The embedded Apple Root CA is public certificate
material; Apple signing credentials are not included.

## Setup

```sh
yarn install
yarn wrangler d1 migrations apply your-purchase-db --remote
yarn wrangler secret put APPLE_IAP_ISSUER_ID
yarn wrangler secret put APPLE_IAP_KEY_ID
yarn wrangler secret put APPLE_IAP_PRIVATE_KEY
yarn wrangler secret put APP_TX_HMAC_KEY
yarn wrangler secret put APP_TX_ENCRYPTION_KEY
```

Replace every `REPLACE_WITH_...` value and `your-...` resource name before a
deployment. Use isolated D1/DO state and credentials per lane. Enable a
reconciliation cron only after Apple verification and liability monitoring
are configured.

Use independent random values of at least 32 bytes for `APP_TX_HMAC_KEY` and
`APP_TX_ENCRYPTION_KEY`; do not reuse them across lanes.

## Commands

```sh
yarn test
yarn typecheck
yarn test:integration
yarn test:production
yarn deploy:dry-run
```

Tests mint synthetic StoreKit JWS fixtures locally. Do not commit generated
fixtures, private keys, transaction histories, account/install identifiers,
or notification payloads. Preserve signature-chain, bundle, environment,
transaction, idempotency, reconciliation, and liability checks.

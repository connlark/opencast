# OpenCast Notifications Worker

Self-hostable Cloudflare Worker code for OpenCast episode notifications. The
Worker is implemented in Rust with `workers-rs`; Yarn is the command surface for
Wrangler.

This public copy is a template. It does not include the private deployed Worker
names, routes, D1 database IDs, APNs credentials, Cloudflare account resources,
device tokens, production proof data, or private admin endpoints.

## Setup

Install dependencies:

```sh
yarn install
```

Create your own Cloudflare D1 database and APNs mTLS certificate, then copy the
example config:

```sh
cp wrangler.example.toml wrangler.toml
```

Replace every `REPLACE_WITH_...` value in `wrangler.toml` with resources from
your own Cloudflare and Apple developer accounts. Keep public notifications,
debug endpoints, admin endpoints, and cron polling disabled until App Attest,
APNs, D1 migrations, routes, and abuse controls are configured.

Set required secrets with Wrangler commands, never by committing values:

```sh
yarn wrangler secret put CHALLENGE_SOURCE_HASH_KEY
yarn wrangler secret put ADMIN_TEST_TOKEN
```

`ADMIN_TEST_TOKEN` is only for private proof environments where admin endpoints
are explicitly enabled.

## Commands

```sh
yarn test
yarn typecheck
yarn deploy:dry-run
python3 ../../scripts/check-feed-resource-policy.py
node tests/feed-runtime.mjs
```

The runtime harness starts the packaged Worker in workerd with isolated D1 and
mock feed/APNs services. It exercises baseline establishment, malformed-feed
rollback, update delivery, deduplication, and the Worker memory ceiling without
using remote credentials or services. Run `yarn deploy:dry-run` first so the
packaged `build/` modules exist.

Apply migrations to your own D1 database:

```sh
yarn wrangler d1 migrations apply your-notifications-db --remote
```

Run locally after you have a local `wrangler.toml`:

```sh
yarn dev
```

## Security Defaults

Keep these properties intact when adapting the Worker:

- App Attest protects write endpoints.
- APNs credentials stay server-side through Cloudflare mTLS or an equivalent
  server-side credential path.
- Admin and debug endpoints stay disabled by default and token-protected when
  enabled.
- Public notification enrollment stays disabled until your D1, APNs, App
  Attest, route, cron, and abuse controls are ready.
- Request body caps, feed URL validation, redirect limits, per-install caps,
  per-host caps, and global admission caps remain in place.
- Raw APNs private keys, Cloudflare API tokens, D1 exports, APNs device tokens,
  App Attest key IDs, token hashes, install IDs, and private feed URLs must not
  be committed.

The routing test is safe to run publicly. Captured physical-device App Attest
fixtures are intentionally omitted from the OSS tree; generate your own private
fixtures if you need device-level attestation proof coverage.

## Feed Resource Policy

The app and Worker share explicit ceilings for unusually large catalogs. The
Worker accepts at most 128 MiB of decoded XML and 100,000 raw RSS items, streams
the response through a bounded parser, and limits XML depth, individual text
fields, per-item text, and cumulative text processing. Two scans may run per
isolate; each polling invocation also has bounded elapsed-time and decoded-byte
admission budgets.

Only a complete successful scan may send notifications or advance a feed
checkpoint. The scanner retains bounded channel metadata, notification
candidates, and recent publication timestamps instead of materializing the
complete catalog in memory. `scripts/check-feed-resource-policy.py` keeps the
Swift and Rust limits aligned.

# OpenCast Notifications Worker

Self-hostable Cloudflare Worker code for OpenCast episode notifications. The
Worker is implemented in Rust with `workers-rs`; Yarn is the command surface for
Wrangler.

This public copy is a template. It does not include Connor's deployed Worker
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
```

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

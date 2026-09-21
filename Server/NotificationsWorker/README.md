# OpenCast Notifications Worker

Self-hostable Cloudflare Worker for OpenCast episode notifications, written in
Rust with `workers-rs`. Yarn is the command surface for Wrangler.
`adapter/index.js` is the named-entrypoint and Queue interop layer; validation,
authorization and delivery policy stay in Rust.

This Worker owns App Attest registration, subscriptions, durable delivery and
APNs. It does **not** fetch RSS: polling lives in the companion
[`FeedPollingWorker`](../FeedPollingWorker/README.md), which links this crate as
a library and calls back through a service binding. Deploy both for new-episode
pushes. Queues are wakeups; D1 is the authority.

This public copy is a template. It contains no deployed Worker names, routes,
D1 IDs, APNs credentials, device tokens or proof data.

## Setup

```sh
yarn install
cp wrangler.example.toml wrangler.toml
```

Replace every `REPLACE_WITH_...` value with your own Cloudflare and Apple
resources, and provision each one before deploying: the config only declares
them. Per lane you need:

- a **D1 database** (`APP_ATTEST_DB`);
- an **mTLS certificate** (`APNS_CERT`) for APNs;
- an **R2 bucket** (`FEED_SNAPSHOTS`) for private feed history;
- three **Queue producer/consumer pairs** with dead-letter queues:
  `EVENT_QUEUE`, `EPISODE_DELIVERY_QUEUE` and `JOB_DELIVERY_QUEUE`;
- a **service binding** `NOTIFICATION_EVENTS` → this Worker's `FeedEvents`
  entrypoint.

Three template values are load-bearing, not placeholders:

- **Queue names.** Ingress rejects any message whose queue is not
  `opencast-notification-{event,episode,job}-<lane>`. Only the lane suffix
  (`development`, `prod-staging` or `production`) is yours to choose.
- **`main = "adapter/index.js"`.**
- **`compatibility_flags = ["enable_request_signal"]`.** The fetch entrypoint
  uses the request abort signal to release scan capacity when a client
  disconnects.

Set secrets with Wrangler, never in the repository:

```sh
yarn wrangler secret put CHALLENGE_SOURCE_HASH_KEY
```

Keep public notifications, debug endpoints, cron and every `NOTIFICATION_*`
switch off until App Attest, APNs, migrations, routes and abuse controls are
ready.

### Enablement is a dual switch

Each capability needs its `NOTIFICATION_*` variable in `wrangler.toml` **and**
its row in the D1 `n_control` table, which the migrations seed disabled. The D1
row is part of every write fence, so it is an independent brake. A deployment
with the variables `"true"` and `n_control` untouched starts cleanly and does
nothing.

| `n_control` row | Environment variable | Gates |
| --- | --- | --- |
| `dispatcher_admission` | `NOTIFICATION_DISPATCHER_ADMISSION` | admitting feeds for polling |
| `feed_observation` | `NOTIFICATION_FEED_OBSERVATION` | scanning and publishing observations |
| `episode_activation` | `NOTIFICATION_EPISODE_ACTIVATION` | turning observations into releases |
| `episode_send` | `NOTIFICATION_EPISODE_SEND` | sending episode pushes |
| `job_enrollment` | `NOTIFICATION_JOB_ENROLLMENT` | enrolling job notifications |
| `job_send` | `NOTIFICATION_JOB_SEND` | sending job pushes |
| `cleanup` | `NOTIFICATION_CLEANUP` | snapshot and observation garbage collection |
| `five_minute_polling` | `NOTIFICATION_FIVE_MINUTE_POLLING` | a bounded fixture experiment; leave it off |

Enable a row once the rest of the lane is ready:

```sh
yarn wrangler d1 execute your-notifications-db --remote \
  --command "UPDATE n_control SET enabled=1, revision=revision+1 WHERE name='episode_send'"
```

### Migrations

```sh
yarn wrangler d1 migrations apply your-notifications-db --remote
```

A fresh database applies everything in one pass. An existing one must not:
`0025` and `0026` are an expand/contract pair. Apply `0025` alone, deploy both
Workers, let old invocations and leases drain, then apply `0026`. Current
binaries need `0025` or later; registration confirmation needs `0027`.

Before running DDL of your own, inventory incoming foreign keys, indexes and
triggers. `n_feed` has a cascading child table and must never be rebuilt.
Migration files are immutable.

### Cron

The scheduled handler reconciles delivery and prunes retention; it does not
poll feeds. Once a lane is live it is required. Leave `crons = []` until then,
then enable a one-minute trigger.

## Commands

```sh
yarn dev
yarn test
yarn typecheck
yarn deploy:dry-run
python3 ../../scripts/check-feed-resource-policy.py
node tests/storage-cleanup.mjs
node tests/current-schema-upgrade.mjs
node tests/catalog-contract-runtime.mjs
node tests/current-engine-runtime.mjs
node tests/delivery-runtime.mjs
node tests/observation-runtime.mjs
node tests/feed-cancellation-runtime.mjs
```

The `node` harnesses run the packaged Worker in workerd with isolated D1, R2
and Queues and mocked APNs; they need no remote credentials. Run
`yarn deploy:dry-run` first so `build/` exists. The contract oracles under
[`scripts/notifications-overhaul/`](../../scripts/notifications-overhaul/README.md)
run with plain `node --test`.

Captured physical-device App Attest fixtures are omitted from this tree;
generate your own if you need device-level attestation coverage.

## Security defaults

Keep these intact when adapting the Worker:

- App Attest protects write endpoints.
- APNs credentials stay server-side, through Cloudflare mTLS or an equivalent.
- Debug endpoints stay off by default.
- Named capabilities are selected by **service bindings only**, never by
  request headers or URLs. A public request cannot reach `FeedEvents`,
  `FeedObservations` or `FeedControl`.
- Body caps, feed URL validation, redirect limits and the per-install, per-host
  and global admission caps stay in place.
- Queue messages and logs carry opaque IDs, counts, timing and disposition
  codes, never URLs, tokens or validators.
- Never commit APNs keys, Cloudflare API tokens, D1 exports, device tokens, App
  Attest key IDs, install IDs or private feed URLs.

## Endpoints

Public HTTP surface, App Attest protected unless noted:

- `GET /health` returns `{ "message": "hello world" }`.
- `POST /v1/app-attest/challenge` creates a one-time registration challenge.
- `POST /v1/app-attest/register` verifies an Apple attestation and stores the
  install's public key. The request carries the plaintext challenge; D1 stores
  only its hash.
- `POST /v1/devices/register` stores the current APNs token. Its APNs
  environment must match the lane, or the request returns
  `apns_environment_mismatch`.
- `POST /v1/devices/unregister` disables the token. The raw token is cleared;
  its hash is kept for audit and dedupe.
- `POST /v1/subscriptions/sync` replaces the install's full subscription set.
  All of a sync's writes land in one `db.batch()` transaction, so a 200-feed
  sync costs a handful of D1 subrequests. An unchanged live subscription is
  rewritten at most once a day; a changed preference, a resubscribe or a new
  feed writes at once.
- `POST /v1/install/delete` deletes the install's keys, challenges, devices,
  subscriptions and notification audit rows.
- `POST /v1/secure/hello` and `POST /v1/debug/send-test-push` are diagnostics,
  disabled in production.

`PUBLIC_NOTIFICATIONS_ENABLED = "false"` is the kill switch for paths that
enroll new state. It does not block unregister or install delete. Other routes
return a small JSON error.

Sync request and response:

```json
{ "subscriptions": [
  { "feed_url": "https://example.com/feed.xml", "notifications_enabled": true }
] }
```

```json
{
  "message": "synced",
  "registration_ready": true,
  "accepted": [{ "feed_url": "https://example.com/feed.xml", "title": "Example Podcast" }],
  "rejected": [{ "feed_url": "http://localhost/feed.xml", "error": "blocked_host" }]
}
```

Internal surfaces, reachable only through a service binding:

- `FeedEvents`, `AdAnalysisEvents`, `RemoteTranscriptionEvents`: producer-scoped
  event ingress (`POST /v1/events`), plus `POST /v1/interests/register` and
  `/cancel` for the non-feed producers.
- `FeedObservations`: bounded scan, prepare, drain, outbox and GC operations. It
  has storage and producer authority but no APNs credentials.
- `FeedControl`: `POST /inspect`, `/pause`, `/pause-sends`, `/resume` or
  `/resume-sends` with `{ "feed_id": "<opaque digest>", "expected_epoch": 1 }`.
  Admission and send pauses are independent, and a stale epoch returns 409. For
  scheduling, repair and aggregate health use FeedPollingWorker's
  `PollingControl`.

## Registration recovery

`registration_ready` is true only when the install has an enabled, nonempty
APNs token for this lane and bundle. It describes server state at response
time, not delivery. The field is optional in both directions, so old clients
and old servers interoperate.

A `false` makes the client re-upload its current token in the same pass, which
is how an endpoint the server disabled (after an APNs 410, say) recovers without
a relaunch. Migration `0027` keeps `token_generation` when the endpoint is
unchanged, so a confirmation never invalidates a delivery claim. Each upload
costs one App Attest assertion with the existing key, not a new attestation.
There is no per-upload rate limit; the five-device cap still applies.

## Storage

- `n_feed` is scheduling authority. Epoch, eligibility and schedule-generation
  fences apply to every commit.
- `n_feed_catalog` holds canonical and source URLs, metadata and admission
  timestamps, separate from engine authority.
- `n_delivery_history` preserves historical sends. Current event and delivery
  records are live data under fixed retention.
- Install deletion erases every install-scoped row, delivery history included.
- `feed_subscriptions.updated_at` means "changed, or last confirmed by a sync",
  so it can trail an install's latest sync by up to a day.
  `app_attest_keys.last_used_at` is the exact last authenticated request.

## Client rendering

Episode pushes use `aps.category = OPENCAST_EPISODE` and a custom `opencast`
payload. The app's Notification Service Extension downloads the HTTPS
`artwork_url` and attaches it; its Notification Content Extension renders the
expanded card. Proofs need a physical device: the simulator has no App Attest
and does not render remote pushes.

## Feed resource policy

The app and both Workers share explicit ceilings. A scan accepts at most
128 MiB of decoded XML and 100,000 items through a streaming, depth- and
text-bounded parser. Two scans may run per isolate, each under elapsed-time and
decoded-byte budgets, and an abandoned client request disposes the scan it
owned. Only a complete successful scan may publish an observation or advance a
checkpoint.

`scripts/check-feed-resource-policy.py` keeps the Swift and Rust limits
aligned. Queue-side polling deadlines are documented in
[`FeedPollingWorker`](../FeedPollingWorker/README.md).

## App Attest verifier

The verifier uses `x509-parser`, RustCrypto P-256/P-384, `minicbor` and `sha2`.
The `appattest` crate was not an option because its `aws-lc-sys` dependency does
not compile for the Workers wasm target; its DER extension walking is adapted
here under MIT, with attribution in the source. No ECDSA code is custom.

The shared `AppAttestCore` accepts both legacy 37-byte authenticator data and
iOS 27's signed CBOR extensions. Signature verification covers every original
byte, and replay counters, request binding and app identity checks stay
mandatory. `AppAttestCore/tests/assertion_extensions.rs` covers extended,
tampered, malformed, legacy and replayed assertions.

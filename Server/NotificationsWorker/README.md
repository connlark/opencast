# OpenCast Notifications Worker

Self-hostable Cloudflare Worker for OpenCast episode notifications, written in
Rust with `workers-rs`. Yarn is the command surface for Wrangler.
`adapter/index.js` is the named-entrypoint and Queue interop layer; validation,
authorization and delivery policy stay in Rust.

This Worker owns App Attest registration, subscriptions, durable delivery and
APNs. It does **not** fetch RSS: polling lives in the companion
[`FeedPollingWorker`](../FeedPollingWorker/README.md), which links this crate as
a library and calls back through a service binding. Deploy both for new-episode
pushes. Queues are wakeups; PostgreSQL, reached through a Hyperdrive binding
(`DB`), is the authority.

This public copy is a template. It contains no deployed Worker names, routes,
Hyperdrive or database identities, APNs credentials, device tokens or proof
data.

## Setup

```sh
yarn install
cp wrangler.example.toml wrangler.toml
```

Replace every `REPLACE_WITH_...` value with your own Cloudflare and Apple
resources, and provision each one before deploying: the config only declares
them. Per lane you need:

- a **PostgreSQL database** reached through a **Hyperdrive configuration**
  bound as `DB` (see [Storage setup](#storage-setup));
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
switch off until App Attest, APNs, the database schema, routes and abuse
controls are ready.

### Enablement is a dual switch

Each capability needs its `NOTIFICATION_*` variable in `wrangler.toml` **and**
its row in the `n_control` table, which the schema seeds disabled. The row is
part of every write fence, so it is an independent brake. A deployment
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

Enable a row once the rest of the lane is ready, as the schema owner (the
runtime role can read the controls but not change them):

```sh
psql "<schema owner connection>" \
  --command "UPDATE opencast.n_control SET enabled=1, revision=revision+1 WHERE name='episode_send'"
```

### Storage setup

Storage is PostgreSQL 16 or later with UTF8 server encoding; the Worker reaches
it through a Hyperdrive configuration bound as `DB`. As the schema owner, apply
`postgres/migrations/0001` through `0004` and the grant files to one runtime
role, in the single-runtime-role order of
[`postgres/README.md`](postgres/README.md). Create the Hyperdrive configuration
with the runtime role's credentials, never the owner's, and put its ID in the
lane's `[[hyperdrive]]` block. FeedPollingWorker binds its own `DB` to the same
database.

`STORAGE_AUTHORITY = "postgres"` selects this storage; an absent or any other
value is refused at the first storage call. `STORAGE_IDENTITY` pins a version
to one database, `v1;<lane>;postgres;pg:<database name>[:<system identifier>]`:
set it to your database's identity, or delete the line for an ungated
deployment. The template's `REPLACE_WITH_*` pin does not parse, so an unedited
lane refuses every storage call and writes nothing.

Migration files are immutable; a schema change is a new migration. Before
running DDL of your own, inventory incoming foreign keys, indexes and
triggers. `n_feed` has a cascading child table and must never be rebuilt.

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
bash postgres/local/local-postgres.sh up
node postgres/local/test-local-postgres.mjs
node tests/postgres/test-sql.mjs
node tests/postgres/test-database.mjs
node tests/postgres/test-storage.mjs
node tests/postgres/test-proxy.mjs
node tests/postgres/test-timing.mjs
node tests/postgres/test-witness.mjs
node tests/catalog-contract-runtime.mjs
node tests/current-engine-runtime.mjs
node tests/delivery-runtime.mjs
node tests/observation-runtime.mjs
node tests/feed-cancellation-runtime.mjs
node tests/storage-gc-runtime.mjs
node tests/identity-cache-runtime.mjs
```

`postgres/local/local-postgres.sh up` starts the local test topology: one
container on `127.0.0.1:55432` (`OPENCAST_PG_PORT`) running PostgreSQL 18.6
from its multi-platform index digest (your runtime runs your platform's entry),
the schema installed into a connection-free template, and `opencast_dev`
cloned from it. It uses Podman when installed, otherwise Docker;
`OPENCAST_CONTAINER_RUNTIME=docker` chooses Docker Desktop explicitly (that path
is not yet verified). With `OPENCAST_PG_PSQL=host` it uses your own psql
against `OPENCAST_PG_HOST` and `OPENCAST_PG_PORT` instead, overriding any
inherited `PG*` connection variable with a notice. Its passwords are fixed
local constants, not secrets. `test-local-postgres.mjs` needs exclusive use of
the topology: while it runs it changes the local roles' settings and the install
marker (restoring both before it ends), so never run it beside another run of
it, `install`, `reset`, `prune` or anything relying on those roles or the
marker. Suites that only clone the template need no such serialization.

The `node` harnesses run the packaged Worker in workerd with isolated R2 and
Queues, mocked APNs and a PostgreSQL clone of the topology's template per
instance; they need no remote credentials. `OPENCAST_TEST_STORAGE` may be unset
or `postgres`; any other value is refused. Run `yarn deploy:dry-run` first so
`build/` exists. `test-proxy.mjs`, `test-timing.mjs` and `test-witness.mjs`
also need the storage-fixture build
(`worker-build --release --out-dir <dir> --no-default-features --features
storage-fixture`, named by `OPENCAST_FIXTURE_BUILD`), and
`storage-selection-runtime.mjs` takes both Workers' packaged builds
(`OPENCAST_POSTGRES_BUILD`, `OPENCAST_POLLING_POSTGRES_BUILD`) and needs no
database. The contract oracles under
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
- Never commit APNs keys, Cloudflare API tokens, database dumps, device tokens, App
  Attest key IDs, install IDs or private feed URLs.

## Endpoints

Public HTTP surface, App Attest protected unless noted:

- `GET /health` returns `{ "message": "hello world" }`.
- `POST /v1/app-attest/challenge` creates a one-time registration challenge.
- `POST /v1/app-attest/register` verifies an Apple attestation and stores the
  install's public key. The request carries the plaintext challenge; storage
  keeps only its hash.
- `POST /v1/devices/register` stores the current APNs token. Its APNs
  environment must match the lane, or the request returns
  `apns_environment_mismatch`.
- `POST /v1/devices/unregister` disables the token. The raw token is cleared;
  its hash is kept for audit and dedupe.
- `POST /v1/subscriptions/sync` replaces the install's full subscription set.
  All of a sync's writes land in one storage transaction of array
  statements, so a 200-feed sync costs a handful of statements. An unchanged live subscription is
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
a relaunch. Registration confirmation keeps `token_generation` when the endpoint is
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

Notification text comes from one pipeline, `src/notification_text.rs`. It runs
when the observation scan builds a release candidate and again, idempotently,
when delivery renders the APNs alert. It cleans the whole feed description (or
the `content:encoded` show notes when the description is empty or repeats the
title) into single-line prose the way a browser would read the markup: inline
elements add no whitespace, other element boundaries become a space, comments
and script or style bodies vanish, entities decode to their real characters,
and bare URLs shrink to their host. Only then is the prose bounded to 512
bytes at a word boundary with an ellipsis. Never bound the raw markup: a long
`<a href>` inside the first 512 bytes can swallow all but the first words of a
summary. The content extension applies the same rules for the rare payload
that had to drop `episode_summary`.

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

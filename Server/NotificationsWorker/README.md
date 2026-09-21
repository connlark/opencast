# OpenCast Notifications Worker

Self-hostable Cloudflare Worker code for OpenCast episode notifications. The
Worker is implemented in Rust with `workers-rs`; Yarn is the command surface for
Wrangler. `adapter/index.js` is the required Workers named-entrypoint and queue
interop layer — all validation, authorization and delivery policy stay in Rust.

This Worker owns App Attest registration, subscription interests, durable
notification delivery and APNs. It does **not** fetch RSS: feed polling and
adaptive scheduling live in the companion
[`FeedPollingWorker`](../FeedPollingWorker/README.md), which links this crate as
a Rust library and calls back through a service binding. Deploy both if you want
new-episode pushes; queues are wakeups and D1 is the authority.

This public copy is a template. It does not include the private deployed Worker
names, routes, D1 database IDs, APNs credentials, Cloudflare account resources,
device tokens, production proof data, or private admin endpoints.

## Setup

Install dependencies:

```sh
yarn install
```

Create your own Cloudflare resources, then copy the example config:

```sh
cp wrangler.example.toml wrangler.toml
```

Replace every `REPLACE_WITH_...` value in `wrangler.toml` with resources from
your own Cloudflare and Apple developer accounts. You need, per lane:

- a **D1 database** (`APP_ATTEST_DB`) — auth, subscriptions, feeds, delivery;
- an **mTLS certificate** (`APNS_CERT`) for APNs;
- an **R2 bucket** (`FEED_SNAPSHOTS`) for private immutable feed history;
- three **Queue producer/consumer pairs** with dead-letter queues —
  `EVENT_QUEUE`, `EPISODE_DELIVERY_QUEUE` and `JOB_DELIVERY_QUEUE`;
- a **service binding** `NOTIFICATION_EVENTS` → this Worker's `FeedEvents`
  entrypoint.

Resource declarations in the config are declarations only: provision each one
explicitly before deploying, including Queue retention.

The queue names in the template are **not decoration**. The queue ingress
compares each delivered message against
`opencast-notification-{event,episode,job}-<lane>` and rejects anything else, so
keep those names (only the lane suffix is yours to choose among `development`,
`prod-staging` and `production`).

Keep `main = "adapter/index.js"`, and keep
`compatibility_flags = ["enable_request_signal"]`: the fetch entrypoint uses the
native request abort signal to release scan capacity when a client disconnects,
and the runtime harnesses read the flag from `wrangler.toml`.

Keep public notifications, debug endpoints, cron, and every `NOTIFICATION_*`
switch disabled until App Attest, APNs, D1 migrations, routes, and abuse
controls are configured.

Set required secrets with Wrangler commands, never by committing values:

```sh
yarn wrangler secret put CHALLENGE_SOURCE_HASH_KEY
```

### Enablement is a dual switch

Every capability gate is checked twice: the `NOTIFICATION_*` environment
variable in `wrangler.toml` **and** a row in the `n_control` D1 table, which the
migrations seed disabled. Both must allow an operation before it runs, and the
D1 control is part of the write fence rather than a startup read, so it is an
independently effective brake. A deployment whose variables are `"true"` while
`n_control` is still seeded off will start cleanly and do nothing.

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

Enable a row with an ordinary D1 statement once the rest of the lane is ready:

```sh
yarn wrangler d1 execute your-notifications-db --remote \
  --command "UPDATE n_control SET enabled=1, revision=revision+1 WHERE name='episode_send'"
```

### Migrations

Apply migrations to your own D1 database:

```sh
yarn wrangler d1 migrations apply your-notifications-db --remote
```

A **fresh** database applies the whole sequence in one pass. An **existing**
database running an older binary must not: `0025` and `0026` are a two-phase
expand/contract pair. Apply `0025` alone, deploy both Workers, wait for the old
invocation and lease window to drain, then apply `0026` alone. Current binaries
require `0025` or later; registration-confirmation binaries require `0027`.
Inventory every incoming foreign key, index and trigger before running DDL of
your own — `n_feed` has a cascading child table and must never be rebuilt.

### Cron

The scheduled handler no longer polls feeds. It reconciles durable delivery and
prunes shared authentication/subscription retention, so once a lane is live it
is *required*, not optional. Leave `crons = []` until the lane is configured,
then enable a one-minute trigger.

Run locally after you have a local `wrangler.toml`:

```sh
yarn dev
```

## Commands

```sh
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

The runtime harnesses start the packaged Worker in workerd with isolated D1, R2
and Queues and mocked APNs. They exercise the populated migration upgrades, the
public catalog/registration/sync/erasure contract, queued enrollment and control
fencing, durable event fan-out and sending, bounded observation, and the Worker
memory ceiling — without remote credentials or services. Run
`yarn deploy:dry-run` first so the packaged `build/` modules exist.

The cancellation harness starts the same packaged entrypoint with the
compatibility flags from `wrangler.toml` and checks that an abandoned client
request disposes the scan it owned: native request signals, transport disposal,
permit reuse, late continuations, and repeat-poll deduplication. Reports land in
the system temporary directory by default.

The contract oracles under [`scripts/notifications-overhaul/`](../../scripts/notifications-overhaul/README.md)
run with plain `node --test` and need no Cloudflare resources at all.

## Security Defaults

Keep these properties intact when adapting the Worker:

- App Attest protects write endpoints.
- APNs credentials stay server-side through Cloudflare mTLS or an equivalent
  server-side credential path.
- Debug endpoints stay disabled by default.
- Named capabilities are selected by **service bindings only**, never by request
  headers or URLs. A public request cannot reach `FeedEvents`,
  `FeedObservations` or `FeedControl` no matter what it sends.
- Public notification enrollment stays disabled until your D1, APNs, App
  Attest, route, cron, and abuse controls are ready.
- Request body caps, feed URL validation, redirect limits, per-install caps,
  per-host caps, and global admission caps remain in place.
- Queue references carry a schema version, lane, opaque feed ID, owner epoch,
  dispatch generation, due time and step — never URLs, tokens or validators.
  Structured logs carry only opaque identifiers, counts, timing and disposition
  codes.
- Raw APNs private keys, Cloudflare API tokens, D1 exports, APNs device tokens,
  App Attest key IDs, token hashes, install IDs, and private feed URLs must not
  be committed.

The routing test is safe to run publicly. Captured physical-device App Attest
fixtures are intentionally omitted from the OSS tree; generate your own private
fixtures if you need device-level attestation proof coverage.

## Endpoints

Public HTTP surface (App Attest protected unless noted):

- `GET /health` returns `{ "message": "hello world" }`.
- `POST /v1/app-attest/challenge` creates a one-time registration challenge.
- `POST /v1/app-attest/register` verifies an Apple App Attest attestation and
  stores the install-scoped App Attest public key.
- `POST /v1/secure/hello` verifies an App Attest assertion over
  `POST\n/v1/secure/hello\n<sha256(payload)>` and returns
  `{ "message": "hello world" }` on success. Disabled in production.
- `POST /v1/devices/register` stores the current APNs device token after App
  Attest assertion verification. The submitted APNs environment must match the
  configured Worker lane, or the request returns `apns_environment_mismatch`.
- `POST /v1/devices/unregister` disables the current APNs device token for the
  authenticated install. The raw APNs token is cleared while the token hash is
  retained for audit/dedupe records.
- `POST /v1/debug/send-test-push` sends a diagnostic APNs push to the latest
  enabled device for the authenticated install. Disabled in production.
- `POST /v1/subscriptions/sync` verifies an App Attest assertion and treats the
  submitted feed list as the install's full notification-subscription
  replacement. Known feeds and per-host admission budgets are resolved with
  chunked `IN`-list reads (≤90 keys per statement, under D1's 100-parameter
  ceiling) and every write the sync produces — pending feed rows, admission
  attempts, subscription upserts, stale-subscription deletes — lands in one
  `db.batch()` transaction, so a 200-feed sync costs a handful of D1
  subrequests rather than several per feed.
- `POST /v1/install/delete` verifies an App Attest assertion and deletes the
  install's App Attest keys, challenges, device rows, feed subscriptions, and
  notification audit rows.

`PUBLIC_NOTIFICATIONS_ENABLED = "false"` is the kill switch for setup/write
paths that would enroll new notification state; it does not block unregister or
install delete cleanup.

Internal surfaces reachable only through a service binding:

- `FeedEvents`, `AdAnalysisEvents`, `RemoteTranscriptionEvents` — producer-scoped
  immutable event ingress (`POST /v1/events`), plus `POST /v1/interests/register`
  and `POST /v1/interests/cancel` for the non-feed producers.
- `FeedObservations` — bounded scan/prepare/drain/outbox/GC operations. It
  receives storage and producer authority without APNs credentials.
- `FeedControl` — `POST /inspect`, `/pause`, `/pause-sends`, `/resume` or
  `/resume-sends` with exactly
  `{ "feed_id": "<opaque digest>", "expected_epoch": 1 }`. Admission and send
  pauses are independent; resume requires expired poll leases and reservations;
  a stale epoch returns 409. For scheduling, repair and aggregate health use
  FeedPollingWorker's `PollingControl` instead.

Subscription sync request payload:

```json
{
  "subscriptions": [
    {
      "feed_url": "https://example.com/feed.xml",
      "notifications_enabled": true
    }
  ]
}
```

Subscription sync response payload:

```json
{
  "message": "synced",
  "registration_ready": true,
  "accepted": [
    {
      "feed_url": "https://example.com/feed.xml",
      "title": "Example Podcast"
    }
  ],
  "rejected": [
    {
      "feed_url": "http://localhost/feed.xml",
      "error": "blocked_host"
    }
  ]
}
```

Other routes return a small JSON error payload.

The register request includes the plaintext challenge as well as the challenge
ID. D1 stores only the challenge hash; the server re-hashes the submitted
challenge before using it for App Attest nonce verification.

## Registration recovery

`registration_ready` in the signed sync response is true only when the current
enabled installation has a matching enabled, nonempty APNs token for this lane
and bundle. It describes the server endpoint at response time, not delivery or
device presentation. Older clients ignore the field; newer clients accept its
absence from older servers but still require their own successful registration
before showing a ready status.

Opted-in clients ask APNs for the current token on launch, on foreground, and
when opening notification settings, and upload it when the token differs from
the last one the server accepted, once per app process even when unchanged,
after a `registration_ready: false` response, and on explicit enable. A false
response therefore makes the client re-upload its unchanged token in the same
pass, which is how an endpoint the server disabled (for example after an APNs
410) recovers without a relaunch.

Migration `0027` preserves the delivery claim (`token_generation`) when the
enabled endpoint is unchanged, so a confirmation does not invalidate it.
`registration_revision` advances on device updates and fences a concurrent
invalidation; `registered_at` still rejects older APNs invalidation timestamps.
Each upload adds one ordinary App Attest assertion using the existing key: it
does not request a new Apple attestation or consume challenge/key enrollment
quota on the healthy path. The device endpoint has no per-upload rate limit; the
five-device cap and the shared App Attest challenge/key limits are unchanged.

## Storage boundary

`n_delivery_history` preserves historical sends and authenticated installation
erasure. Current event/delivery records, accepted-send bridges and snapshot
references are live data, under the usual fixed retention and user-directed
installation deletion. `n_feed_catalog` preserves canonical/source URLs,
metadata and admission timestamps separately from engine authority; `n_feed`
remains scheduling authority, and epoch, eligibility and schedule-generation
fences apply to every commit. `feed_subscriptions`, admission quota ledgers and
device projection triggers serve installed clients and authenticated erasure.

Historical migration files are immutable. Retired runtime tests live in Git
history; the current observation, delivery, control, cancellation and polling
suites replace their executable-path coverage.

## Client notification rendering

Episode pushes use `aps.category = OPENCAST_EPISODE` and the custom `opencast`
payload. The app embeds two extensions that consume it:

- `OpenCastNotificationService` (Notification Service Extension) downloads the
  HTTPS `artwork_url` and attaches it as a local `UNNotificationAttachment`
  before delivery.
- `OpenCastNotificationContent` (Notification Content Extension) renders the
  expanded `OPENCAST_EPISODE` card from the payload and first attachment. Its
  Info.plist sets `UNNotificationExtensionCategory = OPENCAST_EPISODE`,
  `UNNotificationExtensionDefaultContentHidden = YES`, and
  `NSExtensionMainStoryboard = MainInterface`, and the binary links
  `UserNotificationsUI.framework`.

Physical-device proofs require a real device: the simulator reports App Attest
unavailable and does not render remote pushes.

## Feed Resource Policy

The app and both Workers share explicit ceilings for unusually large catalogs.
A scan accepts at most 128 MiB of decoded XML and 100,000 raw RSS items, streams
the response through a bounded parser, and limits XML depth, individual text
fields, per-item text, and cumulative text processing. Two scans may run per
isolate; each invocation also has bounded elapsed-time and decoded-byte
admission budgets. The fetch entrypoint binds the native request abort signal to
ownership of the Rust future, its admission permit, the fetch, and the BYOB
reader, so an abandoned request disposes them together; owner IDs make a late
release harmless to replacement work.

Only a complete successful scan may publish an observation or advance a feed
checkpoint. The scanner retains bounded channel metadata, notification
candidates, and recent publication timestamps instead of materializing the
complete catalog in memory. `scripts/check-feed-resource-policy.py` keeps the
Swift and Rust limits aligned. The queue-side deadlines that apply to polling
invocations are documented in
[`FeedPollingWorker`](../FeedPollingWorker/README.md).

## App Attest Verifier

The Worker uses `x509-parser`, RustCrypto P-256/P-384 ECDSA verification,
`minicbor`, and `sha2`. The MIT-licensed `appattest` crate was evaluated, but
its `aws-lc-sys` dependency does not compile for this Cloudflare Workers wasm
target. The local verifier keeps only the small App Attest-specific CBOR,
authenticator-data, DER extension, certificate-chain, and assertion checks
needed for this slice.

The DER extension walking is adapted from that MIT crate, with attribution in
the source. Production signing and assertion verification still rely on
well-maintained crypto crates rather than custom ECDSA code.

The shared `AppAttestCore` verifier accepts both legacy 37-byte assertion
authenticator data and iOS 27's signed CBOR extensions. Apple encodes the
validation category as a four-byte little-endian value in its
[published attestation fixture](https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide).
Assertion parsing reads the fixed header separately from these extensions;
signature verification still covers every original authenticator-data byte.
Replay counters, request binding, and app identity checks remain mandatory.
`AppAttestCore/tests/assertion_extensions.rs` covers extended assertions,
extension tampering, malformed data, legacy assertions, and replay rejection.

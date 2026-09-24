# OpenCast Feed Polling Worker

Self-hostable Cloudflare Worker that polls podcast RSS feeds for OpenCast
episode notifications. It is a Rust `workers-rs` binary that links
[`NotificationsWorker`](../NotificationsWorker/README.md) as a library with the
notification entrypoints disabled, so this deployment has **no public routes, no
workers.dev hostname and no APNs bindings**. `adapter/index.js` supplies only
the private control, scheduled and Queue capabilities.

NotificationsWorker owns enrollment, subscriptions and APNs delivery; this
Worker owns RSS requests, observations and adaptive scheduling. Queues are
wakeups, D1 is the authority, and both Workers share one D1 database and one R2
bucket per lane.

This public copy is a template. It contains no deployed Worker names, routes,
Cloudflare account resources, database IDs or credentials.

## How it works

- **Dispatch.** A one-minute dispatcher admits at most 400 due polls and 100
  maintenance feeds, rotating across origins, oldest due first. Admission is one
  statement on `n_feed` that reserves the feed and advances its
  `schedule_generation`; only the rows it returns become Queue messages. So
  overlapping dispatchers need no lease, and there is no per-attempt job row.
- **The Queue message is the lease.** It carries the feed ID, owner epoch,
  dispatch generation, due time and step. Every write is fenced on epoch,
  generation and eligibility, so a redelivery may repeat one conditional fetch
  but can never publish or send twice. A failed delivery is redelivered three
  times, sixty seconds apart; the dead-letter consumer then backs the feed off
  from five minutes, doubling to six hours. A five-minute reservation bounds the
  delay after a lost message. The feed row, not the message, is the recovery
  source.
- **Unchanged is cheap.** A matched 304 or a semantically unchanged 200 only
  updates the schedule: three D1 rows and no R2 operation. Rows and snapshots
  are created only once the complete body differs from the published scan's
  digest. A body over the 5 MiB buffer spills to one multipart scratch upload,
  which is aborted unless the feed changed.
- **One request per origin** per isolate, redirects included, and two Queue
  consumers bound the fleet at two per origin. `Retry-After` (capped at 24
  hours) and exponential cooldowns live in `n_poll_origin` and are re-read
  immediately before each request.
- **One scan per isolate.** Queue concurrency is two and batch size is one, and
  each isolate still admits only one complete scan or preparation at a time. Do
  not remove that memory guard based on average feeds.
- **Deadlines.** A queued scan has a 15-second absolute deadline and a
  five-second body inactivity limit; storage work after the body is bounded by
  the 180-second scan lease. Large feeds must fit the time budget as well as the
  [byte and item limits](../NotificationsWorker/README.md#feed-resource-policy).
  Memory admission waits up to three seconds, then redelivers after a jittered
  5–15 seconds.
- **No stuck permits.** Each polling step runs under a 200-second deadline, so
  an await that never returns ends the step instead of holding its scan
  permit. A permit older than 240 seconds is reclaimed on the next acquisition
  and logged as `scan_permit_reclaimed`. A poll that finds the scanner busy is
  counted as `scan_busy`; once the oldest permit is a minute old it retries
  after a flat 60 seconds instead of the jittered delay.
- **Cadence.** Each successful poll re-runs the adaptive policy: a 15-minute hot
  floor, 1-hour, 6-hour and 24-hour age tiers, and a cadence accelerator.
  Revoking user interest takes effect immediately.
- **Cleanup.** A separate wakeup every fifteen minutes takes a D1 lease and
  collects 200 objects per batch, including scratch objects orphaned by a crash.

## Setup

Install dependencies from the repository root:

```sh
yarn install
```

`wrangler.jsonc` in this directory is the public template. Replace every
`REPLACE_WITH_...` value and `your-*` placeholder with your own resources, and
provision each one before deploying: the config only declares them. Each lane
binds:

- the **same D1 database** as the notifications lane (`APP_ATTEST_DB`);
  migrations live in `../NotificationsWorker/migrations`;
- the **same private R2 bucket** (`FEED_SNAPSHOTS`). Keep R2's default rule that
  aborts incomplete multipart uploads after seven days;
- a **poll Queue and dead-letter Queue** (`POLL_QUEUE`) with four-day retention;
- a **service binding** `NOTIFICATION_EVENTS` → your NotificationsWorker's
  `FeedEvents` entrypoint.

Queue names are not placeholders. NotificationsWorker's ingress checks each
message against `opencast-notification-{event,episode,job}-<lane>` and this
Worker's queues pair with them, so keep the names and choose only the lane
suffix.

The compatibility date is `2026-09-10`, the newest the pinned local workerd
supports. Advance it only together with the pinned toolchain.

### Enablement

`dispatcher_admission` and `feed_observation` must be allowed by both the D1
`n_control` row and the environment variable; `cleanup` gates garbage
collection. `five_minute_polling` stays off: it exists only for the
`tests/capacity.mjs` fixture experiment. The template ships every switch
`"false"` and `"crons": []`. See the
[notifications enablement table](../NotificationsWorker/README.md#enablement-is-a-dual-switch)
for the full matrix and the statement that flips a row.

Current binaries need migration `0028` or later. `0028` only adds columns (the
permit counters and the dispatcher's alert state), so on a lane already at
`0027` apply it, then deploy both Workers. Upgrading a lane from `0024`: apply
`0025` alone, deploy **both** Workers, let old invocations and leases drain,
then apply `0026` through `0028`.

### Operator alerts

The dispatcher can page an operator when polling stalls. It is off until all
three secrets are set on the lane:

```sh
yarn wrangler secret put ALERT_WEBHOOK_URL --env <lane>
yarn wrangler secret put ALERT_CREDENTIAL --env <lane>
yarn wrangler secret put ALERT_RECIPIENT --env <lane>
```

A URL that is not `https://` is refused and logged as
`poll_alert_misconfigured`. The dispatcher's per-minute log and `/stats`
report `alerting: true` once the lane is configured. Alerts only run while
the dispatcher itself is enabled.

A stall is at least 50 healthy feeds overdue with no poll completed in five
minutes. With alerting configured, the lane sends a one-time "armed" notice,
then an onset alert when a stall starts, a reminder every hour while it
lasts, and a recovery once five polls complete within five minutes. Stall
state lives in D1 and every transition is fenced there, so overlapping
dispatchers send each alert once and a failed send is retried rather than
lost. Alerts carry counts, seconds and the lane name only, never feed IDs or
URLs.

Each alert is a `POST` to `ALERT_WEBHOOK_URL` with a 10-second timeout:

- headers: `Authorization: Bearer <ALERT_CREDENTIAL>`,
  `Content-Type: application/json`, and an `Idempotency-Key` that is stable for
  that alert (`feed-polling-alerts-armed-<lane>`,
  `feed-polling-stall-<lane>-<since>[-<hour>]`,
  `feed-polling-recovered-<lane>-<since>`);
- body: `{"recipient": "<ALERT_RECIPIENT>", "draft": {...}}`, where `draft`
  has `schema_version: 1`, `title`, `subtitle`, `body`, `sound`, `badge`,
  `interruption_level`, `relevance_score`, `category_id`, `thread_id`,
  `collapse_id`, `expiration`, `priority` and `custom_data`.

An alert counts as delivered on a `200` whose JSON `aggregate_status` is
`accepted`, `partially_accepted`, `recipient_muted`, `recipient_revoked` or
`no_active_target`, or on a `409` with error code `idempotency_conflict`.
Anything else is retried on the next dispatcher tick with the same key, so
the receiver should treat a repeated key as the same alert even when the
counts in the body have changed. To use a different service, put a small
adapter Worker in front of it that speaks this contract.

## Controls

The private `PollingControl` service entrypoint accepts POST:

- `/dispatch`: bounded reconciliation and admission. The scheduled handler calls
  it.
- `/stats`: aggregate health. Overdue and oldest-due ages (healthy and unhealthy
  separately), publisher backoff, dead-lettered feeds, reservations, origin
  cooldowns, outbox and orphan counts, and rolling 24-hour failure, redelivery,
  dead-letter, stale-commit and clamp totals. It also reports the isolate's
  scan permits (active count, oldest age, holder step, reclaims) and the alert
  state: `alerting`, `stall_state` and `stall_since`.
- `/repair` with `{ "feed_id": "<opaque feed digest>" }`: retry an investigated
  dead-lettered feed now, or reset a poisoned burst. It never changes ownership,
  controls or event expiry.
- `/consume` and `/dead-letter`: the Queue adapter's own calls.

Every public HTTP path returns 404, spoofed capability headers included. Bind
operators privately and close temporary operator sessions afterward. Publisher
errors keep their normal retry and backoff; do not confuse them with internal
handling failures.

## Commands

From the repository root, with the pinned Yarn, Node and Rust toolchains:

```sh
cargo test --locked --manifest-path Server/FeedPollingWorker/Cargo.toml
cargo check --locked --manifest-path Server/FeedPollingWorker/Cargo.toml \
  --target wasm32-unknown-unknown --lib
yarn workspace @opencast/notifications-worker deploy:dry-run
yarn workspace @opencast/feed-polling-worker deploy:dry-run

for suite in lifecycle digest-runtime review-regressions alerting \
    permit-reclaim deadline-runtime interest preparation queue evidence \
    no-change recovery runtime cleanup equivalence; do
  node "Server/FeedPollingWorker/tests/$suite.mjs" || break
done
```

The crate is entirely `wasm32`-gated, so host `cargo test` builds an empty
library and the wasm check is the real compile gate. Package **both** Workers
before the runtime suites, and whenever the shared engine changes: the harness
boots both against isolated Miniflare D1, R2 and Queues with mocked APNs. No
test contacts a remote resource.

`capacity.mjs`, `maximum.mjs` and `cost.mjs` are measurement harnesses. They
need local loopback ports, write reports under `/private/tmp`, and should run
one at a time. `maximum.mjs` covers the supported 100,000-item, 128 MiB
envelope; `OPENCAST_OBSERVATION_SCALE=1` runs the notifications observation
suite at the same scale.

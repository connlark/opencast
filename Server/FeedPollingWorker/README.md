# OpenCast Feed Polling Worker

Self-hostable Cloudflare Worker that polls podcast RSS feeds for OpenCast
episode notifications. It is a Rust `workers-rs` binary that links
[`NotificationsWorker`](../NotificationsWorker/README.md) as a library with the
notification entrypoints disabled, so this deployment has **no public routes, no
workers.dev hostname and no APNs bindings**. `adapter/index.js` supplies only
the private control, scheduled and Queue capabilities.

NotificationsWorker still owns enrollment, subscription interests and APNs
delivery; this Worker owns RSS requests, complete observations and adaptive
scheduling. Queues are wakeups, D1 is the authority, and both Workers share one
D1 database and one R2 bucket per lane.

This public copy is a template. It contains no deployed Worker names, live
routes, Cloudflare account resources, database IDs, or credentials.

## Runtime

A one-minute dispatcher admits at most 400 due polls and 100 maintenance feeds.
The initial 80/20 recurring/baseline share borrows unused slots. Selection
rotates across origins within each class, oldest due first within an origin.
Admission is one statement on `n_feed` that reserves the feed (`dispatch_until`)
and advances its `schedule_generation`; only the rows it returns become Queue
messages, so overlapping dispatchers need no lease and **there is no per-attempt
job row**. Missed slots coalesce; the next successful slot uses the feed's stable
phase and independent early jitter, with at most 30 seconds of dispatcher
lookahead.

**The Queue message is the poll-attempt lease.** It carries the feed ID, owner
epoch, dispatch generation, due time and a continuation step. A consumer's claim
is a read; every write is fenced on epoch, generation, eligibility and an
unsettled reservation. A five-minute reservation only bounds the delay after a
lost message: its expiry lets the dispatcher issue a newer generation, which is
what fences the older one. A failed or cancelled delivery is not acknowledged,
so the Queue redelivers it (three retries, sixty seconds apart). An
equal-generation redelivery may repeat one conditional fetch; it can never
publish or send twice. The dead-letter consumer settles an exhausted generation
into a bounded backoff (five minutes doubling to six hours) that does not blame
the publisher; the feed row, not the message, is the recovery source.

Each invocation runs one bounded step, derived from durable observation state:
drain a published observation, resume a complete preparation, deliver a due
outbox, else scan if due. Continuations are chained under the same generation.
Future releases and accepted-observation outboxes are admitted from that state
alone, so neither publisher backoff, an origin cooldown nor a dead-letter
backoff holds them hostage. Poisoned preparations follow the observation
engine's abandonment policy and permit a new scan with retained recovery
evidence.

**A matched 304 or a semantically unchanged 200 is a schedule update, not an
observation.** A scan starts with reads only and buffers in the isolate. It
claims the scan lease and creates rows only after the complete body's exact
identity and fingerprint sets differ from the published scan's digest, which is
bound to that snapshot's never-reused key (so a digest left by a binary that
does not maintain it, or by an expired history, can never match). The unchanged
settle is one fenced batch: three D1 rows per poll with its dispatch, no R2
operation. A feed too large for the 5 MiB buffer spills unproved spool pages to
one multipart scratch upload with no D1 row: aborted when unchanged, failed or
truncated (never an object), copied under the claimed lease and deleted when
changed. A scan that sent a publisher request and failed keeps one inert
first-observed bound per failure streak. The bound is inserted against the
authority and success token that scan read, so a failure landing after a
duplicate or newer generation already settled keeps nothing, and neither does an
origin deferral or a cancellation while waiting for the scan permit.

An isolate admits **one request per origin**, redirect destinations included,
and frees the slot before any storage work; two Queue consumers bound the fleet
at two per origin with no D1 permit. Every redirect hop rechecks the fence.
Retry-After seconds/dates and exponential cooldowns live in `n_poll_origin`,
written only when an origin fails or recovers, and are honored by every consumer
and by admission. The cooldown is read immediately before each request, source
origin included: a copy taken with the message claim would miss one committed
while the scan waited. Native fetch, stream cancellation, complete XML
validation, URL admission, redirect limits, decoded size and inactivity limits
remain in the shared engine.

The starting Queue concurrency is two and batch size is one. **Each isolate
still admits only one complete scan or preparation at a time**, even when
multiple Queue invocations reuse it. Do not remove that memory guard based on
average feeds.

Successful polls re-run the adaptive policy on live inputs: a 15-minute hot
floor, the 1-hour/6-hour/24-hour age tiers and the cadence accelerator.
User-interest revocation is immediate in the shared authoritative tables, and
every commit rechecks its generation.

A separate cleanup wakeup runs every fifteen minutes, uses a D1 lease and chains
200-object batches; it also sweeps a completed scratch object orphaned by a
crash. This keeps collection proportional to changed-response object churn while
bounding each invocation below D1's query limit.

Queued scans have a 15-second absolute deadline and five-second body inactivity
limit; private diagnostic observations keep 120/20 seconds. Storage work after
the body is bounded by the 180-second scan lease instead. Large feeds must
complete within the queued time budget as well as the byte and item limits.
Shared isolate memory admission waits up to three seconds, then uses a
5–15-second jittered delayed message. Retry-After is capped at 24 hours. Queued
feed failures retry after five minutes, then double to a six-hour ceiling;
per-origin cooldown is independent.

## Setup

Install dependencies from the repository root:

```sh
yarn install
```

`wrangler.jsonc` in this directory is the public template. Replace every
`REPLACE_WITH_...` value and every `your-*` placeholder with resources from your
own Cloudflare account. Each lane binds, explicitly:

- the **same D1 database** the notifications lane uses (`APP_ATTEST_DB`);
  migrations live in `../NotificationsWorker/migrations`;
- a **private R2 bucket** (`FEED_SNAPSHOTS`), the same bucket as that lane;
- a **poll Queue and dead-letter Queue** (`POLL_QUEUE`), with four-day
  retention;
- a **service binding** `NOTIFICATION_EVENTS` → your NotificationsWorker's
  `FeedEvents` entrypoint.

Keep R2's default rule that aborts incomplete multipart uploads after seven days
on the snapshot bucket. Resource declarations are declarations only: provision
each one before deploying.

The queue names in the template are **not decoration** — the delivery Worker's
ingress compares each message against
`opencast-notification-{event,episode,job}-<lane>` and this Worker's own queue
pairs with them, so keep the names and choose only the lane suffix.

The compatibility date is September 10, 2026, the newest supported by the pinned
local workerd. Do not advance it without upgrading the pinned toolchain and
re-verifying the flags together.

### Enablement

Both the D1 `n_control` rows and the environment variables must allow
`dispatcher_admission` and `feed_observation`; the D1 controls are part of every
write fence. `cleanup` gates garbage collection. `five_minute_polling` is a
separate, **disabled** switch kept only for a bounded fixture experiment
(`tests/capacity.mjs`) — production cadence is the adaptive policy. The public
template ships every switch `"false"` and `"crons": []`. See the
[notifications enablement table](../NotificationsWorker/README.md#enablement-is-a-dual-switch)
for the full matrix and the statement that flips a control row.

Current binaries require migration `0025` or later and read source URLs from
`n_feed_catalog`; `n_feed` remains scheduling authority. Upgrading an existing
lane from `0024` means: apply `0025` alone, deploy **both** Workers, let the old
invocation and lease window drain, then contract with `0026`.

## Controls and operations

The private `PollingControl` service entrypoint accepts POST:

- `/dispatch` — bounded reconciliation and admission. The scheduled handler
  calls this; there is no public access.
- `/stats` — overdue, healthy overdue and oldest due ages (healthy and unhealthy
  reported separately), publisher backoff, dead-lettered feeds, live and expired
  reservations, origin cooldowns, preparation abandonment, burst poison and
  outbox counts, the oldest served due time in flight, collectible snapshot
  orphans using the collector's exact grace/live predicate, and rolling 24-hour
  publisher-failure, handling-failure, redelivery, dead-letter, stale-commit and
  clamp totals. Only those events write the aggregate; healthy polls leave the
  feed's last outcome and sampled structured events.
- `/consume`, `/dead-letter` — the Queue adapter's own calls, private like the
  rest.
- `/repair` with `{ "feed_id": "<opaque feed digest>" }` — retry an investigated
  dead-lettered feed now, or reset a poisoned burst. It never changes ownership,
  controls or event expiry.

Public `/dispatch`, `/consume`, spoofed capability headers and every other HTTP
path return 404. Bind operators privately and close temporary operator sessions
afterward. Publisher errors retain normal retry and backoff; do not confuse them
with internal handling failures.

## Commands

From the repository root, with the pinned Yarn/Node and Rust toolchains:

```sh
cargo test --locked --manifest-path Server/FeedPollingWorker/Cargo.toml
cargo check --locked --manifest-path Server/FeedPollingWorker/Cargo.toml \
  --target wasm32-unknown-unknown --lib
yarn workspace @opencast/notifications-worker deploy:dry-run
yarn workspace @opencast/feed-polling-worker deploy:dry-run
node Server/FeedPollingWorker/tests/lifecycle.mjs
node Server/FeedPollingWorker/tests/digest-runtime.mjs
node Server/FeedPollingWorker/tests/review-regressions.mjs
node Server/FeedPollingWorker/tests/deadline-runtime.mjs
node Server/FeedPollingWorker/tests/interest.mjs
node Server/FeedPollingWorker/tests/preparation.mjs
node Server/FeedPollingWorker/tests/queue.mjs
node Server/FeedPollingWorker/tests/evidence.mjs
node Server/FeedPollingWorker/tests/no-change.mjs
node Server/FeedPollingWorker/tests/recovery.mjs
node Server/FeedPollingWorker/tests/runtime.mjs
node Server/FeedPollingWorker/tests/cleanup.mjs
node Server/FeedPollingWorker/tests/equivalence.mjs
node Server/FeedPollingWorker/tests/capacity.mjs
node Server/FeedPollingWorker/tests/maximum.mjs
node Server/FeedPollingWorker/tests/cost.mjs
```

The crate is entirely `wasm32`-gated, so `cargo test` on the host builds an
empty library — the wasm target check is the real compile gate. Package both
Workers before the runtime suites: the harness boots the packaged polling Worker
*and* the packaged notifications Worker against isolated Miniflare D1, R2 and
Queues with mocked APNs, so both `build/` directories must exist. No remote
resource is provisioned or contacted by any of these tests.

`digest-runtime.mjs` covers stale-digest and history-expiry behavior.
`equivalence.mjs` compares the current engine against an inert recorded
event-contract oracle. `capacity.mjs`, `maximum.mjs` and `cost.mjs` are
measurement harnesses: they need local loopback ports, write their reports under
`/private/tmp`, and should be run separately from one another rather than in a
batch. `Server/FeedPollingWorker/tests/maximum.mjs` covers the supported
100,000-item / 128 MiB envelope; `OPENCAST_OBSERVATION_SCALE=1` runs the
notifications observation suite at the same scale.

Because the polling crate consumes the shared notifications library, package and
deploy **both** Workers whenever that engine changes.

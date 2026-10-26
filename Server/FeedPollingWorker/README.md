# OpenCast Feed Polling Worker

Self-hostable Cloudflare Worker that polls podcast RSS feeds for OpenCast
episode notifications. It is a Rust `workers-rs` binary that links
[`NotificationsWorker`](../NotificationsWorker/README.md) as a library with the
notification entrypoints disabled, so this deployment has **no public routes, no
workers.dev hostname and no APNs bindings**. `adapter/index.js` supplies only
the private control, scheduled and Queue capabilities.

NotificationsWorker owns enrollment, subscriptions and APNs delivery; this
Worker owns RSS requests, observations and adaptive scheduling. Queues are
wakeups, PostgreSQL is the authority, and both Workers share one PostgreSQL
database (each through its own `DB` Hyperdrive binding) and one R2 bucket per
lane.

This public copy is a template. It contains no deployed Worker names, routes,
Cloudflare account resources, database IDs or credentials.

## How it works

- **Dispatch.** A one-minute dispatcher selects at most 400 due polls and 100
  maintenance feeds, rotating across canonical origins, oldest due first. New
  scans take only the headroom below 200 live reservations in total and 100 per
  origin, so one origin cannot use the other half and a different origin that
  comes due on a later tick still finds room. Repairs and maintenance bypass
  both caps, but their live reservations count toward them. Admission is one
  statement on `n_feed` that counts, orders and reserves the feed
  (`dispatch_until`); only the rows it returns become Queue messages. So
  overlapping dispatchers need no lease, and there is no per-attempt job row. A settled feed advances its
  `schedule_generation`; a lapsed reservation is repaired under the same
  generation.
- **The Queue message wakes a durable feed obligation.** It carries the feed
  ID, owner epoch, dispatch generation, due time and step. Every write is
  fenced on epoch, generation, eligibility and an unsettled reservation, so a
  redelivery may repeat one conditional fetch but can never publish or send
  twice. A failed delivery is redelivered three times, sixty seconds apart; the
  dead-letter consumer then backs the feed off from five minutes, doubling to
  six hours. A five-minute reservation bounds the delay after a lost message:
  its expiry permits a same-generation repair, which leaves queued copies valid
  until the obligation settles. Each tick repairs at most 20 lapsed
  obligations, oldest reservation first, across recurring, baseline and
  maintenance work, before admitting new polls. An uncertain Queue send lapses
  the reservation for repair rather than settling it, and a new generation
  begins only after the previous obligation settles. The feed row, not the
  message, is the recovery source.
- **Unchanged is cheap.** A matched 304 or a semantically unchanged 200 only
  updates the schedule: three database rows and no R2 operation. Rows and snapshots
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
  five-second body inactivity limit. The whole delivery, including its claim,
  storage work and continuation send, has a 200-second deadline, and failure
  bookkeeping gets a further 20 seconds; a timeout still returns failure so the
  Queue redelivers. Failure cleanup releases only the scan lease that
  invocation tried to acquire. Large feeds must fit the time budget as well as the
  [byte and item limits](../NotificationsWorker/README.md#feed-resource-policy).
  Memory admission waits up to three seconds, then redelivers after a jittered
  5–15 seconds.
- **No stuck permits.** Because of the delivery deadline, an await that never
  returns ends the step instead of holding its scan permit. A permit older than 240 seconds is reclaimed on the next acquisition
  and logged as `scan_permit_reclaimed`. A poll that finds the scanner busy is
  counted as `scan_busy`; once the oldest permit is a minute old it retries
  after a flat 60 seconds instead of the jittered delay.
- **Cadence.** Each successful poll re-runs the adaptive policy: a 15-minute hot
  floor, 1-hour, 6-hour and 24-hour age tiers, and a cadence accelerator.
  Revoking user interest takes effect immediately.
- **Cleanup.** A separate `*/2 * * * *` cron runs cleanup under a 180-second storage
  lease. Each run selects at most 200 objects, including scratch objects
  orphaned by a crash, and starts no new object after 25 seconds. Database
  retention still runs when that budget runs out, so object churn cannot starve
  history or statistic expiry; an unfinished run leaves the cleanup generation
  for the next cron. Cleanup Queue messages from older versions are
  acknowledged without work.

## Setup

Install dependencies from the repository root:

```sh
yarn install
```

`wrangler.jsonc` in this directory is the public template. Replace every
`REPLACE_WITH_...` value and `your-*` placeholder with your own resources, and
provision each one before deploying: the config only declares them. Each lane
binds:

- the **same PostgreSQL database** as the notifications lane, through its own
  Hyperdrive binding `DB` (`STORAGE_AUTHORITY = "postgres"` and, optionally,
  the `STORAGE_IDENTITY` pin); the schema lives in
  `../NotificationsWorker/postgres`;
- the **same private R2 bucket** (`FEED_SNAPSHOTS`). Keep R2's default rule that
  aborts incomplete multipart uploads after seven days;
- a **poll Queue and dead-letter Queue** (`POLL_QUEUE`) with four-day retention;
- a **service binding** `NOTIFICATION_EVENTS` → your NotificationsWorker's
  `FeedEvents` entrypoint.

Queue names are not placeholders. NotificationsWorker's ingress checks each
message against `opencast-notification-{event,episode,job}-<lane>` and this
Worker's queues pair with them, so keep the names and choose only the lane
suffix.

The compatibility date is `2026-09-18`, matching the pinned local workerd.
Advance it only together with the pinned toolchain.

### Enablement

`dispatcher_admission` and `feed_observation` must be allowed by both the
`n_control` row and the environment variable; `cleanup` gates garbage
collection. The template ships every switch
`"false"` and `"crons": []`; a running lane needs both `"* * * * *"`
(dispatch) and `"*/2 * * * *"` (cleanup). A changed cron list takes effect
only after `yarn wrangler triggers deploy` for that environment, so check both
expressions on the live version. See the
[notifications enablement table](../NotificationsWorker/README.md#enablement-is-a-dual-switch)
for the full matrix and the statement that flips a row.

The schema and its install order live with NotificationsWorker (see its
[storage setup](../NotificationsWorker/README.md#storage-setup)); after a
schema change, deploy **both** Workers.

### Operator alerts

The dispatcher can page an operator when polling falls behind. It is off until all
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

The dispatcher alerts when at least ten healthy, previously scanned feeds are
more than ten minutes late, or when at least 50 healthy feeds are overdue with
no poll completed in five minutes. Feeds with publisher or handling failures,
pending retries or origin cooldowns are not healthy, and late first scans
(baselines) are counted separately rather than toward the ten. With alerting
configured, the lane sends a one-time "armed" notice, then an onset alert, a
reminder every hour while it lasts, and a recovery once no healthy scanned
feed is over ten minutes late and five polls complete within five minutes.
The per-minute rollup and `/stats` share these health predicates and report
`late_600` and `late_baselines`; the rollup also counts `repairs`,
`outstanding` and `admission_deferred` (eligible due scans left unreserved by
the caps), and an obsolete delivery emits `poll_outcome` without a storage write.
Stall state lives in the database and every transition is fenced there, so overlapping
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

- `/dispatch`: bounded reconciliation and admission. The one-minute cron calls
  it.
- `/cleanup`: bounded scheduled collection, gated by the cleanup controls. The
  two-minute cron calls it.
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

`poll_delivery` logs every delivery that is not a plain success, every first
delivery that waited more than 120 seconds in the Queue, and every delivery
longer than five seconds; other unchanged successes are sampled at 1 in 64.
It carries `due_lag_seconds`, `message_age_ms` (from the Queue send time, so
it includes planned delays and retry backoff), `initial_queue_wait_ms` (first
attempts of undelayed wakeups only), `claim_ms`, `publisher_fetch_ms` and
`storage_ms`, with opaque feed and origin keys only.

Every public HTTP path returns 404, spoofed capability headers included. Bind
operators privately and close temporary operator sessions afterward. Publisher
errors keep their normal retry and backoff; do not confuse them with internal
handling failures.

### The storage timing witness

Every polling invocation writes one `storage_phases` line (schema 2): dispatch,
cleanup and dead-letter always; a consume under `poll_delivery`'s gate, on
`failed` or `cancelled`, and for every consume of a feed whose opaque id's first
hex nibble is below 4 (the provenance cohort). A consume is attributed only to a
valid message: every exit of one writes its line, the environment brake's
`polling_disabled` 503 included (its chain, outcome `refused` and no
operation; the parser does not classify it as a storage failure), while a
permanently invalid payload (an `invalid_wakeup` 400, an undecodable wakeup) or
a legacy cleanup message writes none, having no valid chain or feed to name.
It records, per invocation, every storage operation the Worker ran: an identity
read as its own `identity` operation, each Unknown readback as a `readback` of
the operation that started it, and the AbandonPoisoned executor as
`interactive`. Each operation has its races (connect, read, the pipelined
transaction with its steps and the gate's reply time, rollback, close). Each
race carries the bound that limited it at its start (`limit`, `budget_ms`) and
how it ended (`completed`, `timeout`, `cancelled`, `driver`, `database` or
`dropped`). The line also carries:
- the first failing race as `primary`, with the pre-primary validity snapshot
  `prior` and up to four later `failures`;
- `durations` of storage (the union of every storage interval, overlap counted
  once), R2 (with its body reads), the FeedEvents POST, the alert exchange, the
  publisher fetch, the queue sends, and `idle`, the wall less their union;
- each consume's actions with coarse checkpoints (a drain's page offset, a
  preparation's phase), its chain (the feed id, the polling generation, step,
  attempts and a 16-hex digest of the Queue's message id), its continuation
  send and its FeedEvents POST counts;
- `scheduled_lag_ms`, from the cron's scheduled time, which the adapter passes
  to `/dispatch` and `/cleanup` in the private `x-poll-scheduled-ms` header (a
  diagnostic that bounds nothing; the public fetch stays 404).

Strings are restricted to `[A-Za-z0-9_.-]` and every integer is bounded, so a
line is never over 8,192 bytes. Past that ceiling the detail is trimmed in a
fixed order: operation races, then operation entries, then actions, then
`slowest`, then failures beyond two; then the compact form, at most 6,349
bytes by `storage_phases/compact_width.py`'s model. An implementation defect
writes `storage_phases_overflow` instead, never a larger line.

`storage_phases/storage_phases_parse.py` reads the lines: it tags each failed
row with every evidence class it matches (C0 cron lag, C1 connection setup, C2
cumulative budget exhaustion, C3/C3' a slow write or a lost acknowledgement, C4
R2, C5 gate contention, C6 idle, C7 overshoot, U unresolved). Each tag uses
exactly the inputs that class names, and a missing input reads `unknown`. It
also classifies send provenance (retry, ambiguous, unknown, exact) and gives
the retry wait only between two retained consecutive attempts. Exact page
repetition, prepare redo, skipped rows and the outcome of an `unknown`
checkpoint are never inferred. A storage-fixture build also logs
`storage_phases_cost` (each line's bytes and build time) for the runtime
maxima control.

## Commands

From the repository root, with the pinned Yarn, Node and Rust toolchains:

```sh
cargo test --locked --manifest-path Server/FeedPollingWorker/Cargo.toml
cargo check --locked --manifest-path Server/FeedPollingWorker/Cargo.toml \
  --target wasm32-unknown-unknown --lib
yarn workspace @opencast/notifications-worker deploy:dry-run
yarn workspace @opencast/feed-polling-worker deploy:dry-run
bash Server/NotificationsWorker/postgres/local/local-postgres.sh up

for suite in lifecycle digest-runtime review-regressions alerting \
    stage1-review permit-reclaim deadline-runtime interest preparation queue \
    evidence no-change recovery runtime cleanup equivalence livelock; do
  node "Server/FeedPollingWorker/tests/$suite.mjs" || break
done
(cd Server/FeedPollingWorker && worker-build --release --out-dir /tmp/opencast-polling-fixture-build --features storage-fixture)
node Server/FeedPollingWorker/tests/hooks-runtime.mjs
OPENCAST_POLLING_FIXTURE_BUILD=/tmp/opencast-polling-fixture-build STORAGE_PHASES_ROWS_OUT=/tmp/opencast-storage-phases-rows.jsonl node Server/FeedPollingWorker/tests/witness-runtime.mjs
STORAGE_PHASES_ROWS=/tmp/opencast-storage-phases-rows.jsonl python3 -B -m unittest discover -s Server/FeedPollingWorker/storage_phases
```

The crate is entirely `wasm32`-gated, so host `cargo test` builds an empty
library and the wasm check is the real compile gate. Package **both** Workers
before the runtime suites, and whenever the shared engine changes: the harness
boots both against a PostgreSQL clone of the local test topology's template
(see the [notifications commands](../NotificationsWorker/README.md#commands)),
isolated Miniflare R2 and Queues and mocked APNs. `OPENCAST_TEST_STORAGE` may
be unset or `postgres`. No test contacts a remote resource.

`capacity.mjs`, `deadline-load.mjs` and `maximum.mjs` are measurement harnesses. They
need local loopback ports, write reports under `/private/tmp`, and should run
one at a time. The default 2,000-feed capacity case uses the fastest
production cadence (15 minutes); overload and the admission caps are covered
by `livelock.mjs`; `deadline-load.mjs` audits native cancellation of hanging
streams under load in one isolate. `maximum.mjs` covers the supported 100,000-item, 128 MiB
envelope; `OPENCAST_OBSERVATION_SCALE=1` runs the notifications observation
suite at the same scale.

The test entry's fixture hooks (`tests/entry.mjs`, `fixtureHooks`) control
timing a test cannot reach on the wire: the retry delay its real-queue path
forwards (`/test/retry-delay`), key-scoped R2 delays and body holds
(`slow_get:<ms>:<prefix>`, `hang_get:<prefix>`), a held FeedEvents reply body
(`hold_service_body:<ms>`), a reply body held inside the isolate for the
alert-webhook stub (`tests/webhook-stub.mjs`, with its idempotency ledger)
and a synchronous isolate stall (`/test/stall`, scheduled from a wire-proxy
fire by `controls.stall`). The polling Worker's `storage-fixture` feature
(never in a shipped manifest) adds the polling loop's fixture clock and gate
and the core's close delay behind private fixture routes;
`harness(..., { pollingBuild })` runs that build. `hooks-runtime.mjs`
qualifies every hook (`OPENCAST_POLLING_FIXTURE_BUILD` names the fixture
build, default `/tmp/opencast-polling-fixture-build`). `witness-runtime.mjs`
reads each invocation's `storage_phases` line against the wire proxy's own
witness of the same operations: the guards, the intervals, the zero-budget and
Date-jump controls, send provenance through the parser, and the runtime maxima.
It has no default build: `OPENCAST_POLLING_FIXTURE_BUILD` must name the
fixture build (its close-delay and maxima cases fail without it), and
`WITNESS_CASES=<names>` runs a subset. `STORAGE_PHASES_ROWS_OUT=<file>` saves
every line it read; the parser's unittest discovery with
`STORAGE_PHASES_ROWS=<file>` then also parses each of them (the round trip;
without it that one test is skipped).

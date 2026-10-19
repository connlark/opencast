# Semantic storage

`polling::Operation` is the closed slice A request set. Callers pass identities,
fences, values and timestamps. The private `postgres` module owns their SQL. Observation requests carry the published generation/token, checkpoint
fence and preallocated reservation IDs; they never hold a mutable client.

A storage call's only returned success is a completed response with validated
counts/rows. PostgreSQL opens an invocation-owned storage segment, uses typed unnamed
statements and closes before returning to publisher, Queue or other I/O. Every
mutation locks the dispatch singleton before evaluating application predicates
in a fresh statement snapshot. Reads do not acquire it. Runtime maintenance
writers must obey the same gate order. The caller supplies the enclosing
operation's absolute deadline; the segment's connect, statement and transaction
budgets are capped by it and an expired deadline submits nothing.

Errors retain `NotCommitted`, `Unknown` or read-only `NotApplicable` separately
from valid zero-row results. SQL/count/decoding diagnostics contain no SQL or
bindings. No executor retries. An Unknown request keeps its original identity:

- Admission, enqueue lapse and continuation leave the durable generation for
  existing dispatcher repair; no messages are synthesized from an uncertain
  reservation response.
- Origin/failure/dead-letter counters and aggregate stats are never blindly
  replayed. A Queue redelivery is a distinct existing attempt.
- An unchanged settle has its preallocated success token; a superseding token
  cannot prove noncommit. Its error leaves recovery to the existing generation.
- A failed scan has both reservation IDs and its lease. The existing recovery
  evidence can be read without inserting another presumed-rolled-back copy.
- Release and alert markers retain their exact ownership/CAS predicates.

The invocation constructs one immutable `Authority` from `STORAGE_AUTHORITY`.
The pure selector and its host tests live in the normally declared
`crate::database_selection` module outside the wasm-only database tree.
`postgres` selects PostgreSQL through the `DB` binding; it is the only storage
backend. An absent value (`storage_authority_missing`) or any other value,
`d1` and a non-string binding included (`invalid_storage_authority`), fails at
the first storage call. There is no fallback and no default; every shipped
environment sets `postgres`. `storage-fixture` supplies an isolated
local-only entrypoint and is incompatible with `notification-entrypoint`.
The fixture selects one authority through its immutable binding; it has no
arbitrary SQL endpoint and rejects unported requests. No shipped manifest
enables this entrypoint.

The fixture's lost-result switch injects at the post-completion boundary. Actual transport/COMMIT faults require the separate adapter
wire fixtures. A pure read has a read error, never a mutation commit outcome.
Counter operations without a source fence/no-op retain their unconditional
increment; tests must not invent a new fence or idempotency policy for them.

The observation interface covers scan reservations, preparation, publication,
object metadata and references, with its own PostgreSQL SQL. First-row calls
return zero or one row under the same count and reply contract as the original
calls. Page JSON bindings retain the complete original metadata and object-key
order. R2 work remains outside database operations. Catalog source lookup uses the
polling interface. Local fixtures cover full rowsets, results, counts and
concurrent serialization.

Cleanup lease claim, statistics pruning and lease release each retain their own
single-call boundary, with object-store work between those calls. An uncertain
claim reads the singleton's cleanup lease, deadline and generation; only the
original lease proves ownership for work still within that lease. Pruning reads
only buckets older than the original cutoff, and does not replay a delete when
its acknowledgement is lost. Release reads the singleton and never assumes
that an absent or superseding lease proves that its own call committed. A failed
cleanup retains the generation; only a successful completion may advance it.

Operator repair retains two independent mutations. Feed repair reads the feed's
failure count, retry time and error marker. Burst repair reads the feed's burst
rows, including their failure counts, retry times, completion flags and leases.
An uncertain repair reads those durable witnesses without replaying either
write; concurrent later work can make the original commit indeterminate. A
failure of burst repair never rolls back a completed feed repair. Repair of a
poisoned incomplete burst intentionally clears even a live lease, matching the
existing operator action. The runtime authority performs those operation-specific readbacks before
returning the original uncertainty to the operator caller.

The observation completion and preparation-wait queries remain read-only first
calls. All invocation
control checks share the existing polling control operation and its exact
first-row query, including the environment switch's short-circuit behavior.


## Storage identity

A version opts into the bind-time identity gate by setting `STORAGE_IDENTITY`
to `v1;<environment>;postgres;pg:<datname>[:<system identifier>]` (without
the identifier when the role cannot read it). Absent, the Worker behaves
exactly as before: no identity statement, no log line. The schema identity is
compiled in from the shipped migrations: the digest of the catalog text
(columns and types, primary keys, trigger names and states of the 32
application tables) a fresh install produces; a host test pins the migration
files' digest beside it. Any other pin, a `d1` one included, is malformed and
refuses with reason `pin` before any read.

The first storage call of an isolate checks, in order: the pin's shape, the
pin's environment against `NOTIFICATION_ENVIRONMENT`, then one read-only
statement (database name, system identifier and catalog digest on its own
storage segment under the invocation's deadline and cancellation, without the
mutation gate), then the schema and the database. The verdict is cached for
the isolate: after an acceptance the steady path adds no round trip, and an
ordinary storage error keeps it; after a refusal every storage call, reads
included, fails before submitting anything with
`storage_<operation>_Identity_NotCommitted` (mutations) or
`storage_<operation>_Identity_NotApplicable` (reads). An unreadable identity is
not cached and fails the call with the read's own kind and the pre-submission
outcome. Each verdict logs one `storage_identity` line with the backend,
environment, live and expected identities and no secret; its `fence` key is
always `null`. The App Attest seam passes the gate before its key read and
counter CAS. `PollingControl` and `FeedControl` answer `POST /identity` with
the same report, read-only.

`delivery::wire::parse` is the request boundary that rejects integers beyond ±(2^53−1) before typed decoding or storage access.

## Invocation ownership

All polling, observation, identity, ingress, delivery and retention operations
receive the invocation's `Authority`. Clones share its immutable selection; they
never share a PostgreSQL connection. The notification
scheduled handler shares one value across watchdog and maintenance. The
existing adapters invoke Rust once per queue message, in their original serial
loop; each message retains its original invocation and acknowledgement boundary.
Narrow service adapters pass through the same selection variable and existing
binding. They do not introduce an additional authority or create a binding.

Fetch invocations carry their request abort signal; scheduled work carries a
never-cancelling future. The storage deadline covers the invocation's original
post-budget and post-external-call writes, not just its work phase. Every future
authority site must reserve that bookkeeping window when the original caller
writes after a phase ends. Nested contexts share selection and cannot extend
their parent's absolute cap; bookkeeping uses independent cancellation.

Polling consumption retains its 200-second step plus 20-second bookkeeping cap.
Cleanup reserves 25 seconds for object work plus that same 20-second allowance;
after scratch, GC (including its final three retirements) and lease release use
bookkeeping capped at the object budget's expiry plus 20 seconds and the original
45-second outer deadline. The object loop still starts no new object after its
budget and a budget stop never advances the cleanup cursor.

Queued notifications have an arrival + 15 seconds + `HANDLER_MS` outer cap so
APNs' existing 15-second bound leaves room for finish/failure writes. This keeps
one absolute 27-second invocation cap without resetting it after a reply; each
PostgreSQL connection still has the core's `HANDLER_MS` storage-segment cap.
Dispatch has a `HANDLER_MS` work phase, its existing 10-second alert bound and
20 seconds of bookkeeping (42 seconds total). Markers after an alert and the
final state read use bookkeeping capped at reply time + 20 seconds and that
outer deadline; pre-alert work retains the shorter work cap. These limits also
apply to the polling scheduled helper. Other notification scheduled work keeps
its shared `HANDLER_MS` cap; the watchdog read remains capped at its own 10
seconds within that shared deadline, and on PostgreSQL the per-statement
budget (`STATEMENT_MS`, 4 seconds) bounds that read first, so its effective
bound is the smaller of the two. Publisher scan and transport timers still
bound their own futures.

## Runtime uncertainty settlement

Every PostgreSQL D/E/F mutation passes through its family's runtime executor.
On `Unknown`, it opens the operation's closed readback(s), using the same
cancellation and absolute deadline, before returning the original failure.
Readback errors, expired budgets and cancellation never create a new budget or
change Unknown to NotCommitted. Dropping an aborted invocation closes the
current transport; an invocation that cannot finish observing defers to the
existing durable recovery path. No readback replays a write. A matching witness
can show current state, but cannot reconstruct the original affected counts or
rule out subsequent work, so the runtime conservatively retains Unknown.
Logs contain only operation/readback names, completion, deferred settlement
and, for an observed readback, a witness digest and row count: the decoded rows
in the cutover tool's canonical tokens (a nested JSON value, such as a
retention readback's parsed row, as `"j:"` and the hex of its compact,
sorted-key JSON), each line prefixed with its reply index and ordered by
column name, row digests aggregated in ascending order. No row value is
logged.

**Ingress and feed control (F).** Admission reads the original event identity;
registration and cancellation read the original interest; suppression reads
remaining live deliveries; feed changes inspect the original feed. The caller
returns its existing storage error and issues no queue send or successful
receipt from the uncertain response. A later original-identity delivery uses
the existing durable reads and conflict checks. Cancellation does not invent a
zero or one affected count, and an uncertain resume does not enqueue deliveries.
The watchdog only reads and needs no mutation settlement.

**Drain, fanout and delivery (D).** Claims read the original lease/fence rows;
fanout, grouping and completion read their event, cursor, burst and delivery
witnesses; send outcomes read the original delivery and endpoint/circuit/install
state; drain and outbox writes read their original observation/release/outbox.
Unknown propagates through the caller's existing error path, preserving its
durable identity for queue redelivery or reconciliation. In particular, a lost
claim acknowledgement cannot authorize APNs, and an uncertain APNs outcome
cannot cause an immediate resend. Already-completed external work is not undone.
Operator repair retains the independent boundaries described above.

**Recovery, retention and object GC (E).** Each operation reads only its
specified rows/predicates. The caller stops its existing loop or returns its
existing error; the next scheduled invocation resumes from durable state.
An uncertain GC claim never authorizes R2 deletion, and a lost database mark
does not replay the mark in the same invocation. Cleanup does not advance its
generation after an uncertain claim, prune or release. Best-effort handling
at higher levels remains intact. The separate identity retention operations
retain their original best-effort handling and next-invocation recovery.

## Local integration runners

Run these serially under `/usr/bin/lockf /private/tmp/opencast-heavy-gate.lock`,
with a fresh protected `OPENCAST_SLICE_EVIDENCE` directory beneath the absolute
`OPENCAST_SLICE_EVIDENCE_ROOT`. All commands run from the repository root except
`worker-build`, which runs from `Server/NotificationsWorker`. Build output paths
must be separate from the default `build/` directory.

- `integration-podman.py collation` resumes the owned local PostgreSQL fixture
  after `schema`, using `OPENCAST_PG_DRAIN_PROOF` from that schema packet and
  `OPENCAST_SLICE_BUILD` pointing to the PostgreSQL storage-fixture build. It
  runs four collation pairs and both negative controls.
- `integration-lanes.py authority-wire` requires
  `OPENCAST_INTEGRATION_FIXTURE_BUILD`: the output of `worker-build --release
  --out-dir <fixture-build> --offline --locked --no-default-features --features
  storage-fixture`. It runs the unchanged authority-wire suite and its
  sibling `integration-authority-deadlines.mjs` for cleanup, delayed APNs finish
  and post-alert bookkeeping. The typed peer is local and needs no PostgreSQL VM.
- `integration-lanes.py integer-boundaries` requires
  `OPENCAST_INTEGRATION_POSTGRES_BUILD`: the output of `worker-build --release
  --out-dir <production-build> --offline --locked` with the
  default production entrypoint. It runs the unchanged request-boundary and
  invalid-selection/health harness.

The local Python runners coordinate fixture and production-entrypoint checks.
No lane sets a production binding or deploys a Worker. The default runtime and
package lanes keep their existing build and suite-pin requirements.

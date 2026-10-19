# Isolated PostgreSQL application schema

These owner-applied files create the application schema in `opencast` and grant
a separately selected runtime role only the operations the Workers need. Both
Workers have run on this schema in production, through their `DB` Hyperdrive
binding, since 2026-10-16.

After owner-only role creation, apply in this order:

1. `migrations/0001_slice_a.sql` once in an empty database.
2. `runtime-grants.sql` with psql `-v runtime_role=<role>` for each runtime role.
3. `migrations/0002_slice_b.sql` for the B authority; all B objects are inherited
   from 0001, and this migration verifies its relation prerequisites.
4. `runtime-grants-slice-b.sql` with `-v runtime_role=opencast_slice_b`, for the
   B role only. Do not add B grants to the unchanged A comparison role.
5. `migrations/0003_delivery_member.sql` installs `n_event`, `n_delivery_member`
   and `n_group_member`, with their frozen 0030 keys, FKs and indexes. No grants.
   Slices C, D and E add their own runtime authority.
6. `migrations/0004_identity_delivery_support.sql` completes the frozen application
   schema with `app_attest_challenge_source_buckets`, `app_attest_challenges`,
   `app_attest_keys`, `feed_admission_attempts`, `n_circuit`, `n_deleted_install`,
   `n_requester_ticket`, `push_send_attempts` and `secure_hello_attempts`.
   It adds only their frozen columns, defaults, keys and explicit indexes;
   there are no new CHECKs, foreign keys, triggers or grants. It preserves
   the sole D1 seed: `n_circuit(lane,updated_at) VALUES('apns',0)`, with
   `paused=0` and `reason=NULL` from the frozen defaults.
   Each later runtime family supplies its own grants.
7. `runtime-grants-slice-f.sql` with psql `-v runtime_role=<ingress role>`,
   for the selected ingress/control runtime role only. Do not add these grants
   to the unchanged A or B comparison role.

The local comparison roles are `opencast_slice_a` and `opencast_slice_b`.
Give them the fixture search path
default `opencast, pg_catalog`; application sessions do not issue SET.
The schema owner creates
roles and assigns connection/time limits separately. Never use the owner role
in the Worker. Runtime cannot create schema objects, truncate tables, mutate
controls/identity, delete the mutation gate, or reset application state.

The numbered order above keeps the local comparison roles apart. A production
install has one runtime role and applies, in this order, every file to that
role with `-v runtime_role=<runtime role>`: `migrations/0001_slice_a.sql`,
`runtime-grants.sql`, `migrations/0002_slice_b.sql`,
`runtime-grants-slice-b.sql`, `migrations/0003_delivery_member.sql`,
`migrations/0004_identity_delivery_support.sql`,
`runtime-grants-slice-c.sql`, `runtime-grants-slice-d.sql`,
`runtime-grants-slice-e.sql`, `runtime-grants-slice-f.sql`, then
`runtime-grants-integration.sql` (owner-applied additions to the runtime grant
union: the cleanup lease, until and generation columns on the dispatch
singleton and the retention deletes; no schema change). Finally,
`reader-grants.sql` with `-v reader_role=<read-only role>` gives the separate
read-only role schema usage and SELECT on every application table, which the
cutover tool's `manifest-target` requires. Objects are created
as the owner; any default privileges the host grants to the runtime role are
re-established only after this sequence, so the installed tables carry
exactly these grants.
Optionally, `reader-stats-grant.sql` (same `-v reader_role=`, but run by the
`postgres` superuser over the local maintenance connection, since the owner cannot
grant predefined-role membership) grants that role `pg_read_all_stats WITH INHERIT
TRUE` for the dashboard's session-state view; no table or write access.

Local topology: `local/local-postgres.sh up` runs one PostgreSQL 18.6 container
on 127.0.0.1:55432 (Podman first; Docker Desktop through
`OPENCAST_CONTAINER_RUNTIME=docker`, a path not yet verified on a Docker daemon)
from the 18.6 multi-platform index, and installs these same files, in the production order above with one runtime role, into the template
`opencast_template`. The template accepts no connections and its marker records
the files' hash and the image the runtime runs (`image_requested`, `image_resolved`,
`platform`; `provenance` prints them read-only and `status` refuses an unresolved
one), so a changed file refuses until `reset`; the superuser also
applies `reader-stats-grant.sql`, outside that hash. The Notifications and FeedPolling Miniflare suites clone the
template per Miniflare instance through `NotificationsWorker/tests/storage.mjs`,
both Workers' `wrangler dev` uses its `opencast_dev` clone (the development
Hyperdrive id is a placeholder), and CI runs `install` against a PostgreSQL
service with the host psql at `OPENCAST_PG_HOST`:`OPENCAST_PG_PORT` (inherited
`PG*` settings are overridden, each with a notice). `down` keeps the volume, `reset` rebuilds from
empty, `status` compares the marker with these files and `prune` drops a killed
run's clones; `local/test-local-postgres.mjs` checks the install and its posture.
That self-test needs exclusive use of the topology: while it runs it changes
shared state that clones do not isolate (the local roles' settings, the install
marker's provenance columns and its recorded image, each restored before it
ends), so never run it beside another run of it, `install`, `reset`, `prune` or
anything relying on the local roles or the marker. Suites that only clone the
template need no such serialization.
The suites' wire proxy (`tests/postgres/proxy.mjs`) carries the storage hooks;
its timing controls (`tests/postgres/timing.mjs`: statement-matched armings,
held COMMIT or unit replies, operation-wide releases, handshake holds, the
interactive hold, scheduled isolate stalls) are qualified by
`tests/postgres/test-timing.mjs`, with the storage-fixture build's close delay
and core cancellation (`/test/close-delay`, `/test/cancel-core`).
The local roles' passwords are fixed constants, not secrets.

The schema preserves the final D1 table/column/key/check/index definitions for
32 application tables and 13 projection triggers. Integer values are BIGINT, binary values are BYTEA, flags retain
integer CHECKs, JSON stays exact text with `IS JSON` only where the frozen
schema requires validity, and nullable lease-pair checks remain. Primary keys
are non-null logical identities in PostgreSQL; callers already supply them. No sequences or new interest/feed FK.
The 44 explicit indexes preserve access-path intent, including partial uniqueness.

Every runtime write must lock the singleton `n_poll_dispatch` row first, before
application rows; dependent statements follow with a fresh statement snapshot.
Direct maintenance follows the same order, or runs only after all writers and
in-flight transactions are stopped. The gate is seeded before runtime access.
Only database work belongs inside that transaction; Queue and HTTP calls remain
outside. Missing gate is an error, never an unlocked write.

The closure follows outgoing FKs and trigger dependencies. Migration 0003
closes the former inbound `n_delivery_member.delivery_id` →
`n_delivery.delivery_id` omission before C (B20), D (B04) and E (B05/B06/B11).
Its event FK requires `n_event`; `n_group_member` closes that parent's inbound
FK. Only these three tables are added by 0003. All three new FKs retain D1's `NO ACTION`,
and the new tables have no triggers. The frozen B ledger records these
additions; the recomputed installed union has zero inbound omissions.

Migration 0004 is shared by the remaining runtime families. They inherit the
complete application schema and add only their own runtime grants; no further
per-family migration is needed. D1 engine bookkeeping (`_cf_KV`, `d1_migrations`
and `sqlite_sequence`) is excluded. PostgreSQL primary/unique constraints own
their indexes; SQLite autoindex names are not application objects.

Slice B adds the first runtime DELETE, on `n_snapshot`, for `release_unused`.
Its full semantic predicate is the caller's still-owned key set plus
`state='reserved' AND sha256='' AND lease_id=<own lease>`. The table-wide grant
does not enforce that row bound. The two NO ACTION `n_snapshot_ref` FKs protect
both referenced manifest and page keys, and runtime has no reference UPDATE or
DELETE with which to undo them. The observation snapshot FK is also installed,
but observation UPDATE can repoint it, so it does not replace the predicate.
Uploaded, digest-bearing and other-lease keys must survive `release_unused`.
No reference-deletion or GC operation is authorized by these grants; semantic
SQL must preserve the source transitions despite the state column's broad CHECK.

The B semantic implementation is present behind the optional backend. Fresh
local differential, race, adapter and wire checks pass after the D1 page-binding
correction. Exact baseline D1 traces also pass, including SQL-bearing invocation
boundaries and retry scenarios; no-SQL requests are counted separately. The
D1 runtime matrix, locked Rust tests, host/wasm Clippy feature lanes, local
pilot fixtures and both Workers' package dry runs pass. Fixture-clock fixes
are isolated from the port and preserve every assertion and golden. This
completes local qualification for review, with no production delivery policy
change or deployment. That B qualification predates additive 0003 and 0004; A/B schema
definitions and role grants remain unchanged.

# Recovery reconciliation

A restore from backup rolls the notifications and polling authority back to
its recovery point. Consumed App Attest challenges and counters come back,
and so do deleted installations, opt-outs, and deliveries that were already
sent. Counter checks cannot tell those replays apart. A restored copy must
not serve until it has been reconciled.

`recovery.py` enforces the conservative recovery policy:

- every client re-attests, registers its device and confirms its
  subscriptions again;
- no restored personal state survives;
- no pre-recovery send replays;
- new work starts at a fresh eligibility boundary.

It also fences the old primary.

It writes only inside the transactions described below and never contacts
Cloudflare. Every command leaves a receipt in a directory the operator names.
The host runbook (`Server/Infrastructure/oracle-postgres/private/README.md`,
"Recovery: fence, restore, reconcile, resume") gives the full incident
sequence.

Requirements: the cutover tool's, namely Python 3.9 or later (standard library
only), psql 16 or later, and PostgreSQL 16 or later with server encoding UTF8.
The target must be installed from the parent directory's schema files in the
single-runtime-role order.

**Not yet proved for production.**

- **Tested locally only.** The tool has been tested on a local PostgreSQL
  primary and on a copy restored from its base backup and archived WAL.
- **Still outstanding before production use:**
  - a rehearsal on a copy restored from the real backup repository;
  - `fence` and `unfence` on a live database.
- **No shipped point-in-time restore that keeps its copy.**
  `Server/Infrastructure/oracle-postgres/private/restore-backup-fixture.py` is
  a drill: it recovers to the end of the archive and deletes its copy, so
  there is no shipped persistent point-in-time restore for this tool to run
  on yet.

## Why a marker, not the identity

A physical restore copies the cluster's control file, so the copy has the old
primary's system identifier. Point-in-time recovery and promotion change the
timeline, not the identifier. The Workers' identity pin and the cluster guard
therefore read the same values on the copy and on the old primary, and cannot
tell them apart. Two things can:

- **The marker.** It names the restored copy: a one-row table in schema
  `opencast_recovery`, written by the operator who restored the copy, after
  promote and before any restart.
- **The fence.** It protects against a second writer: the old primary's
  runtime role loses every write privilege. After the fence, stop and mask
  the old primary's unit.

## The sequence

`T` = `python3 Server/NotificationsWorker/postgres/recovery/recovery.py`. Keep
receipts in a 0700 directory `R`. The tool refuses anything group- or
world-accessible and never overwrites a receipt, so a rerun needs a fresh
directory. Every database command takes these flags:

- `--psql '<JSON argv prefix>'`: the tool appends its flags and streams SQL on
  stdin; arguments carrying a password are refused;
- `--target-database`;
- `--target-system-identifier`.

The commands:

1. `T fence --psql '<superuser on the old primary>' … --runtime-role <runtime role> --receipts R/fence`
   - Before: it reads the privileges and probes a runtime write. The probe is
     a no-op update of the dispatch singleton's `stall_state` as the runtime
     role, always rolled back, and must succeed.
   - Fence: it runs `fence.sql`, which revokes INSERT, UPDATE, DELETE and
     TRUNCATE on every table and USAGE and UPDATE on every sequence of
     schema `opencast` from that role. A table-level revoke also removes the
     column grants. SELECT stays, so stale readers keep working.
   - After: zero writable tables, columns and sequences; the probe refused
     with 42501; and every privilege difference a runtime write.
   - It refuses on a database that holds a marker. It needs a superuser
     session because the probe sets the runtime role.
2. Restore to the point into a new data directory, and promote it.
3. `T nonce > R/nonce`, then
   `T mark --psql '<owner on the copy>' [--owner-role <owner>] … --recovery-target <lsn:…|time:…|latest> --nonce "$(cat R/nonce)" --receipts R/recovery`.
   `marker.sql` refuses (with SQLSTATE) in these cases:
   - ORM01: the server is in recovery, or its current run did not begin with
     archive recovery (`pg_last_xact_replay_timestamp()` is set only by
     archive recovery and stays fixed after promotion until a restart). So a
     primary that was never restored cannot be marked, not even after a crash
     restart.
   - ORM02: another database or cluster.
   - ORM03: an effective role that does not own schema `opencast`.
   - ORM04: a schema without the 32 application tables.
   - ORM05: an existing marker.

   The marker records `restored_at`, the recovery target, the last replayed
   commit, the boundary (`restored_at`), the timeline, the identifier, the
   database and the nonce's sha256.
4. `T reconcile --psql '<owner on the copy>' [--owner-role <owner>] … --nonce "$(cat R/nonce)" --receipts R/recovery`. See below.
5. `T census --psql '<reader>' … --label after --receipts R/recovery`, and
   `T acl … --compare R/fence/fence.json`. If the copy carries the fence
   (its restore point follows the fence), run `T unfence` on the copy.
   The reader has no USAGE on `opencast_recovery`, so its census receipt
   records the marker as unreadable (null); the owner's receipts attest the
   marker.
6. `T close --psql '<owner on the copy>' … --nonce "$(cat R/nonce)" --receipts R/recovery`
   re-checks the end state, including the dispatch gate singleton, under the
   same gate probe (22012 when the singleton is absent). It then drops schema
   `opencast_recovery`. From then on `reconcile` and `close` refuse on this
   database, because it holds no marker, before the copy serves. A deliberate
   new `mark` is still possible until the promoted server restarts, and only
   by an operator who means it.
7. `T unfence … --runtime-role <role> --fence-receipt R/fence/fence.json --receipts R/unfence`
   re-applies the seven runtime grant files in the parent README's order, in
   one transaction (`unfence.sql`). It passes only when the privilege set
   equals the fence receipt's readback exactly and the probe succeeds again.
   Run it on the old primary only when a recovery is abandoned before the
   copy serves.

`T <name>-sql` prints each shipped SQL file, with includes expanded. Every file
also runs unchanged under `psql -f` with its `-v` variables. The variables are
listed in each file's header.

## The reconciliation transaction

`reconcile.sql` runs as the owner of schema `opencast`. Lock timeout is 10 s,
statement timeout 300 s, idle timeout 60 s. The projection triggers stay enabled.

- **G1.** The marker row `FOR UPDATE`, before any application row. The
  refusals:
  - **42P01** (undefined table): the marker *schema* is absent, as on a live
    primary or after `close`.
  - **ORG01**: the marker relation exists but its row is missing, the nonce
    is wrong, the database, cluster or timeline is another, or the effective
    role is not the schema owner.
- **G2.** The dispatch gate: the storage interface's fail-closed probe,
  `SELECT 1/COUNT(*) AS guard … FROM (SELECT id FROM n_poll_dispatch WHERE id=1 FOR UPDATE)`,
  before any application row.
  - The outer SELECT prints the guard column, so the division is evaluated.
    An absent singleton fails the transaction with SQLSTATE 22012 (division
    by zero): the storage interface's own probe and failure class, so the
    tool and every runtime write fail the same way.
  - The driver also reads the singleton before streaming. On a missing
    singleton it refuses `reconcile` and `close` with exit 2; nothing is
    sent.
- **G3.** A rerun is allowed only while the end state still holds.
  - **ORG02**: a rerun on a copy whose end state no longer holds, for example
    after any re-enrolment.
  - The driver refuses the same cases before streaming (exit 2); the SQL
    codes are what a direct `psql -f` run reports.
- **The census before.** Then, in order:

| Id | Statement | Effect |
| --- | --- | --- |
| R13 | every enabled `n_control` set to 0, revision + 1 | everything stays paused |
| R14 | `n_interest.changed_at` = boundary | the erasure's prelude; the interest-removal trigger then sets `no_interest_since` to the boundary |
| R15 | delete `n_delivery_member` | erased |
| R7 | delete `n_delivery` | every delivery, including the uncertain ones (`pending`, `leased`, `uncertain`, `poisoned`), erased, never replayed |
| R16 | delete `n_group_member` rows of job events | erased |
| R17 | delete every job event (`kind <> 'episode'`) | erased |
| R18 | delete `n_requester_ticket` | restored tickets rejected |
| R10 | delete `n_job_interest` | job grants rejected |
| R5 | delete `n_interest` | erased; `n_interest_removed` moves each feed's eligibility generation |
| R11c | delete `n_legacy_bridge` | erased |
| R6 | delete `n_install` | installations erased; registration re-required |
| R19 | delete `n_delivery_history` | erased |
| R11a | delete `push_send_attempts` | audit erased |
| R20 | delete `feed_admission_attempts` | audit erased; admission rate limits restart |
| R4 | delete `feed_subscriptions` | subscription confirmation re-required |
| R3 | delete `devices` | device registration re-required |
| R11b | delete `secure_hello_attempts` | audit erased |
| R1 | delete `app_attest_challenges` | restored challenges rejected |
| R2 | delete `app_attest_keys` | restored credentials rejected; re-attestation required (`unknown_key`) |
| R11d | delete `app_attest_challenge_source_buckets` | restored rate state erased |
| R8 | events with `fanout_complete = 0` closed: complete, `disposition = 'suppressed'`, `terminal_at` = boundary, envelope cleared, lease dropped | unfinished fan-out never resumes |
| R9 | pending `n_outbox` rows set to `expired` | unacknowledged publications never resume |
| R12 | every feed's eligibility generation + 1, lease dropped, once per marker | pre-recovery scans and staging observations cannot commit |

The erasure statements are the product's own per-installation erasure
(`EraseInstall` in the Worker's PostgreSQL storage). They are applied to every
installation, in its order, plus the challenge-source buckets and every job
event.

That order satisfies every foreign key:

- members go before deliveries and events;
- job group rows go before job events.

By the time devices and subscriptions are deleted, their triggers' targets are
already gone, so `n_device_delete` and `n_subscription_delete` update nothing.
Two things are kept:

- **Feed-level state**: feeds, the catalog, observations, snapshots, releases,
  bursts, origins, statistics, the circuit, episode events (closed) and the
  outbox (pending rows expired).
- **The keyed seven-day deletion fences.**

Why no pre-recovery release can reach a re-enrolled installation:

- a fresh subscription stores the server's current time as `created_at`;
- the projections copy that time into the interest's `activated_at`;
- the recipient rule admits an installation only for releases dated at or
  after activation.

The marker update (the commit witness) comes next, then the postconditions:

- the erased tables are empty;
- no job events remain;
- no unfinished events, pending outbox rows, enabled controls or feed leases;
- every feed's generation has moved;
- the marker is reconciled;
- the gate row is present.

Then the census after. The transaction commits only when every postcondition
holds; otherwise it rolls back with ORV01.

Every statement prints `recovery|stmt|<id>|<rows>|<clock>`, and the receipt
records each one's rows and elapsed milliseconds. The receipt also holds:

- four censuses: the driver's before, the transaction's before and after,
  and a separate session's after commit;
- the marker before, after and as committed, never the nonce;
- the postconditions and the outcome.

If psql dies at COMMIT, the marker's `reconciled_at` read in a fresh session
decides the outcome.

## Exit codes and receipts

- **0, PASS.**
- **1, STOP.** The command ran and its required outcome did not hold. **Exit 1
  can be a rollback or a committed state that could not be verified:** the
  receipt's `outcome` decides, so read it before anything else. Once a mutating
  command (`mark`, `reconcile`, `close`, `fence`, `unfence`) has sent its write
  stream:
  - the receipt says `mutation_attempted`;
  - it records the stream's own evidence (`psql.exit_code`,
    `commit_reported`; for `reconcile` also the statements and the census
    after) before any later read;
  - any later failure is STOP, never a refusal.

  The outcome words:
  - `COMMITTED`: the stream committed (and, on PASS, every readback agrees).
  - `COMMITTED_UNVERIFIED`: the stream reported its commit, then a read or
    the receipt output failed. The write happened. For `reconcile`, rerun it
    into a fresh receipts directory: it changes nothing when the end state
    holds, and it refuses when it does not.
  - `ROLLED_BACK_UNVERIFIED`: the stream reported its rollback, then a read
    failed.
  - `UNKNOWN`: the stream's outcome is unreadable. A write may have run.
  - `ROLLED_BACK`, `FAILED <SQLSTATE>`, `TARGET_STATE_UNKNOWN`,
    `COMMITTED_UNREPORTED`: the reconciliation's verified failure outcomes.
  - `NOT_COMMITTED`: a mutating command whose stream reported no commit.
  - STOP also covers a fence readback that is not zero and a listed privilege
    difference.
- **2, REFUSED.** Guard, identity, input or usage, decided before any write
  stream was sent: nothing was written. A malformed flag is rejected by
  argument parsing before any receipt; every other refusal leaves a receipt.

Receipts record identities, counts, state vocabularies, privileges, SQLSTATEs
and timings, never a row value or the nonce (argv shows `sha256:<12 hex>`).

## Tests

From the repository root:

```sh
python3 -m unittest discover -s Server/NotificationsWorker/postgres/recovery
```

`test_recovery.py` needs no database. It uses a stand-in psql and checks
these SQL invariants against the product source and the parent README:

- the gate order, and that the gate's outer SELECT reads its guard column;
- the erasure against `EraseInstall`;
- one end-state list;
- the unfence's seven grant files;
- a census that prints no row value.

`test_recovery_pg.py` runs against a real primary and a copy restored from its
base backup and archived WAL, then promoted, and skips unless
`OPENCAST_RECOVERY_PG` names a configuration (its docstring has the format).
Its synthetic seed (`--print-seed`) and every predicted count are stated in
the module.

# Target manifests and the restore compare

`cutover.py` reads a canonical manifest of the notifications and polling
application schema in this directory's parent from one PostgreSQL database,
and compares two such manifests: a reference database and a copy restored from
backup. It never contacts Cloudflare and never writes to a database. Every step
leaves a receipt in a directory the operator names.

Requirements: Python 3.9 or later (standard library only), psql 16 or later,
PostgreSQL 16 or later with server encoding UTF8, and a target installed from
the schema files in the parent directory's single-runtime-role order.

## The sequence

The operator keeps private directories for receipts and optional row files
(mode 0700; the tool refuses anything group- or world-accessible and never
overwrites a receipt). `T` below is
`python3 Server/NotificationsWorker/postgres/cutover/cutover.py`.

1. `T manifest-target --psql '<read-only psql argv as JSON>' --target-database <db> --target-system-identifier <id> [--rows-dir W/reference-rows] --receipts R1`
   on the reference database.
2. The same on the restored copy, with its own database name and system
   identifier, into `R2` (and `W/restored-rows`).
3. `T compare-targets --reference R1 --restored R2 [--reference-rows W/reference-rows --restored-rows W/restored-rows] --receipts R3`
   — **stop** on any difference: the restored copy does not equal its
   reference, so do not promote it.

`manifest-target` runs as a role that can read every application table and
write none; it refuses a superuser, a role that can write any table and a role
that cannot read one. Every psql session it starts reports the target's
identity (database name, `pg_control_system()` system identifier, server
version and encoding, role), and any session that names another database is
refused. It reads the catalog, then the catalog again and every table inside
one `REPEATABLE READ READ ONLY` snapshot, and writes `target-manifest.json`:
per table its columns and types, primary key, row count and digest; the
control rows (`n_control`, `n_circuit`, `n_poll_dispatch`) and the highest
`epoch` of `n_install` and `n_feed`; the projection triggers' names and enabled
states. It stops on a table set other than the 32 application tables, a
column type other than `bigint`, `text` or `bytea`, a table without a primary
key, a row line that is not canonical, or a catalog that changed between its
two reads.

`compare-targets` reads both receipt directories (each a passing
`manifest-target.json` and the `target-manifest.json` whose digest it records)
and lists every difference: per table, over both table sets, the columns,
primary key, row count and digest (with `rows_detail`, the rows missing, extra
and changed by primary key, when both row directories are given); the control
rows; the trigger names; any trigger not enabled on either side; a receipt
that did not pass. The two identities are recorded and never compared: a
restore lands in another cluster, so its system identifier differs by design
and its database name may too. Its receipt, `compare-targets.json`, carries
both manifest digests, both identities and the differences.

A missing or malformed flag is rejected by argument parsing (exit 2) before
any receipt is written; every other refusal leaves a receipt. Exit 1 is a stop
(a data gate failed), exit 2 a refusal (identity, input or usage: nothing was
evaluated).

`--psql` is the complete argv prefix of a psql invocation (for example an SSH
command that runs psql on the database host). The tool appends its own flags and
streams SQL on stdin. Arguments that carry a password are refused; supply
credentials through the environment or a password file.

## Canonical rows and digests

A manifest encodes each row as one ASCII line: a JSON array with one token per
column in column order. Integers are decimal; text is `"t:"` plus the
lowercase hex of its exact UTF-8 bytes; `bytea` is `"b:"` plus lowercase hex;
NULL is `null`; a REAL (which no target column holds) is `"r:"` plus its
shortest round-trip text. Rows are ordered by primary key: integers
numerically, text and bytes by bytes (PostgreSQL's `COLLATE "C"`). The tool
re-checks the order and re-parses every line, so a disagreement stops rather
than producing a different digest.

A table's digest is sha256 over the concatenated sha256 of each `line + "\n"`.

## Privacy

Receipts and manifests carry identities, counts, digests, the control rows and
SQLSTATEs, never another row value or key. Row files written with `--rows-dir`
are private data: keep them in a private directory and delete them once the
comparison is done. psql reports SQLSTATEs only, because PostgreSQL's error
detail quotes row values.

## History

The one-time move of this authority out of D1 (fence, bookmark, export, scan,
manifest-source, emit, load, compare, attest) ran once, on 2026-10-16; its
receipts are archived with the cutover's own record. The tool no longer
carries those commands; `manifest-target` and the canonical form are the ones
it used.

## Tests

From the repository root:

```sh
python3 -B -m unittest discover -s Server/NotificationsWorker/postgres/cutover
```

The tests need no database server: a stand-in psql answers with
`fixtures/target-catalog.txt`, the catalog a fresh install reports. Its first
line is `migrations|` and the sha256 of the parent's `migrations/*.sql`
concatenated in name order; the rest is `CATALOG_SQL`'s output as the read-only
role. A test fails when a migration is edited or added: regenerate the
fixture from a fresh clone of the local topology's template
(`postgres/local/`), reading `CATALOG_SQL` as `opencast_local_reader`
(`psql -X -q -A -t`), and update its first line.

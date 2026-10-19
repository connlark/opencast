-- Recovery marker. The operator who restored a copy writes it once, after
-- promote and before any restart of the copy. reconcile.sql and close.sql run
-- only where this marker holds the operator's nonce.
--
-- psql variables: nonce (32 lowercase hex), recovery_target (lsn:<lsn>,
-- time:<ISO 8601> or latest), target_database, system_identifier; owner_role
-- is optional (SET LOCAL ROLE from a superuser or migrator session). The
-- effective role must own schema opencast; the marker schema is then its own.
--
-- Refusals (SQLSTATE): ORM00 a variable is missing or malformed; ORM01 the
-- server is not a promoted copy whose current run began with archive recovery
-- (pg_last_xact_replay_timestamp() is set only by archive recovery and stays
-- fixed after promotion until the next restart); ORM02 not the database or
-- cluster named; ORM03 the effective role does not own schema opencast; ORM04
-- schema opencast does not hold the 32 application tables; ORM05 a marker
-- already exists.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
\pset format unaligned
\pset tuples_only on
\if :{?nonce}
\if :{?recovery_target}
\if :{?target_database}
\if :{?system_identifier}
\set recovery_vars true
\endif
\endif
\endif
\endif
\if :{?recovery_vars}
\else
DO $vars$ BEGIN RAISE EXCEPTION USING ERRCODE = 'ORM00', MESSAGE = 'marker.sql needs -v nonce, recovery_target, target_database and system_identifier'; END $vars$;
\endif
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
\if :{?owner_role}
SET LOCAL ROLE :"owner_role";
\endif
SELECT 'recovery|vars|' || count(*) FROM (VALUES
  (set_config('opencast_recovery.nonce_ok', (:'nonce' ~ '^[0-9a-f]{32}$')::text, true)),
  (set_config('opencast_recovery.nonce_sha256', encode(sha256(convert_to(:'nonce', 'UTF8')), 'hex'), true)),
  (set_config('opencast_recovery.recovery_target', :'recovery_target', true)),
  (set_config('opencast_recovery.database', :'target_database', true)),
  (set_config('opencast_recovery.system_identifier', :'system_identifier', true))) AS v(x);
DO $mark$
DECLARE
  replayed timestamptz := pg_last_xact_replay_timestamp();
  sysid text := (SELECT system_identifier::text FROM pg_control_system());
  target text := current_setting('opencast_recovery.recovery_target');
  restored bigint := extract(epoch FROM now())::bigint;
BEGIN
  IF current_setting('opencast_recovery.nonce_ok') <> 'true'
     OR target !~ '^(latest|lsn:[0-9A-F]{1,8}/[0-9A-F]{1,8}|time:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2}))$' THEN
    RAISE EXCEPTION USING ERRCODE = 'ORM00', MESSAGE = 'the nonce or the recovery target is malformed';
  END IF;
  IF pg_is_in_recovery() OR replayed IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ORM01',
      MESSAGE = 'not a promoted restored copy: the server is in recovery, or its current run did not begin with archive recovery';
  END IF;
  IF current_database() <> current_setting('opencast_recovery.database')
     OR sysid <> current_setting('opencast_recovery.system_identifier') THEN
    RAISE EXCEPTION USING ERRCODE = 'ORM02', MESSAGE = 'connected to a database other than the one named';
  END IF;
  IF (SELECT nspowner FROM pg_namespace WHERE nspname = 'opencast') IS DISTINCT FROM
     (SELECT oid FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION USING ERRCODE = 'ORM03', MESSAGE = 'the effective role does not own schema opencast';
  END IF;
  IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'opencast' AND c.relkind IN ('r', 'p')) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = 'ORM04', MESSAGE = 'schema opencast does not hold the 32 application tables';
  END IF;
  IF to_regnamespace('opencast_recovery') IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ORM05', MESSAGE = 'this database already holds a recovery marker';
  END IF;
  CREATE SCHEMA opencast_recovery;
  REVOKE ALL ON SCHEMA opencast_recovery FROM PUBLIC;
  CREATE TABLE opencast_recovery.marker (
    id bigint PRIMARY KEY CHECK (id = 1),
    format text NOT NULL CHECK (format = 'opencast-recovery-marker-1'),
    nonce_sha256 text NOT NULL CHECK (nonce_sha256 ~ '^[0-9a-f]{64}$'),
    restored_at bigint NOT NULL,
    recovery_target text NOT NULL,
    last_replayed_at bigint NOT NULL,
    boundary bigint NOT NULL,
    timeline bigint NOT NULL,
    system_identifier text NOT NULL,
    database text NOT NULL,
    reconciled_at bigint
  );
  REVOKE ALL ON opencast_recovery.marker FROM PUBLIC;
  INSERT INTO opencast_recovery.marker VALUES (
    1, 'opencast-recovery-marker-1', current_setting('opencast_recovery.nonce_sha256'), restored, target,
    extract(epoch FROM replayed)::bigint, GREATEST(restored, extract(epoch FROM replayed)::bigint),
    ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::bigint, sysid, current_database(), NULL);
END
$mark$;
SELECT 'recovery|marker|' || restored_at || '|' || recovery_target || '|' || last_replayed_at || '|' || boundary
       || '|' || timeline || '|' || system_identifier || '|' || database
FROM opencast_recovery.marker WHERE id = 1;
COMMIT;
\echo recovery|mark|COMMITTED

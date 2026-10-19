-- Old-primary write fence: revoke the runtime role's write privileges on every
-- application table and sequence of this database, so no Worker write can
-- commit here while a restored copy takes over. Table privileges are per
-- database, so another database that shares the role is untouched. A
-- table-level REVOKE also removes the role's column-level INSERT and UPDATE
-- grants; SELECT stays, so stale readers keep working. unfence.sql reverses it.
--
-- Run as a superuser on the old primary's database. psql variables:
-- runtime_role, target_database, system_identifier. Refusals: ORF00 a variable
-- is missing; ORF01 this database holds a recovery marker (it is a restored
-- copy, not the old primary); ORF02 the session is not superuser; ORF03 not the
-- database or cluster named; ORF04 the runtime role does not exist.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
\pset format unaligned
\pset tuples_only on
\if :{?runtime_role}
\if :{?target_database}
\if :{?system_identifier}
\set recovery_vars true
\endif
\endif
\endif
\if :{?recovery_vars}
\else
DO $vars$ BEGIN RAISE EXCEPTION USING ERRCODE = 'ORF00', MESSAGE = 'fence.sql needs -v runtime_role, target_database and system_identifier'; END $vars$;
\endif
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
SELECT 'recovery|vars|' || count(*) FROM (VALUES
  (set_config('opencast_recovery.runtime_role', :'runtime_role', true)),
  (set_config('opencast_recovery.database', :'target_database', true)),
  (set_config('opencast_recovery.system_identifier', :'system_identifier', true))) AS v(x);
DO $guard$
BEGIN
  IF to_regclass('opencast_recovery.marker') IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ORF01', MESSAGE = 'this database holds a recovery marker: it is a restored copy, not the old primary';
  END IF;
  IF current_setting('is_superuser') <> 'on' THEN
    RAISE EXCEPTION USING ERRCODE = 'ORF02', MESSAGE = 'the fence needs a superuser session';
  END IF;
  IF current_database() <> current_setting('opencast_recovery.database')
     OR (SELECT system_identifier::text FROM pg_control_system()) <> current_setting('opencast_recovery.system_identifier') THEN
    RAISE EXCEPTION USING ERRCODE = 'ORF03', MESSAGE = 'connected to a database other than the one named';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_setting('opencast_recovery.runtime_role')) THEN
    RAISE EXCEPTION USING ERRCODE = 'ORF04', MESSAGE = 'the runtime role does not exist';
  END IF;
END
$guard$;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA opencast FROM :"runtime_role";
REVOKE USAGE, UPDATE ON ALL SEQUENCES IN SCHEMA opencast FROM :"runtime_role";
COMMIT;
\echo recovery|fence|COMMITTED

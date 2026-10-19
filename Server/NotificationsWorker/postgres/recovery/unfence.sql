-- Lift the write fence: re-apply the shipped runtime grant files, in the
-- parent README's single-runtime-role order (the migrations left out), in one
-- transaction. The grant files hold only GRANT statements, so this restores
-- exactly the installed union; the driver proves it by ACL equality with the
-- fence receipt's readback.
--
-- Run as a superuser. psql variables: runtime_role, target_database,
-- system_identifier. Refusals: ORU00 a variable is missing; ORU02 the session
-- is not superuser; ORU03 not the database or cluster named.
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
DO $vars$ BEGIN RAISE EXCEPTION USING ERRCODE = 'ORU00', MESSAGE = 'unfence.sql needs -v runtime_role, target_database and system_identifier'; END $vars$;
\endif
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
SELECT 'recovery|vars|' || count(*) FROM (VALUES
  (set_config('opencast_recovery.database', :'target_database', true)),
  (set_config('opencast_recovery.system_identifier', :'system_identifier', true))) AS v(x);
DO $guard$
BEGIN
  IF current_setting('is_superuser') <> 'on' THEN
    RAISE EXCEPTION USING ERRCODE = 'ORU02', MESSAGE = 'the unfence needs a superuser session';
  END IF;
  IF current_database() <> current_setting('opencast_recovery.database')
     OR (SELECT system_identifier::text FROM pg_control_system()) <> current_setting('opencast_recovery.system_identifier') THEN
    RAISE EXCEPTION USING ERRCODE = 'ORU03', MESSAGE = 'connected to a database other than the one named';
  END IF;
END
$guard$;
\ir ../runtime-grants.sql
\ir ../runtime-grants-slice-b.sql
\ir ../runtime-grants-slice-c.sql
\ir ../runtime-grants-slice-d.sql
\ir ../runtime-grants-slice-e.sql
\ir ../runtime-grants-slice-f.sql
\ir ../runtime-grants-integration.sql
COMMIT;
\echo recovery|unfence|COMMITTED

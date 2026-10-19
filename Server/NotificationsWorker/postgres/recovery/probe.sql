-- Runtime write probe, always rolled back: one read of n_control and one
-- no-op update of the dispatch singleton's stall_state column, both as the
-- runtime role (runtime-grants.sql grants that column's UPDATE). Prints
-- probe|select|<rows> and, when the update is allowed, probe|write|<rows>; a
-- refused update leaves its SQLSTATE (42501) on stderr. The update takes the
-- singleton's row lock for the length of the probe, as any runtime write does.
--
-- psql variable runtime_role. The session must be able to SET ROLE to it
-- (a superuser session).
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '10s';
SET LOCAL ROLE :"runtime_role";
SELECT 'probe|select|' || count(*) FROM opencast.n_control;
\set ON_ERROR_STOP off
WITH u AS (UPDATE opencast.n_poll_dispatch SET stall_state = stall_state WHERE id = 1 RETURNING 1)
SELECT 'probe|write|' || count(*) FROM u;
\set ON_ERROR_STOP on
ROLLBACK;
\echo probe|done

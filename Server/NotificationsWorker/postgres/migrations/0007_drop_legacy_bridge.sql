-- Drop the legacy handoff-dedupe bridge. Apply once as
-- the owner, LAST and separately: after the release of both Workers whose
-- builds list 31 application tables, and after 0006 (which stops the n_feed
-- trigger hydrating the table). A build listing 32 tables binds only while the
-- table exists, so the drop comes after that release; the 31-table identity
-- digest is the same before and after it.
-- Maintenance takes the n_poll_dispatch gate first (postgres/README.md); a
-- missing singleton aborts by division by zero. Then, when the table still
-- exists, an ACCESS EXCLUSIVE lock on it before anything reads it, and the
-- transaction aborts, dropping nothing, while the trigger function still
-- writes the table (0006 not applied) or while any row is unexpired against
-- unrounded time. No CASCADE: a dependent object stops the drop. Idempotent: a
-- run without the table changes nothing.
-- Rollback to a 32-table build: re-create the table, empty, as the owner from
-- 0001_slice_a.sql:67-71, and re-apply its grants (a drop takes them along):
-- runtime-grants-slice-c.sql's INSERT(install_id,feed_id,identity_key,
-- disposition,expires_at), SELECT(install_id) and DELETE, -slice-d.sql's
-- SELECT(install_id,feed_id,expires_at,identity_key) and -slice-e.sql's SELECT
-- and DELETE, as of their versions before this change, and reader-grants.sql;
-- then the 32-table digest reads the old pin again.
BEGIN;

SELECT 1/COUNT(*) FROM (SELECT id FROM opencast.n_poll_dispatch WHERE id = 1 FOR UPDATE) AS gate;

DO $drop$
BEGIN
  IF to_regclass('opencast.n_legacy_bridge') IS NULL THEN
    RETURN;
  END IF;
  LOCK TABLE opencast.n_legacy_bridge IN ACCESS EXCLUSIVE MODE;
  IF strpos(pg_get_functiondef('opencast.n_feed_insert_fn()'::regprocedure), 'n_legacy_bridge') > 0 THEN
    RAISE EXCEPTION 'n_feed_insert_fn still writes n_legacy_bridge: apply 0006 first'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM opencast.n_legacy_bridge
      WHERE expires_at > floor(extract(epoch FROM clock_timestamp()))) THEN
    RAISE EXCEPTION 'n_legacy_bridge holds unexpired rows: the drop is refused'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$drop$;

DROP TABLE IF EXISTS opencast.n_legacy_bridge;

COMMIT;

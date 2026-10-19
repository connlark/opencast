-- Recovery close: after verification and before the copy is put back in
-- service, drop the recovery marker so the reconciliation can never run on
-- this database again. Run as the owner of schema opencast.
--
-- psql variables: nonce, target_database, system_identifier; owner_role
-- optional. Refusals: ORC00 a variable is missing; ORC01 no marker (42P01 when
-- the marker schema does not exist), a wrong nonce, another database, cluster
-- or timeline, or an effective role that does not own schema opencast; ORC02
-- the copy was never reconciled; 22012 (division by zero) the dispatch gate
-- singleton is absent (the storage interface's probe, read by the outer SELECT);
-- ORC03 the end state no longer holds.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
\pset format unaligned
\pset tuples_only on
\if :{?nonce}
\if :{?target_database}
\if :{?system_identifier}
\set recovery_vars true
\endif
\endif
\endif
\if :{?recovery_vars}
\else
DO $vars$ BEGIN RAISE EXCEPTION USING ERRCODE = 'ORC00', MESSAGE = 'close.sql needs -v nonce, target_database and system_identifier'; END $vars$;
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
  (set_config('opencast_recovery.database', :'target_database', true)),
  (set_config('opencast_recovery.system_identifier', :'system_identifier', true))) AS v(x);
DO $guard$
DECLARE
  m record;
  sysid text := (SELECT system_identifier::text FROM pg_control_system());
  tli bigint := ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::bigint;
BEGIN
  SELECT * INTO m FROM opencast_recovery.marker WHERE id = 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'ORC01', MESSAGE = 'the recovery marker has no row';
  END IF;
  IF current_setting('opencast_recovery.nonce_ok') <> 'true' OR m.format <> 'opencast-recovery-marker-1'
     OR m.nonce_sha256 <> current_setting('opencast_recovery.nonce_sha256') THEN
    RAISE EXCEPTION USING ERRCODE = 'ORC01', MESSAGE = 'the nonce does not match the recovery marker';
  END IF;
  IF current_database() <> current_setting('opencast_recovery.database') OR m.database <> current_database()
     OR sysid <> current_setting('opencast_recovery.system_identifier') OR m.system_identifier <> sysid
     OR m.timeline <> tli THEN
    RAISE EXCEPTION USING ERRCODE = 'ORC01', MESSAGE = 'not the database, cluster or timeline the marker names';
  END IF;
  IF (SELECT nspowner FROM pg_namespace WHERE nspname = 'opencast') IS DISTINCT FROM
     (SELECT oid FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION USING ERRCODE = 'ORC01', MESSAGE = 'the effective role does not own schema opencast';
  END IF;
  IF m.reconciled_at IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ORC02', MESSAGE = 'this copy was never reconciled';
  END IF;
END
$guard$;
SELECT 'recovery|gate|' || g.guard || '|' || g.gate_wait_us || '|' || extract(epoch FROM clock_timestamp())
FROM (SELECT 1/COUNT(*) AS guard,(EXTRACT(EPOCH FROM clock_timestamp()-statement_timestamp())*1000000)::bigint AS gate_wait_us FROM (SELECT id FROM opencast.n_poll_dispatch WHERE id=1 FOR UPDATE) AS gate) AS g;
DO $state$
BEGIN
  IF EXISTS (SELECT 1 FROM (VALUES
    -- recovery:end-state begin
    ('app_attest_challenge_source_buckets', (SELECT count(*) FROM opencast.app_attest_challenge_source_buckets)),
    ('app_attest_challenges', (SELECT count(*) FROM opencast.app_attest_challenges)),
    ('app_attest_keys', (SELECT count(*) FROM opencast.app_attest_keys)),
    ('devices', (SELECT count(*) FROM opencast.devices)),
    ('feed_admission_attempts', (SELECT count(*) FROM opencast.feed_admission_attempts)),
    ('feed_subscriptions', (SELECT count(*) FROM opencast.feed_subscriptions)),
    ('n_control_enabled', (SELECT count(*) FROM opencast.n_control WHERE enabled = 1)),
    ('n_delivery', (SELECT count(*) FROM opencast.n_delivery)),
    ('n_delivery_history', (SELECT count(*) FROM opencast.n_delivery_history)),
    ('n_delivery_member', (SELECT count(*) FROM opencast.n_delivery_member)),
    ('n_event_job', (SELECT count(*) FROM opencast.n_event WHERE kind <> 'episode')),
    ('n_event_unfinished', (SELECT count(*) FROM opencast.n_event WHERE fanout_complete = 0)),
    ('n_feed_leased', (SELECT count(*) FROM opencast.n_feed WHERE lease_id IS NOT NULL)),
    ('n_group_member_job', (SELECT count(*) FROM opencast.n_group_member g JOIN opencast.n_event e
                              ON e.source = g.source AND e.event_id = g.event_id WHERE e.kind <> 'episode')),
    ('n_install', (SELECT count(*) FROM opencast.n_install)),
    ('n_interest', (SELECT count(*) FROM opencast.n_interest)),
    ('n_job_interest', (SELECT count(*) FROM opencast.n_job_interest)),
    ('n_legacy_bridge', (SELECT count(*) FROM opencast.n_legacy_bridge)),
    ('n_outbox_pending', (SELECT count(*) FROM opencast.n_outbox WHERE state = 'pending')),
    ('n_poll_dispatch_missing', (SELECT 1 - count(*) FROM opencast.n_poll_dispatch WHERE id = 1)),
    ('n_requester_ticket', (SELECT count(*) FROM opencast.n_requester_ticket)),
    ('push_send_attempts', (SELECT count(*) FROM opencast.push_send_attempts)),
    ('secure_hello_attempts', (SELECT count(*) FROM opencast.secure_hello_attempts))
    -- recovery:end-state end
  ) AS e(name, n) WHERE e.n <> 0) THEN
    RAISE EXCEPTION USING ERRCODE = 'ORC03', MESSAGE = 'the reconciled end state no longer holds';
  END IF;
END
$state$;
SELECT 'recovery|marker|closed|' || restored_at || '|' || recovery_target || '|' || last_replayed_at || '|' || boundary
       || '|' || timeline || '|' || system_identifier || '|' || database || '|' || COALESCE(reconciled_at::text, '')
FROM opencast_recovery.marker WHERE id = 1;
DROP SCHEMA opencast_recovery CASCADE;
COMMIT;
\echo recovery|close|COMMITTED

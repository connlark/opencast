-- Recovery reconciliation: one transaction on a marked restored copy, run as
-- the owner of schema opencast with the projection triggers enabled. It closes
-- every control; erases every user-linked family the product's installation
-- erasure defines, table-wide and in that erasure's order (plus the
-- challenge-source buckets and every job event); closes unfinished events;
-- expires pending outbox rows; moves every feed's eligibility generation; and
-- commits only when the end state holds. Each statement prints
-- recovery|stmt|<id>|<rows>|<clock>; see README.md for the ids.
--
-- psql variables: nonce, target_database, system_identifier; optional
-- owner_role, lock_timeout (10s), statement_timeout (300s), idle_timeout (60s).
--
-- Refusals before any application row: ORG00 a variable is missing; ORG01 no
-- marker (42P01 when the marker schema does not exist), a wrong nonce, another
-- database, cluster or timeline than the marker's, or an effective role that
-- does not own schema opencast. At the dispatch gate: 22012 (division by
-- zero) the gate singleton is absent. After it: ORG02 a rerun on a copy whose
-- end state no longer holds. ORV01: the end state did not hold; rolled back.
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
DO $vars$ BEGIN RAISE EXCEPTION USING ERRCODE = 'ORG00', MESSAGE = 'reconcile.sql needs -v nonce, target_database and system_identifier'; END $vars$;
\endif
\if :{?lock_timeout}
\else
\set lock_timeout 10s
\endif
\if :{?statement_timeout}
\else
\set statement_timeout 300s
\endif
\if :{?idle_timeout}
\else
\set idle_timeout 60s
\endif
BEGIN;
SET LOCAL lock_timeout = :'lock_timeout';
SET LOCAL statement_timeout = :'statement_timeout';
SET LOCAL idle_in_transaction_session_timeout = :'idle_timeout';
\if :{?owner_role}
SET LOCAL ROLE :"owner_role";
\endif
SELECT 'recovery|vars|' || count(*) FROM (VALUES
  (set_config('opencast_recovery.nonce_ok', (:'nonce' ~ '^[0-9a-f]{32}$')::text, true)),
  (set_config('opencast_recovery.nonce_sha256', encode(sha256(convert_to(:'nonce', 'UTF8')), 'hex'), true)),
  (set_config('opencast_recovery.database', :'target_database', true)),
  (set_config('opencast_recovery.system_identifier', :'system_identifier', true))) AS v(x);

-- G1: the marker row, locked, before the gate and before any application row.
DO $guard$
DECLARE
  m record;
  sysid text := (SELECT system_identifier::text FROM pg_control_system());
  tli bigint := ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::bigint;
BEGIN
  SELECT * INTO m FROM opencast_recovery.marker WHERE id = 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'ORG01', MESSAGE = 'the recovery marker has no row';
  END IF;
  IF current_setting('opencast_recovery.nonce_ok') <> 'true' OR m.format <> 'opencast-recovery-marker-1'
     OR m.nonce_sha256 <> current_setting('opencast_recovery.nonce_sha256') THEN
    RAISE EXCEPTION USING ERRCODE = 'ORG01', MESSAGE = 'the nonce does not match the recovery marker';
  END IF;
  IF current_database() <> current_setting('opencast_recovery.database') OR m.database <> current_database()
     OR sysid <> current_setting('opencast_recovery.system_identifier') OR m.system_identifier <> sysid
     OR m.timeline <> tli THEN
    RAISE EXCEPTION USING ERRCODE = 'ORG01', MESSAGE = 'not the database, cluster or timeline the marker names';
  END IF;
  IF (SELECT nspowner FROM pg_namespace WHERE nspname = 'opencast') IS DISTINCT FROM
     (SELECT oid FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION USING ERRCODE = 'ORG01', MESSAGE = 'the effective role does not own schema opencast';
  END IF;
  PERFORM set_config('opencast_recovery.boundary', m.boundary::text, true);
  PERFORM set_config('opencast_recovery.first_run', (m.reconciled_at IS NULL)::text, true);
END
$guard$;
SELECT 'recovery|marker|before|' || restored_at || '|' || recovery_target || '|' || last_replayed_at || '|' || boundary
       || '|' || timeline || '|' || system_identifier || '|' || database || '|' || COALESCE(reconciled_at::text, '')
FROM opencast_recovery.marker WHERE id = 1;

-- G2: the dispatch gate, the storage interface's fail-closed singleton probe. The outer SELECT reads its
-- guard column, so 1/COUNT(*) is evaluated: an absent singleton fails here with 22012 (division by zero),
-- the storage interface's own failure class, before any application statement.
SELECT 'recovery|gate|' || g.guard || '|' || g.gate_wait_us || '|' || extract(epoch FROM clock_timestamp())
FROM (SELECT 1/COUNT(*) AS guard,(EXTRACT(EPOCH FROM clock_timestamp()-statement_timestamp())*1000000)::bigint AS gate_wait_us FROM (SELECT id FROM opencast.n_poll_dispatch WHERE id=1 FOR UPDATE) AS gate) AS g;

-- G3: a rerun only while the committed end state still holds.
DO $rerun$
BEGIN
  IF current_setting('opencast_recovery.first_run') <> 'true' AND EXISTS (SELECT 1 FROM (VALUES
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
    RAISE EXCEPTION USING ERRCODE = 'ORG02',
      MESSAGE = 'the state changed after reconciliation: this database is no longer the reconciled copy';
  END IF;
END
$rerun$;

\set census_phase before
\ir census.sql
CREATE TEMP TABLE recovery_generation ON COMMIT DROP AS SELECT feed_id, eligibility_generation FROM opencast.n_feed;

-- R13: every control closed first. Reopening is the operator's act.
WITH u AS (UPDATE opencast.n_control SET enabled = 0, revision = revision + 1 WHERE enabled = 1 RETURNING 1)
SELECT 'recovery|stmt|R13|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM u;
-- R14: the erasure's prelude, so the interest-removal trigger stamps the boundary.
WITH u AS (UPDATE opencast.n_interest SET changed_at = current_setting('opencast_recovery.boundary')::bigint RETURNING 1)
SELECT 'recovery|stmt|R14|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM u;
-- R15..R11d: the installation erasure's families, table-wide, in its order.
WITH d AS (DELETE FROM opencast.n_delivery_member RETURNING 1)
SELECT 'recovery|stmt|R15|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_delivery RETURNING 1)
SELECT 'recovery|stmt|R7|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_group_member WHERE (source, event_id) IN (SELECT source, event_id FROM opencast.n_event WHERE kind <> 'episode') RETURNING 1)
SELECT 'recovery|stmt|R16|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_event WHERE kind <> 'episode' RETURNING 1)
SELECT 'recovery|stmt|R17|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_requester_ticket RETURNING 1)
SELECT 'recovery|stmt|R18|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_job_interest RETURNING 1)
SELECT 'recovery|stmt|R10|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_interest RETURNING 1)
SELECT 'recovery|stmt|R5|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_legacy_bridge RETURNING 1)
SELECT 'recovery|stmt|R11c|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_install RETURNING 1)
SELECT 'recovery|stmt|R6|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.n_delivery_history RETURNING 1)
SELECT 'recovery|stmt|R19|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.push_send_attempts RETURNING 1)
SELECT 'recovery|stmt|R11a|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.feed_admission_attempts RETURNING 1)
SELECT 'recovery|stmt|R20|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.feed_subscriptions RETURNING 1)
SELECT 'recovery|stmt|R4|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.devices RETURNING 1)
SELECT 'recovery|stmt|R3|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.secure_hello_attempts RETURNING 1)
SELECT 'recovery|stmt|R11b|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.app_attest_challenges RETURNING 1)
SELECT 'recovery|stmt|R1|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.app_attest_keys RETURNING 1)
SELECT 'recovery|stmt|R2|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
WITH d AS (DELETE FROM opencast.app_attest_challenge_source_buckets RETURNING 1)
SELECT 'recovery|stmt|R11d|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM d;
-- R8: unfinished events closed, never fanned out (the event-expiry shape).
WITH u AS (UPDATE opencast.n_event SET fanout_complete = 1, disposition = 'suppressed',
             terminal_at = current_setting('opencast_recovery.boundary')::bigint, envelope_json = '{}',
             lease_id = NULL, lease_until = NULL
           WHERE fanout_complete = 0 RETURNING 1)
SELECT 'recovery|stmt|R8|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM u;
-- R9: pending outbox rows expired (the outbox has no suppressed state).
WITH u AS (UPDATE opencast.n_outbox SET state = 'expired' WHERE state = 'pending' RETURNING 1)
SELECT 'recovery|stmt|R9|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM u;
-- R12: a fresh eligibility generation on every feed, once per marker.
WITH u AS (UPDATE opencast.n_feed SET eligibility_generation = eligibility_generation + 1, lease_id = NULL, lease_until = NULL
           WHERE (SELECT reconciled_at FROM opencast_recovery.marker WHERE id = 1) IS NULL RETURNING 1)
SELECT 'recovery|stmt|R12|' || count(*) || '|' || extract(epoch FROM clock_timestamp()) FROM u;
-- M: the commit witness.
WITH u AS (UPDATE opencast_recovery.marker SET reconciled_at = extract(epoch FROM now())::bigint
           WHERE id = 1 AND reconciled_at IS NULL RETURNING 1)
SELECT 'recovery|marker_update|' || count(*) FROM u;
SELECT 'recovery|marker|after|' || restored_at || '|' || recovery_target || '|' || last_replayed_at || '|' || boundary
       || '|' || timeline || '|' || system_identifier || '|' || database || '|' || COALESCE(reconciled_at::text, '')
FROM opencast_recovery.marker WHERE id = 1;

-- V: the end state, checked before COMMIT.
SELECT string_agg('recovery|post|' || p.name || '|' || p.value || '|' || CASE WHEN p.ok THEN 'ok' ELSE 'FAIL' END,
                  E'\n' ORDER BY p.name COLLATE "C") AS recovery_report,
       bool_and(p.ok) AS recovery_ok
FROM (
  SELECT e.name, e.n::text AS value, e.n = 0 AS ok FROM (VALUES
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
  ) AS e(name, n)
  UNION ALL SELECT 'feeds_generation_not_moved', s.n::text, s.n = 0 FROM (
    SELECT count(*) AS n FROM opencast.n_feed f LEFT JOIN recovery_generation g ON g.feed_id = f.feed_id
    WHERE g.feed_id IS NULL OR CASE WHEN current_setting('opencast_recovery.first_run') = 'true'
                                    THEN f.eligibility_generation <= g.eligibility_generation
                                    ELSE f.eligibility_generation <> g.eligibility_generation END) AS s
  UNION ALL SELECT 'gate_rows', s.n::text, s.n = 1 FROM (SELECT count(*) AS n FROM opencast.n_poll_dispatch) AS s
  UNION ALL SELECT 'marker_reconciled', s.n::text, s.n = 1 FROM (
    SELECT count(*) AS n FROM opencast_recovery.marker WHERE id = 1 AND reconciled_at IS NOT NULL) AS s
) AS p \gset
\echo :recovery_report
\set census_phase after
\ir census.sql
\if :recovery_ok
COMMIT;
\echo recovery|commit|COMMITTED
\else
ROLLBACK;
\echo recovery|commit|ROLLED_BACK
DO $verify$ BEGIN RAISE EXCEPTION USING ERRCODE = 'ORV01', MESSAGE = 'the recovery end state did not hold; rolled back'; END $verify$;
\endif

-- Recovery census: row counts and state vocabularies of the 32 application
-- tables, never a row value. Read-only. Runs as any role that reads every
-- application table, and inside reconcile.sql's transaction (before and after).
-- Prints one census|<phase>|<key>|<count> line per key, ordered by key.
\if :{?census_phase}
\else
\set census_phase read
\endif
SELECT 'census|' || :'census_phase' || '|' || c.k || '|' || c.v
FROM (
  SELECT t.k, t.v::text AS v FROM (VALUES
    ('app_attest_challenge_source_buckets', (SELECT count(*) FROM opencast.app_attest_challenge_source_buckets)),
    ('app_attest_challenges', (SELECT count(*) FROM opencast.app_attest_challenges)),
    ('app_attest_keys', (SELECT count(*) FROM opencast.app_attest_keys)),
    ('devices', (SELECT count(*) FROM opencast.devices)),
    ('feed_admission_attempts', (SELECT count(*) FROM opencast.feed_admission_attempts)),
    ('feed_subscriptions', (SELECT count(*) FROM opencast.feed_subscriptions)),
    ('n_burst', (SELECT count(*) FROM opencast.n_burst)),
    ('n_circuit', (SELECT count(*) FROM opencast.n_circuit)),
    ('n_control', (SELECT count(*) FROM opencast.n_control)),
    ('n_deleted_install', (SELECT count(*) FROM opencast.n_deleted_install)),
    ('n_delivery', (SELECT count(*) FROM opencast.n_delivery)),
    ('n_delivery_history', (SELECT count(*) FROM opencast.n_delivery_history)),
    ('n_delivery_member', (SELECT count(*) FROM opencast.n_delivery_member)),
    ('n_episode_release', (SELECT count(*) FROM opencast.n_episode_release)),
    ('n_event', (SELECT count(*) FROM opencast.n_event)),
    ('n_feed', (SELECT count(*) FROM opencast.n_feed)),
    ('n_feed_catalog', (SELECT count(*) FROM opencast.n_feed_catalog)),
    ('n_group_member', (SELECT count(*) FROM opencast.n_group_member)),
    ('n_install', (SELECT count(*) FROM opencast.n_install)),
    ('n_interest', (SELECT count(*) FROM opencast.n_interest)),
    ('n_job_interest', (SELECT count(*) FROM opencast.n_job_interest)),
    ('n_legacy_bridge', (SELECT count(*) FROM opencast.n_legacy_bridge)),
    ('n_observation', (SELECT count(*) FROM opencast.n_observation)),
    ('n_outbox', (SELECT count(*) FROM opencast.n_outbox)),
    ('n_poll_dispatch', (SELECT count(*) FROM opencast.n_poll_dispatch)),
    ('n_poll_origin', (SELECT count(*) FROM opencast.n_poll_origin)),
    ('n_poll_stat', (SELECT count(*) FROM opencast.n_poll_stat)),
    ('n_requester_ticket', (SELECT count(*) FROM opencast.n_requester_ticket)),
    ('n_snapshot', (SELECT count(*) FROM opencast.n_snapshot)),
    ('n_snapshot_ref', (SELECT count(*) FROM opencast.n_snapshot_ref)),
    ('push_send_attempts', (SELECT count(*) FROM opencast.push_send_attempts)),
    ('secure_hello_attempts', (SELECT count(*) FROM opencast.secure_hello_attempts)),
    ('n_control_enabled', (SELECT count(*) FROM opencast.n_control WHERE enabled = 1)),
    ('n_interest_enabled', (SELECT count(*) FROM opencast.n_interest WHERE enabled = 1)),
    ('n_install_enabled', (SELECT count(*) FROM opencast.n_install WHERE enabled = 1)),
    ('devices_enabled', (SELECT count(*) FROM opencast.devices WHERE notifications_enabled = 1)),
    ('app_attest_keys_counter_positive', (SELECT count(*) FROM opencast.app_attest_keys WHERE sign_counter > 0)),
    ('app_attest_challenges_consumed', (SELECT count(*) FROM opencast.app_attest_challenges WHERE consumed_at IS NOT NULL)),
    ('app_attest_challenges_unconsumed', (SELECT count(*) FROM opencast.app_attest_challenges WHERE consumed_at IS NULL)),
    ('feed_subscriptions_live_opt_in', (SELECT count(*) FROM opencast.feed_subscriptions WHERE deleted_at IS NULL AND notifications_enabled = 1)),
    ('feed_subscriptions_deleted_or_opted_out', (SELECT count(*) FROM opencast.feed_subscriptions WHERE deleted_at IS NOT NULL OR notifications_enabled = 0)),
    ('n_event_unfinished', (SELECT count(*) FROM opencast.n_event WHERE fanout_complete = 0)),
    ('n_event_leased', (SELECT count(*) FROM opencast.n_event WHERE lease_id IS NOT NULL)),
    ('n_event_episode', (SELECT count(*) FROM opencast.n_event WHERE kind = 'episode')),
    ('n_event_job', (SELECT count(*) FROM opencast.n_event WHERE kind <> 'episode')),
    ('n_event_job_unfinished', (SELECT count(*) FROM opencast.n_event WHERE kind <> 'episode' AND fanout_complete = 0)),
    ('n_group_member_job', (SELECT count(*) FROM opencast.n_group_member g JOIN opencast.n_event e
                              ON e.source = g.source AND e.event_id = g.event_id WHERE e.kind <> 'episode')),
    ('n_outbox_pending', (SELECT count(*) FROM opencast.n_outbox WHERE state = 'pending')),
    ('n_feed_generation_sum', (SELECT COALESCE(sum(eligibility_generation), 0) FROM opencast.n_feed)),
    ('n_feed_leased', (SELECT count(*) FROM opencast.n_feed WHERE lease_id IS NOT NULL)),
    ('n_feed_no_interest_null', (SELECT count(*) FROM opencast.n_feed WHERE no_interest_since IS NULL))
  ) AS t(k, v)
  UNION ALL SELECT 'rows_total', (
    (SELECT count(*) FROM opencast.app_attest_challenge_source_buckets) + (SELECT count(*) FROM opencast.app_attest_challenges)
    + (SELECT count(*) FROM opencast.app_attest_keys) + (SELECT count(*) FROM opencast.devices)
    + (SELECT count(*) FROM opencast.feed_admission_attempts) + (SELECT count(*) FROM opencast.feed_subscriptions)
    + (SELECT count(*) FROM opencast.n_burst) + (SELECT count(*) FROM opencast.n_circuit)
    + (SELECT count(*) FROM opencast.n_control) + (SELECT count(*) FROM opencast.n_deleted_install)
    + (SELECT count(*) FROM opencast.n_delivery) + (SELECT count(*) FROM opencast.n_delivery_history)
    + (SELECT count(*) FROM opencast.n_delivery_member) + (SELECT count(*) FROM opencast.n_episode_release)
    + (SELECT count(*) FROM opencast.n_event) + (SELECT count(*) FROM opencast.n_feed)
    + (SELECT count(*) FROM opencast.n_feed_catalog) + (SELECT count(*) FROM opencast.n_group_member)
    + (SELECT count(*) FROM opencast.n_install) + (SELECT count(*) FROM opencast.n_interest)
    + (SELECT count(*) FROM opencast.n_job_interest) + (SELECT count(*) FROM opencast.n_legacy_bridge)
    + (SELECT count(*) FROM opencast.n_observation) + (SELECT count(*) FROM opencast.n_outbox)
    + (SELECT count(*) FROM opencast.n_poll_dispatch) + (SELECT count(*) FROM opencast.n_poll_origin)
    + (SELECT count(*) FROM opencast.n_poll_stat) + (SELECT count(*) FROM opencast.n_requester_ticket)
    + (SELECT count(*) FROM opencast.n_snapshot) + (SELECT count(*) FROM opencast.n_snapshot_ref)
    + (SELECT count(*) FROM opencast.push_send_attempts) + (SELECT count(*) FROM opencast.secure_hello_attempts))::text
  UNION ALL SELECT 'state|n_delivery|' || state, count(*)::text FROM opencast.n_delivery GROUP BY state
  UNION ALL SELECT 'state|n_outbox|' || state, count(*)::text FROM opencast.n_outbox GROUP BY state
  UNION ALL SELECT 'state|n_job_interest|' || state, count(*)::text FROM opencast.n_job_interest GROUP BY state
  UNION ALL SELECT 'state|n_episode_release|' || state, count(*)::text FROM opencast.n_episode_release GROUP BY state
  UNION ALL SELECT 'state|n_observation|' || state, count(*)::text FROM opencast.n_observation GROUP BY state
  UNION ALL SELECT 'state|n_snapshot|' || state, count(*)::text FROM opencast.n_snapshot GROUP BY state
  UNION ALL SELECT 'state|n_event_disposition|' || disposition, count(*)::text FROM opencast.n_event GROUP BY disposition
  UNION ALL SELECT 'control_enabled|' || name, enabled::text FROM opencast.n_control
  UNION ALL SELECT 'control_revision|' || name, revision::text FROM opencast.n_control
  UNION ALL SELECT 'circuit_paused|' || lane, paused::text FROM opencast.n_circuit
) AS c
ORDER BY c.k COLLATE "C";

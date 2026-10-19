-- Apply as schema owner after creating a LOGIN role provided in psql variable runtime_role.
-- Role creation, credentials, connection/time limits are owner-only setup.
-- No CREATE, TRUNCATE, role membership, function creation, or gate deletion.
GRANT USAGE ON SCHEMA opencast TO :"runtime_role";
GRANT SELECT ON opencast.n_control,opencast.n_poll_dispatch,opencast.n_poll_origin,opencast.n_poll_stat,opencast.n_feed,
 opencast.n_install,opencast.n_interest,opencast.n_observation,opencast.n_snapshot,opencast.n_episode_release,opencast.n_outbox,
 opencast.n_burst,opencast.n_snapshot_ref,opencast.n_feed_catalog TO :"runtime_role";
GRANT UPDATE ON opencast.n_feed,opencast.n_observation TO :"runtime_role";
GRANT INSERT ON opencast.n_snapshot,opencast.n_observation TO :"runtime_role";
GRANT INSERT,UPDATE ON opencast.n_poll_origin,opencast.n_poll_stat TO :"runtime_role";
GRANT UPDATE(absence_generation,absence_at) ON opencast.n_interest TO :"runtime_role";
GRANT UPDATE(stall_state,stall_since,stall_alerted_at,alert_armed_at)
 ON opencast.n_poll_dispatch TO :"runtime_role";
-- FOR UPDATE needs UPDATE on at least one column, supplied by the marker grants.
-- Trigger functions are invoker-security. The A interest update leaves the
-- enabled/generation WHEN predicate false; later slices must add their own grants.

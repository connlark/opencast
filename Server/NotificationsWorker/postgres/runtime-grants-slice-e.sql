-- Owner-only additive capabilities, after the inherited runtime grants.
-- Exact source statements and column mappings are retained below.
-- S075.
GRANT SELECT ON opencast.n_circuit TO :"runtime_role";
-- S061.
GRANT SELECT ON opencast.n_deleted_install TO :"runtime_role";
-- S053, S054, S055, S059, S060, S064, S066, S069, S073, S076, S128.
GRANT SELECT ON opencast.n_delivery TO :"runtime_role";
-- S063.
GRANT SELECT ON opencast.n_delivery_member TO :"runtime_role";
-- S052, S056, S057, S060, S062, S066, S069, S074, S128.
GRANT SELECT ON opencast.n_event TO :"runtime_role";
-- S065.
GRANT SELECT ON opencast.n_group_member TO :"runtime_role";
-- S069.
GRANT SELECT ON opencast.n_job_interest TO :"runtime_role";
-- S067, S071.
GRANT SELECT ON opencast.n_legacy_bridge TO :"runtime_role";
-- S068.
GRANT SELECT ON opencast.n_requester_ticket TO :"runtime_role";
-- S061.
GRANT DELETE ON opencast.n_deleted_install TO :"runtime_role";
-- S063.
GRANT DELETE ON opencast.n_delivery_member TO :"runtime_role";
-- S064.
GRANT DELETE ON opencast.n_delivery TO :"runtime_role";
-- S065.
GRANT DELETE ON opencast.n_group_member TO :"runtime_role";
-- S066.
GRANT DELETE ON opencast.n_event TO :"runtime_role";
-- S067, S071.
GRANT DELETE ON opencast.n_legacy_bridge TO :"runtime_role";
-- S068.
GRANT DELETE ON opencast.n_requester_ticket TO :"runtime_role";
-- S069.
GRANT DELETE ON opencast.n_job_interest TO :"runtime_role";
-- S070.
GRANT DELETE ON opencast.n_interest TO :"runtime_role";
-- S072.
GRANT DELETE ON opencast.n_feed TO :"runtime_role";
-- S111, S116.
GRANT DELETE ON opencast.n_episode_release TO :"runtime_role";
-- S115.
GRANT DELETE ON opencast.n_outbox TO :"runtime_role";
-- S117.
GRANT DELETE ON opencast.n_burst TO :"runtime_role";
-- S125.
GRANT DELETE ON opencast.n_observation TO :"runtime_role";
-- S126.
GRANT DELETE ON opencast.n_snapshot_ref TO :"runtime_role";
-- S127.
GRANT DELETE ON opencast.n_snapshot TO :"runtime_role";
-- S053, S054, S055.
-- failures: S053.
-- state: S053, S054, S055.
-- next_attempt_at: S053, S054.
-- lease_id: S053, S054, S055.
-- lease_until: S053, S054, S055.
-- last_reason: S054, S055.
-- terminal_at: S055.
GRANT UPDATE(failures,last_reason,lease_id,lease_until,next_attempt_at,state,terminal_at) ON opencast.n_delivery TO :"runtime_role";
-- S052, S056, S060.
-- failures: S052.
-- next_attempt_at: S052.
-- lease_id: S052, S056.
-- lease_until: S052, S056.
-- fanout_complete: S056.
-- terminal_at: S056, S060.
-- envelope_json: S056, S060.
GRANT UPDATE(envelope_json,failures,fanout_complete,lease_id,lease_until,next_attempt_at,terminal_at) ON opencast.n_event TO :"runtime_role";
-- S113, S114.
-- state: S113.
-- payload_json: S113, S114.
GRANT UPDATE(payload_json,state) ON opencast.n_outbox TO :"runtime_role";
-- S119, S121.
-- state: S119, S121.
GRANT UPDATE(state) ON opencast.n_snapshot TO :"runtime_role";

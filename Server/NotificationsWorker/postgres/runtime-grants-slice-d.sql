-- Owner-applied delivery authority after the baseline runtime grants.
-- S017/S026/S081: complete event/delivery row reads and joined envelopes.
GRANT SELECT ON opencast.n_event,opencast.n_delivery TO :"runtime_role";
-- S019/S021/S077/S080: job selection, eligibility, attempt and disable trigger.
GRANT SELECT(interest_id,install_id,install_epoch,generation,state,run_id,attempt_started_at)
 ON opencast.n_job_interest TO :"runtime_role";
-- S020/S034: legacy eligibility exclusions.
GRANT SELECT(install_id,feed_id,expires_at,identity_key)
 ON opencast.n_legacy_bridge TO :"runtime_role";
-- S082/S084/S090: endpoint read, invalidation predicate and outcome readback.
GRANT SELECT(install_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,last_seen_at)
 ON opencast.devices TO :"runtime_role";
-- S078/S083/S087/S089: APNs circuit claim, final authority, pause and diagnostic.
GRANT SELECT ON opencast.n_circuit TO :"runtime_role";
GRANT UPDATE(paused,reason,updated_at) ON opencast.n_circuit TO :"runtime_role";
-- S016/S024/S032: fanout claim, page settlement and completion.
GRANT UPDATE(lease_id,lease_until,fanout_cursor,fanout_complete,next_attempt_at,failures)
 ON opencast.n_event TO :"runtime_role";
-- S022/S036: individual and grouped delivery creation.
GRANT INSERT(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,source,event_id,owner_epoch,member_count)
 ON opencast.n_delivery TO :"runtime_role";
-- S023/S038 and S037: membership creation, including existing-delivery retries.
GRANT INSERT ON opencast.n_delivery_member,opencast.n_group_member TO :"runtime_role";
-- S027: burst identity; S028/S033/S039/S040: claim, completion, cursor and failure.
GRANT INSERT(presentation_key,feed_id,owner_epoch) ON opencast.n_burst TO :"runtime_role";
GRANT UPDATE(lease_id,lease_until,complete,cursor,failures,next_attempt_at)
 ON opencast.n_burst TO :"runtime_role";
-- S078/S085/S088, plus S084/S090 -> n_device_update -> n_install_disable.
GRANT UPDATE(state,lease_id,lease_until,attempt,attempt_started_at,attempt_token_generation,stale_410_generation,last_reason,next_attempt_at,terminal_at,failures)
 ON opencast.n_delivery TO :"runtime_role";
-- S079/S086 throttle; S084/S090 invoke n_device_update with invoker privileges.
GRANT UPDATE(next_send_at,token_generation,token_hash,enabled,registration_revision,job_capable,registered_at)
 ON opencast.n_install TO :"runtime_role";
-- S080 attempt start; S084/S090 -> n_install_disable revokes job interests.
GRANT UPDATE(attempt_started_at,state) ON opencast.n_job_interest TO :"runtime_role";
-- S084/S090: guarded token invalidation. The inherited triggers remain intact.
GRANT UPDATE(device_token,notifications_enabled,last_seen_at) ON opencast.devices TO :"runtime_role";
-- S095 candidate drain; S099/S101 expiration and outbox settlement.
GRANT INSERT(feed_id,episode_id,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition)
 ON opencast.n_episode_release TO :"runtime_role";
GRANT UPDATE(state,disposition) ON opencast.n_episode_release TO :"runtime_role";
-- S100 outbox creation; S103-S107 delivery outcome and retry settlement.
GRANT INSERT(source,event_id,observation_id,payload_digest,occurred_at,expires_at,next_attempt_at,state,payload_json)
 ON opencast.n_outbox TO :"runtime_role";
GRANT UPDATE(state,payload_json,next_attempt_at,receipt_id) ON opencast.n_outbox TO :"runtime_role";
-- S096 observation cursor and the shared mutation gate use baseline grants.
-- No DELETE, reference mutation, GC, DDL or whole-table UPDATE is added.

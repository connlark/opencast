-- Apply as owner after the common baseline; runtime_role is the ingress role.
-- Source statement IDs map to the control and ingress contract. No DELETE or GC authority.
-- S041,S046: complete receipt row
GRANT SELECT ON opencast.n_event TO :"runtime_role";
-- S045: admission INSERT target list
GRANT INSERT(source,event_id,schema_version,kind,payload_digest,occurred_at,eligible_at,expires_at,receipt_id,envelope_json,next_attempt_at,disposition,feed_id,interest_id,owner_epoch,fanout_complete,terminal_at) ON opencast.n_event TO :"runtime_role";
-- S042,S044,S047,S048,S049,S051: complete interest readback and mutation fences
GRANT SELECT ON opencast.n_job_interest TO :"runtime_role";
-- S047,S049: registration/cancellation assignment lists
GRANT UPDATE(run_id,job_handle,accepted_at,receipt_id,state,reason,local_fallback_safe) ON opencast.n_job_interest TO :"runtime_role";
-- S050: suppression WHERE predicate
GRANT SELECT(interest_key,state) ON opencast.n_delivery TO :"runtime_role";
-- S050: suppression assignment list
GRANT UPDATE(state,terminal_at,lease_id,lease_until,last_reason) ON opencast.n_delivery TO :"runtime_role";

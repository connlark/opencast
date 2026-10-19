-- Owner-applied additions to the existing runtime grant union; no schema changes.
-- S185 claim and S187 release: exact assignment columns on the singleton.
GRANT UPDATE(cleanup_lease,cleanup_until,cleanup_generation)
 ON opencast.n_poll_dispatch TO :"runtime_role";
-- S186: original retention predicate is bucket < cutoff; no other DELETE added.
GRANT DELETE ON opencast.n_poll_stat TO :"runtime_role";
-- S235 handling_failures/retry_at/last_poll_error: inherited n_feed UPDATE.
-- S236 failures/next_attempt_at/lease_id/lease_until: inherited n_burst columns.
-- S014, S143, S217 and mutation readbacks: inherited SELECT on their tables.

-- S005: DELETE only where updated_at < cutoff; challenge-source bucket retention.
GRANT DELETE ON opencast.app_attest_challenge_source_buckets TO :"runtime_role";
-- S006: created_at < cutoff; app_attest_challenges DELETE inherited from C.
-- S244: created_at < cutoff; push_send_attempts DELETE inherited from C.
-- S251: created_at < cutoff; secure_hello_attempts DELETE inherited from C.
-- S280: created_at < cutoff; feed_admission_attempts DELETE inherited from C.
-- S245: deleted_at IS NOT NULL AND deleted_at < cutoff; feed_subscriptions
-- DELETE inherited from C. Existing subscription/interest triggers are unchanged.

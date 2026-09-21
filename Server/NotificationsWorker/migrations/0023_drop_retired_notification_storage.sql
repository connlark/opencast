-- Deploy both storage-cleanup binaries after 0022, close cleanup admission and
-- drain old invocations before this contract migration. Current GC protects
-- queued roots and shared pages without the retired shadow pointers.
CREATE TABLE n_storage_readiness (remaining INTEGER NOT NULL CHECK(remaining=0));
INSERT INTO n_storage_readiness
SELECT (SELECT COUNT(*) FROM n_feed WHERE owner<>'queued' OR recovery_pending<>0)
     + (SELECT COUNT(*) FROM n_recovery_seed)
     + (SELECT COUNT(*) FROM n_poll)
     + (SELECT COUNT(*) FROM n_origin_permit)
     + (SELECT COUNT(*) FROM n_candidate)
     + (SELECT COUNT(*) FROM n_observation WHERE mode<>'queued')
     + (SELECT COUNT(*) FROM n_episode_release WHERE mode<>'queued' OR state='shadow');
DROP TABLE n_storage_readiness;

DROP TRIGGER n_history_transition_delete;
DROP VIEW episode_notification_sends;
DROP TABLE feed_poll_attempts;
DROP TABLE n_shadow_absence;
DROP TABLE n_shadow_feed;
DROP TABLE n_cutover_receipt;
DROP TABLE n_idle_cutover_receipt;
DROP TABLE n_recovery_cutover_receipt;
DROP TABLE n_recovery_seed;
DROP TABLE n_origin_permit;
DROP TABLE n_poll;
DROP TABLE n_candidate;
ALTER TABLE n_feed DROP COLUMN cutover_token;
ALTER TABLE n_feed DROP COLUMN cutover_paused_at;
ALTER TABLE n_feed DROP COLUMN cohort_bucket;
-- owner/mode/epoch remain current query fences; recovery_pending remains until
-- the external admin reader is updated. No user-history or queued-root deletion.

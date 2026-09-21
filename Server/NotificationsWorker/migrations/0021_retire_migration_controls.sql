-- Deploy the current-only binaries to both Workers before applying this file.
-- Retire audited fixtures first. Never discard outstanding real recovery data.
CREATE TABLE n_cleanup_readiness (remaining INTEGER NOT NULL CHECK(remaining=0));
INSERT INTO n_cleanup_readiness
SELECT (SELECT COUNT(*) FROM n_feed WHERE owner<>'queued' OR recovery_pending<>0)
     + (SELECT COUNT(*) FROM n_recovery_seed);
DROP TABLE n_cleanup_readiness;

DELETE FROM n_control WHERE name IN (
 'legacy_admission','legacy_send','legacy_cleanup',
 'feed_shadow','cutover_admission','cutover_stage','queued_enrollment'
);
-- Historical ledgers, bridge expiry and snapshot roots are unchanged.

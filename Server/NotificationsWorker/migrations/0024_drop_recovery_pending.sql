-- First update and restart every external reader,
-- then verify live dashboard reads. Both Workers must already use the current
-- engine without recovery_pending readers/writers. Do not deploy older code.
-- Check every feed, including dormant and paused identities, in this same
-- migration transaction. A nonzero value aborts the whole migration.
CREATE TABLE n_recovery_field_readiness (
    remaining INTEGER NOT NULL CHECK(remaining=0)
);
INSERT INTO n_recovery_field_readiness
SELECT COUNT(*) FROM n_feed WHERE recovery_pending<>0;
DROP TABLE n_recovery_field_readiness;

ALTER TABLE n_feed DROP COLUMN recovery_pending;
-- No history, snapshot, delivery, schedule, ownership or retention changes.

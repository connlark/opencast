-- Additive and disabled. The Queue message is the poll-attempt lease; n_feed
-- keeps only the schedule/generation state needed to fence that message.
-- dispatch_until>0 marks an uncommitted dispatch generation. Its expiry is a
-- liveness bound for a lost message, never an authority to publish.
ALTER TABLE n_feed ADD COLUMN dispatch_until INTEGER NOT NULL DEFAULT 0;
-- "<snapshot key>:<sha256>" of the published scan's exact identity and
-- fingerprint sets. A binary that publishes without maintaining it moves the
-- snapshot key, which is never reused, so a stale digest can never match.
ALTER TABLE n_feed ADD COLUMN semantic_digest TEXT;
ALTER TABLE n_shadow_feed ADD COLUMN semantic_digest TEXT;
-- The production adaptive policy's own cadence input (median recent gap).
ALTER TABLE n_feed ADD COLUMN publish_cadence INTEGER;
-- Last outcome replaces seven-day terminal poll receipts.
ALTER TABLE n_feed ADD COLUMN last_poll_at INTEGER;
ALTER TABLE n_feed ADD COLUMN last_poll_outcome TEXT;
ALTER TABLE n_feed ADD COLUMN last_poll_error TEXT;
-- Exhausted (dead-lettered) handling backs a feed off without blaming its
-- publisher; any success clears it.
ALTER TABLE n_feed ADD COLUMN handling_failures INTEGER NOT NULL DEFAULT 0;
-- Hourly buckets, written only by failures, redeliveries and rejected commits.
CREATE TABLE n_poll_stat (
 bucket INTEGER PRIMARY KEY,
 publisher_failures INTEGER NOT NULL DEFAULT 0, handling_failures INTEGER NOT NULL DEFAULT 0,
 redeliveries INTEGER NOT NULL DEFAULT 0, dead_letters INTEGER NOT NULL DEFAULT 0,
 stale_commits INTEGER NOT NULL DEFAULT 0, retry_after_clamps INTEGER NOT NULL DEFAULT 0
);
-- n_poll and n_origin_permit receive no new rows. Their tables stay until the
-- last reader and rollback binary are gone; the previous executor still runs
-- without these indexes (measured before the cost reset).
DROP INDEX IF EXISTS n_poll_live;
DROP INDEX IF EXISTS n_poll_due;
DROP INDEX IF EXISTS n_poll_active_feed;
DROP INDEX IF EXISTS n_poll_enqueue;
DROP INDEX IF EXISTS n_origin_permit_expiry;

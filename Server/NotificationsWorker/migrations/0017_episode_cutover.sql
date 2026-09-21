-- Additive cutover authority. New control defaults off; no ownership changes.
ALTER TABLE n_feed ADD COLUMN cutover_token TEXT;
ALTER TABLE n_feed ADD COLUMN cutover_paused_at INTEGER;
ALTER TABLE n_feed ADD COLUMN send_paused INTEGER NOT NULL DEFAULT 0 CHECK(send_paused IN(0,1));
ALTER TABLE n_feed ADD COLUMN cohort_bucket INTEGER NOT NULL DEFAULT -1 CHECK(cohort_bucket BETWEEN -1 AND 99);
INSERT INTO n_control(name,enabled,revision) VALUES('cutover_admission',0,1);
INSERT INTO n_control(name,enabled,revision) VALUES('cutover_stage',0,0);

-- Passive evidence belongs to the current interest generation. Shadow never
-- writes authoritative absence; handoff copies only matching evidence.
CREATE TABLE n_shadow_absence (
 install_id TEXT NOT NULL, feed_id TEXT NOT NULL, interest_generation INTEGER NOT NULL,
 observation_generation INTEGER NOT NULL, observed_at INTEGER NOT NULL,
 PRIMARY KEY(install_id,feed_id),
 FOREIGN KEY(install_id,feed_id) REFERENCES n_interest(install_id,feed_id) ON DELETE CASCADE
);
-- Opaque, per-feed recovery receipt; no URLs, recipient IDs or copied payloads.
CREATE TABLE n_cutover_receipt (
 operation_id TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES n_feed ON DELETE CASCADE,
 from_epoch INTEGER NOT NULL, to_epoch INTEGER NOT NULL,
 snapshot_key TEXT NOT NULL, review_digest TEXT NOT NULL,
 compatibility_version TEXT NOT NULL, completed_at INTEGER NOT NULL,
 cohort_stage INTEGER NOT NULL DEFAULT 0,
 cohort_bucket INTEGER NOT NULL DEFAULT -1 CHECK(cohort_bucket BETWEEN -1 AND 99),
 owned_fixture INTEGER NOT NULL DEFAULT 0 CHECK(owned_fixture IN(0,1))
);
CREATE INDEX n_cutover_receipt_feed ON n_cutover_receipt(feed_id,completed_at);

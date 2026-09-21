-- A failed publisher must not keep the legacy runtime alive. Sparse legacy
-- identities are recovery evidence, never a complete feed snapshot or absence.
ALTER TABLE n_feed ADD COLUMN recovery_pending INTEGER NOT NULL DEFAULT 0 CHECK(recovery_pending IN(0,1));
CREATE TABLE n_recovery_cutover_receipt (
 operation_id TEXT PRIMARY KEY,
 feed_id TEXT NOT NULL REFERENCES n_feed ON DELETE CASCADE,
 from_epoch INTEGER NOT NULL,
 to_epoch INTEGER NOT NULL,
 review_digest TEXT NOT NULL,
 compatibility_version TEXT NOT NULL,
 established_history INTEGER NOT NULL,
 completed_at INTEGER NOT NULL,
 UNIQUE(feed_id,from_epoch)
);
CREATE TABLE n_recovery_seed (
 feed_id TEXT NOT NULL REFERENCES n_feed ON DELETE CASCADE,
 identity_key TEXT NOT NULL,
 PRIMARY KEY(feed_id,identity_key)
);

-- Fresh feed authority can switch only after the explicit retirement gate.
INSERT INTO n_control(name,enabled,revision) VALUES('queued_enrollment',0,1);

-- Idle feeds have no active recipients and require a quiet first baseline on
-- return. Keep a distinct receipt: do not invent a validated snapshot for them.
CREATE TABLE n_idle_cutover_receipt (
 operation_id TEXT PRIMARY KEY,
 feed_id TEXT NOT NULL REFERENCES n_feed ON DELETE CASCADE,
 from_epoch INTEGER NOT NULL,
 to_epoch INTEGER NOT NULL,
 review_digest TEXT NOT NULL,
 compatibility_version TEXT NOT NULL,
 completed_at INTEGER NOT NULL,
 UNIQUE(feed_id,from_epoch)
);

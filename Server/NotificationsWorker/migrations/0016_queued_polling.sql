-- Additive and disabled. Existing clients and the legacy cron keep ownership.
ALTER TABLE n_feed ADD COLUMN schedule_generation INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_feed ADD COLUMN retry_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_feed ADD COLUMN poll_failures INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_feed ADD COLUMN origin_key TEXT;
ALTER TABLE n_feed ADD COLUMN baseline_at INTEGER;
ALTER TABLE n_feed ADD COLUMN credible_release_at INTEGER;
ALTER TABLE n_feed ADD COLUMN credible_cadence INTEGER;
ALTER TABLE n_poll ADD COLUMN eligibility_generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE n_poll ADD COLUMN due_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll ADD COLUMN kind TEXT NOT NULL DEFAULT 'poll';
ALTER TABLE n_poll ADD COLUMN stage TEXT NOT NULL DEFAULT 'scan';
ALTER TABLE n_poll ADD COLUMN prior_publish_token TEXT;
ALTER TABLE n_poll ADD COLUMN enqueued_until INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll ADD COLUMN enqueue_token TEXT;
ALTER TABLE n_poll ADD COLUMN last_error TEXT;
ALTER TABLE n_poll ADD COLUMN completed_at INTEGER;
ALTER TABLE n_poll ADD COLUMN repairs INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll ADD COLUMN scan_lease_id TEXT;
ALTER TABLE n_poll ADD COLUMN poll_completed_at INTEGER;
-- A parked scan/preparation can temporarily drain delivery work without losing
-- its retry deadline, poison state, or the one-live-job-per-feed invariant.
ALTER TABLE n_poll ADD COLUMN resume_stage TEXT;
ALTER TABLE n_poll ADD COLUMN resume_at INTEGER;
ALTER TABLE n_poll ADD COLUMN resume_state TEXT;
CREATE INDEX n_feed_queued_due ON n_feed(owner,admission_paused,retry_at,due_at);
CREATE INDEX n_poll_active_feed ON n_poll(feed_id,state) WHERE state IN('ready','leased','poisoned');
CREATE INDEX n_poll_enqueue ON n_poll(enqueue_token) WHERE enqueue_token IS NOT NULL;
-- Terminal receipts reuse n_poll_due; set next_attempt_at to completion time.
ALTER TABLE n_poll ADD COLUMN scan_busy_retries INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll ADD COLUMN origin_deferred_retries INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll ADD COLUMN lease_reclaims INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll ADD COLUMN stale_commits INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_poll ADD COLUMN retry_after_clamps INTEGER NOT NULL DEFAULT 0;
CREATE INDEX n_observation_age ON n_observation(scan_started_at);
CREATE INDEX n_observation_snapshot ON n_observation(snapshot_key);
CREATE INDEX n_snapshot_lease ON n_snapshot(lease_id);
CREATE INDEX n_feed_snapshot ON n_feed(snapshot_key);
CREATE INDEX n_shadow_feed_snapshot ON n_shadow_feed(snapshot_key);
CREATE TABLE n_poll_origin (
 origin_key TEXT PRIMARY KEY, cooldown_until INTEGER NOT NULL DEFAULT 0,
 failures INTEGER NOT NULL DEFAULT 0, last_status INTEGER, updated_at INTEGER NOT NULL
);
CREATE TABLE n_origin_permit (
 origin_key TEXT NOT NULL REFERENCES n_poll_origin, execution_id TEXT NOT NULL,
 job_id TEXT NOT NULL REFERENCES n_poll, expires_at INTEGER NOT NULL,
 PRIMARY KEY(origin_key,execution_id)
);
CREATE INDEX n_origin_permit_expiry ON n_origin_permit(expires_at);
CREATE TABLE n_poll_dispatch (
 id INTEGER PRIMARY KEY CHECK(id=1), lease_id TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
 cleanup_lease TEXT, cleanup_until INTEGER NOT NULL DEFAULT 0,
 cleanup_generation INTEGER NOT NULL DEFAULT 0
);
INSERT INTO n_poll_dispatch(id) VALUES(1);
INSERT INTO n_control(name,enabled,revision) VALUES('five_minute_polling',0,1);

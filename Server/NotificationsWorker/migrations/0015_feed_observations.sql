-- Disabled complete observations. No feed ownership or live controls change.
INSERT INTO n_control(name,enabled,revision) VALUES('feed_observation',0,1),('feed_shadow',0,1);
ALTER TABLE n_observation ADD COLUMN mode TEXT NOT NULL DEFAULT 'queued' CHECK(mode IN('queued','shadow'));
ALTER TABLE n_observation ADD COLUMN eligibility_generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE n_observation ADD COLUMN etag TEXT;
ALTER TABLE n_observation ADD COLUMN last_modified TEXT;
ALTER TABLE n_observation ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE n_observation ADD COLUMN drain_complete INTEGER NOT NULL DEFAULT 0;
CREATE INDEX n_observation_recovery ON n_observation(feed_id,mode,state,scan_started_at);
CREATE INDEX n_observation_drain ON n_observation(mode,state,drain_complete,completed_at);
-- A shadow never changes n_feed's authoritative checkpoint, lease or interests.
CREATE TABLE n_shadow_feed (
 feed_id TEXT PRIMARY KEY REFERENCES n_feed ON DELETE CASCADE,
 generation INTEGER NOT NULL DEFAULT 0, snapshot_key TEXT,
 lease_id TEXT, lease_until INTEGER, publish_token TEXT,
 etag TEXT, last_modified TEXT, last_success_at INTEGER
);
-- Current pending futures are distinct from immutable historical membership.
CREATE TABLE n_episode_release (
 feed_id TEXT NOT NULL REFERENCES n_feed, episode_id TEXT NOT NULL,
 mode TEXT NOT NULL CHECK(mode IN('queued','shadow')),
 observation_id TEXT NOT NULL REFERENCES n_observation,
 generation INTEGER NOT NULL, owner_epoch INTEGER NOT NULL,
 event_id TEXT NOT NULL, presentation_key TEXT NOT NULL,
 first_observed_at INTEGER NOT NULL, eligible_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL, reason TEXT NOT NULL,
 fingerprint TEXT, published_at INTEGER, metadata_json TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN('pending_future','ready','outboxed','withdrawn','expired','shadow')),
 disposition TEXT, PRIMARY KEY(feed_id,episode_id,mode)
);
CREATE INDEX n_episode_release_due ON n_episode_release(mode,state,eligible_at);
CREATE INDEX n_episode_release_observation ON n_episode_release(observation_id,episode_id);
CREATE INDEX n_snapshot_gc ON n_snapshot(state,gc_after);
ALTER TABLE n_observation ADD COLUMN recovery_evidence INTEGER NOT NULL DEFAULT 1;
-- Recipient cursors serialize immutable presentation membership independently
-- from event acceptance. A delayed event cannot escape as an individual alert.
CREATE TABLE n_burst (
 presentation_key TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES n_feed ON DELETE CASCADE,
 owner_epoch INTEGER NOT NULL, cursor TEXT NOT NULL DEFAULT '',
 lease_id TEXT, lease_until INTEGER, complete INTEGER NOT NULL DEFAULT 0
);
ALTER TABLE n_delivery ADD COLUMN member_count INTEGER NOT NULL DEFAULT 1;
-- Complete-document preparation may span invocations. The feed checkpoint stays
-- unchanged until the final manifest is verified and atomically published.
ALTER TABLE n_observation ADD COLUMN preparation_key TEXT;
ALTER TABLE n_observation ADD COLUMN processing_token TEXT;
ALTER TABLE n_observation ADD COLUMN processing_until INTEGER;
ALTER TABLE n_observation ADD COLUMN processing_failures INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_observation ADD COLUMN processing_next_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_burst ADD COLUMN failures INTEGER NOT NULL DEFAULT 0;
ALTER TABLE n_burst ADD COLUMN next_attempt_at INTEGER NOT NULL DEFAULT 0;
CREATE INDEX n_episode_release_presentation ON n_episode_release(presentation_key,mode,event_id);
CREATE INDEX n_episode_release_expiry ON n_episode_release(expires_at);
CREATE INDEX n_outbox_expiry ON n_outbox(source,expires_at);

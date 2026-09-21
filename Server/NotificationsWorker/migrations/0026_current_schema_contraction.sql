-- Current-schema contraction: update/restart external readers and deploy BOTH Workers
-- using n_feed_catalog without owner/mode, then prove old invocations drained.
-- Keep the expansion in place if that proof is incomplete. Never roll back to
-- code requiring the removed names. No history/root/retention is discarded.
CREATE TABLE n_schema_readiness (remaining INTEGER NOT NULL CHECK(remaining=0));
INSERT INTO n_schema_readiness
SELECT (SELECT COUNT(*) FROM n_feed WHERE owner<>'queued')
     + (SELECT COUNT(*) FROM n_observation WHERE mode<>'queued')
     + (SELECT COUNT(*) FROM n_episode_release WHERE mode<>'queued' OR state='shadow');
DROP TABLE n_schema_readiness;

CREATE TABLE n_catalog_copy_check (remaining INTEGER NOT NULL CHECK(remaining=0));
INSERT INTO n_catalog_copy_check
SELECT (SELECT COUNT(*) FROM (SELECT feed_url,source_url,title,website_url,created_at,updated_at FROM feeds EXCEPT SELECT feed_url,source_url,title,website_url,created_at,updated_at FROM n_feed_catalog))
     + (SELECT COUNT(*) FROM (SELECT feed_url,source_url,title,website_url,created_at,updated_at FROM n_feed_catalog EXCEPT SELECT feed_url,source_url,title,website_url,created_at,updated_at FROM feeds));
-- Compare every still-needed pre-authority admission response too. Already
-- enrolled records use n_feed health, and their old polling fields are inert.
INSERT INTO n_catalog_copy_check
SELECT COUNT(*) FROM feeds c JOIN n_feed_catalog k USING(feed_url)
WHERE NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.canonical_url=c.feed_url)
AND (COALESCE(json_extract(k.admission_health_json,'$.consecutive_failures'),0) IS NOT c.consecutive_failures
 OR json_extract(k.admission_health_json,'$.last_http_status') IS NOT c.last_http_status
 OR json_extract(k.admission_health_json,'$.last_error') IS NOT c.last_error
 OR json_extract(k.admission_health_json,'$.last_polled_at') IS NOT c.last_polled_at);
DROP TABLE n_catalog_copy_check;
DROP TRIGGER n_catalog_from_feeds;
DROP TRIGGER n_catalog_to_feeds;
DROP TABLE feeds;

DROP INDEX n_feed_queued_due;
ALTER TABLE n_feed DROP COLUMN owner;
CREATE INDEX n_feed_due ON n_feed(admission_paused,retry_at,due_at);
DROP INDEX n_observation_recovery;
DROP INDEX n_observation_drain;
ALTER TABLE n_observation DROP COLUMN mode;
CREATE INDEX n_observation_recovery ON n_observation(feed_id,state,scan_started_at);
CREATE INDEX n_observation_drain ON n_observation(state,drain_complete,completed_at);

-- Only this leaf table changes its primary key. Both parents and all their
-- child rows stay in place; defer_foreign_keys does NOT disable CASCADE.
CREATE TABLE n_episode_release_next (
 feed_id TEXT NOT NULL REFERENCES n_feed, episode_id TEXT NOT NULL,
 observation_id TEXT NOT NULL REFERENCES n_observation,
 generation INTEGER NOT NULL, owner_epoch INTEGER NOT NULL,
 event_id TEXT NOT NULL, presentation_key TEXT NOT NULL,
 first_observed_at INTEGER NOT NULL, eligible_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL, reason TEXT NOT NULL,
 fingerprint TEXT, published_at INTEGER, metadata_json TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN('pending_future','ready','outboxed','withdrawn','expired')),
 disposition TEXT, PRIMARY KEY(feed_id,episode_id)
);
INSERT INTO n_episode_release_next(feed_id,episode_id,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition) SELECT feed_id,episode_id,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition FROM n_episode_release;
CREATE TABLE n_release_copy_check (remaining INTEGER NOT NULL CHECK(remaining=0));
INSERT INTO n_release_copy_check
SELECT (SELECT COUNT(*) FROM (SELECT feed_id,episode_id,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition FROM n_episode_release EXCEPT SELECT * FROM n_episode_release_next))
     + (SELECT COUNT(*) FROM (SELECT * FROM n_episode_release_next EXCEPT SELECT feed_id,episode_id,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition FROM n_episode_release));
DROP TABLE n_release_copy_check;
DROP TABLE n_episode_release;
ALTER TABLE n_episode_release_next RENAME TO n_episode_release;
CREATE INDEX n_episode_release_due ON n_episode_release(state,eligible_at);
CREATE INDEX n_episode_release_expiry ON n_episode_release(expires_at);
CREATE INDEX n_episode_release_observation ON n_episode_release(observation_id,episode_id);
CREATE INDEX n_episode_release_presentation ON n_episode_release(presentation_key,event_id);

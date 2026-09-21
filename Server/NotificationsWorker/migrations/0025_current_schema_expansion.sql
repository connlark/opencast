-- Current-schema expansion: apply alone before deploying the current-schema binaries.
-- Inventory EVERY incoming FK/index/trigger first. n_feed has a CASCADE child
-- (n_burst): never DROP/recreate that parent. Column ALTER keeps its identity.
-- n_episode_release has no incoming FK or trigger; it alone is rebuilt below.
CREATE TABLE n_schema_readiness (remaining INTEGER NOT NULL CHECK(remaining=0));
INSERT INTO n_schema_readiness
SELECT (SELECT COUNT(*) FROM n_feed WHERE owner<>'queued')
     + (SELECT COUNT(*) FROM n_observation WHERE mode<>'queued')
     + (SELECT COUNT(*) FROM n_episode_release WHERE mode<>'queued' OR state='shadow');
DROP TABLE n_schema_readiness;

DROP INDEX n_feed_queued_due;
ALTER TABLE n_feed DROP COLUMN owner;
ALTER TABLE n_feed ADD COLUMN owner TEXT NOT NULL DEFAULT 'queued' CHECK(owner='queued');
CREATE INDEX n_feed_queued_due ON n_feed(owner,admission_paused,retry_at,due_at);

-- Both old explicit-mode inserts and new mode-free inserts are valid until
-- contraction. No old shadow/legacy choice is representable after expansion.
CREATE TABLE n_episode_release_next (
 feed_id TEXT NOT NULL REFERENCES n_feed, episode_id TEXT NOT NULL,
 mode TEXT NOT NULL DEFAULT 'queued' CHECK(mode='queued'),
 observation_id TEXT NOT NULL REFERENCES n_observation,
 generation INTEGER NOT NULL, owner_epoch INTEGER NOT NULL,
 event_id TEXT NOT NULL, presentation_key TEXT NOT NULL,
 first_observed_at INTEGER NOT NULL, eligible_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL, reason TEXT NOT NULL,
 fingerprint TEXT, published_at INTEGER, metadata_json TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN('pending_future','ready','outboxed','withdrawn','expired')),
 disposition TEXT, PRIMARY KEY(feed_id,episode_id,mode)
);
INSERT INTO n_episode_release_next(feed_id,episode_id,mode,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition) SELECT feed_id,episode_id,mode,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition FROM n_episode_release;
CREATE TABLE n_release_copy_check (remaining INTEGER NOT NULL CHECK(remaining=0));
INSERT INTO n_release_copy_check
SELECT (SELECT COUNT(*) FROM (SELECT * FROM n_episode_release EXCEPT SELECT * FROM n_episode_release_next))
     + (SELECT COUNT(*) FROM (SELECT * FROM n_episode_release_next EXCEPT SELECT * FROM n_episode_release));
DROP TABLE n_release_copy_check;
DROP TABLE n_episode_release;
ALTER TABLE n_episode_release_next RENAME TO n_episode_release;
CREATE INDEX n_episode_release_due ON n_episode_release(mode,state,eligible_at);
CREATE INDEX n_episode_release_expiry ON n_episode_release(expires_at);
CREATE INDEX n_episode_release_observation ON n_episode_release(observation_id,episode_id);
CREATE INDEX n_episode_release_presentation ON n_episode_release(presentation_key,mode,event_id);

CREATE TABLE n_feed_catalog (
 feed_url TEXT PRIMARY KEY, source_url TEXT NOT NULL, title TEXT, website_url TEXT,
 created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
 admission_health_json TEXT CHECK(admission_health_json IS NULL OR json_valid(admission_health_json))
);
-- A catalog row can precede authority; retained pre-authority admissions do.
-- Preserve its first-sync response snapshot; after enrollment, health comes
-- only from n_feed and the snapshot is cleared in the same transaction.
INSERT INTO n_feed_catalog
SELECT c.feed_url,c.source_url,c.title,c.website_url,c.created_at,c.updated_at,
 CASE WHEN NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.canonical_url=c.feed_url)
 THEN json_object('consecutive_failures',c.consecutive_failures,'last_http_status',c.last_http_status,'last_error',c.last_error,'last_polled_at',c.last_polled_at) END
FROM feeds c;
-- Catalog writes are currently INSERT ... ON CONFLICT DO NOTHING only. The
-- first writer wins in either binary; nested trigger inserts terminate at the
-- primary key. No catalog updates/deletes are exposed during this overlap.
CREATE TRIGGER n_catalog_from_feeds AFTER INSERT ON feeds BEGIN
 INSERT INTO n_feed_catalog(feed_url,source_url,title,website_url,created_at,updated_at)
 VALUES(NEW.feed_url,NEW.source_url,NEW.title,NEW.website_url,NEW.created_at,NEW.updated_at)
 ON CONFLICT(feed_url) DO NOTHING;
END;
CREATE TRIGGER n_catalog_to_feeds AFTER INSERT ON n_feed_catalog BEGIN
 INSERT INTO feeds(feed_url,source_url,title,website_url,poll_interval_seconds,consecutive_failures,created_at,updated_at)
 VALUES(NEW.feed_url,NEW.source_url,NEW.title,NEW.website_url,900,0,NEW.created_at,NEW.updated_at)
 ON CONFLICT(feed_url) DO NOTHING;
END;
CREATE TRIGGER n_catalog_enrolled AFTER INSERT ON n_feed BEGIN
 UPDATE n_feed_catalog SET admission_health_json=NULL WHERE feed_url=NEW.canonical_url AND admission_health_json IS NOT NULL;
END;

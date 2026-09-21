-- Expand before deploying the storage-cleanup binaries. Rename preserves every
-- historical value and constraint; it does not restart delivery or retention.
CREATE TABLE n_history_readiness (remaining INTEGER NOT NULL CHECK(remaining=0));
INSERT INTO n_history_readiness
SELECT (SELECT COUNT(*) FROM n_delivery WHERE source='legacy' AND state IN('pending','leased','uncertain','poisoned'))
     + (SELECT COUNT(*) FROM n_event WHERE source='legacy' AND fanout_complete=0);
DROP TABLE n_history_readiness;
DROP TRIGGER n_legacy_outcome;
ALTER TABLE episode_notification_sends RENAME TO n_delivery_history;
DROP INDEX idx_episode_notification_sends_feed_episode;
DROP INDEX idx_episode_notification_sends_feed_fingerprint;
DROP INDEX idx_episode_notification_sends_pending_created_at;
CREATE INDEX n_delivery_history_feed_episode ON n_delivery_history(feed_url,episode_id);
CREATE UNIQUE INDEX n_delivery_history_fingerprint
 ON n_delivery_history(install_id,device_token_hash,feed_url,episode_fingerprint)
 WHERE episode_fingerprint IS NOT NULL;

-- Recreate explicitly: SQLite builds differ in whether ALTER RENAME rewrites
-- references inside triggers attached to other tables.
DROP TRIGGER n_feed_insert;
CREATE TRIGGER n_feed_insert AFTER INSERT ON n_feed BEGIN
 INSERT OR IGNORE INTO n_interest(install_id,feed_id,generation,activated_at,enabled,changed_at)
 SELECT s.install_id,NEW.feed_id,1,s.created_at, CASE WHEN s.deleted_at IS NULL THEN s.notifications_enabled ELSE 0 END ,s.updated_at
 FROM feed_subscriptions s JOIN n_install i ON i.install_id=s.install_id WHERE s.feed_url=NEW.canonical_url;
 UPDATE n_feed SET no_interest_since=NEW.due_at WHERE feed_id=NEW.feed_id AND NOT EXISTS(SELECT 1 FROM n_interest WHERE feed_id=NEW.feed_id AND enabled=1);
 INSERT INTO n_legacy_bridge(install_id,feed_id,identity_key,disposition,expires_at)
 SELECT install_id,NEW.feed_id,'episode:'||episode_id, CASE WHEN MAX(COALESCE(apns_status=200,0))=1 THEN 'accepted' WHEN MAX(apns_status IS NULL AND apns_error IS NULL)=1 THEN 'uncertain' ELSE 'suppressed' END ,MAX(updated_at)+2592000 FROM n_delivery_history
 WHERE feed_url=NEW.canonical_url GROUP BY install_id,episode_id ON CONFLICT DO NOTHING;
 INSERT INTO n_legacy_bridge(install_id,feed_id,identity_key,disposition,expires_at)
 SELECT install_id,NEW.feed_id,'fingerprint:v2:'||episode_fingerprint, CASE WHEN MAX(COALESCE(apns_status=200,0))=1 THEN 'accepted' WHEN MAX(apns_status IS NULL AND apns_error IS NULL)=1 THEN 'uncertain' ELSE 'suppressed' END ,MAX(updated_at)+2592000 FROM n_delivery_history
 WHERE feed_url=NEW.canonical_url AND episode_fingerprint IS NOT NULL GROUP BY install_id,episode_fingerprint ON CONFLICT DO NOTHING;
END;

-- Only the still-deployed binary's installation erasure needs this temporary
-- name. Both reads and deletes reach the same rows; no dual-write window.
-- 0023 removes the view/trigger after both new binaries have replaced it.
CREATE VIEW episode_notification_sends AS SELECT * FROM n_delivery_history;
CREATE TRIGGER n_history_transition_delete INSTEAD OF DELETE ON episode_notification_sends
BEGIN
 DELETE FROM n_delivery_history WHERE send_id=OLD.send_id;
END;

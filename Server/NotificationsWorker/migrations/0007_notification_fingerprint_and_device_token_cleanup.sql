ALTER TABLE episode_notification_sends ADD COLUMN episode_fingerprint TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_episode_notification_sends_feed_fingerprint
  ON episode_notification_sends (install_id, device_token_hash, feed_url, episode_fingerprint)
  WHERE episode_fingerprint IS NOT NULL;

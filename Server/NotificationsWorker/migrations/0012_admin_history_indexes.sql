CREATE INDEX IF NOT EXISTS idx_feed_poll_attempts_started_at
  ON feed_poll_attempts (started_at);

CREATE INDEX IF NOT EXISTS idx_feed_admission_attempts_created_at
  ON feed_admission_attempts (created_at);

CREATE INDEX IF NOT EXISTS idx_episode_notification_sends_pending_created_at
  ON episode_notification_sends (created_at)
  WHERE apns_status IS NULL AND apns_error IS NULL;

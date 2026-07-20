CREATE INDEX IF NOT EXISTS idx_feeds_next_poll_at
  ON feeds (next_poll_at);

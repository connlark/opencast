CREATE TABLE IF NOT EXISTS feeds (
  feed_url TEXT PRIMARY KEY,
  source_url TEXT NOT NULL,
  title TEXT,
  website_url TEXT,
  etag TEXT,
  last_modified TEXT,
  latest_episode_id TEXT,
  latest_episode_title TEXT,
  latest_episode_published_at INTEGER,
  baseline_established_at INTEGER,
  last_polled_at INTEGER,
  next_poll_at INTEGER,
  poll_interval_seconds INTEGER NOT NULL,
  consecutive_failures INTEGER NOT NULL,
  last_http_status INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS feed_subscriptions (
  install_id TEXT NOT NULL,
  feed_url TEXT NOT NULL,
  notifications_enabled INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  PRIMARY KEY (install_id, feed_url)
);

CREATE INDEX IF NOT EXISTS idx_feed_subscriptions_feed_enabled
  ON feed_subscriptions (feed_url, notifications_enabled, deleted_at);

CREATE TABLE IF NOT EXISTS feed_poll_attempts (
  attempt_id TEXT PRIMARY KEY,
  feed_url TEXT NOT NULL,
  http_status INTEGER,
  changed INTEGER NOT NULL,
  new_episode_id TEXT,
  error_code TEXT,
  started_at INTEGER NOT NULL,
  finished_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_feed_poll_attempts_feed_started
  ON feed_poll_attempts (feed_url, started_at);

CREATE TABLE IF NOT EXISTS episode_notification_sends (
  send_id TEXT PRIMARY KEY,
  install_id TEXT NOT NULL,
  device_token_hash TEXT NOT NULL,
  feed_url TEXT NOT NULL,
  episode_id TEXT NOT NULL,
  apns_environment TEXT NOT NULL,
  apns_status INTEGER,
  apns_id TEXT,
  apns_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (install_id, device_token_hash, feed_url, episode_id)
);

CREATE INDEX IF NOT EXISTS idx_episode_notification_sends_feed_episode
  ON episode_notification_sends (feed_url, episode_id);

CREATE TABLE IF NOT EXISTS feed_admission_attempts (
  attempt_id TEXT PRIMARY KEY,
  install_id TEXT NOT NULL,
  key_id TEXT NOT NULL,
  host TEXT,
  accepted INTEGER NOT NULL,
  error_code TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_feed_admission_attempts_install_created
  ON feed_admission_attempts (install_id, created_at);

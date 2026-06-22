CREATE TABLE IF NOT EXISTS devices (
  install_id TEXT NOT NULL,
  key_id TEXT NOT NULL,
  device_token TEXT NOT NULL,
  device_token_hash TEXT NOT NULL,
  apns_environment TEXT NOT NULL,
  bundle_id TEXT NOT NULL,
  notifications_enabled INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  PRIMARY KEY (install_id, device_token_hash)
);

CREATE INDEX IF NOT EXISTS idx_devices_install
  ON devices (install_id);

CREATE TABLE IF NOT EXISTS push_send_attempts (
  attempt_id TEXT PRIMARY KEY,
  install_id TEXT,
  device_token_hash TEXT,
  apns_environment TEXT NOT NULL,
  apns_status INTEGER,
  apns_id TEXT,
  apns_error TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_push_send_attempts_created_at
  ON push_send_attempts (created_at);

CREATE TABLE IF NOT EXISTS app_attest_challenges (
  challenge_id TEXT PRIMARY KEY,
  challenge_hash TEXT NOT NULL,
  purpose TEXT NOT NULL,
  install_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_app_attest_challenges_lookup
  ON app_attest_challenges (install_id, purpose, expires_at, consumed_at);

CREATE TABLE IF NOT EXISTS app_attest_keys (
  install_id TEXT NOT NULL,
  key_id TEXT NOT NULL,
  public_key BLOB NOT NULL,
  sign_counter INTEGER NOT NULL DEFAULT 0,
  app_id TEXT NOT NULL,
  environment TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  PRIMARY KEY (install_id, key_id)
);

CREATE INDEX IF NOT EXISTS idx_app_attest_keys_install
  ON app_attest_keys (install_id);

CREATE TABLE IF NOT EXISTS secure_hello_attempts (
  attempt_id TEXT PRIMARY KEY,
  install_id TEXT,
  key_id TEXT,
  accepted INTEGER NOT NULL,
  error_code TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_secure_hello_attempts_created_at
  ON secure_hello_attempts (created_at);

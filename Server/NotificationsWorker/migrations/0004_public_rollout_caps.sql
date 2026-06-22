CREATE INDEX IF NOT EXISTS idx_app_attest_challenges_install_created
  ON app_attest_challenges (install_id, created_at);

CREATE INDEX IF NOT EXISTS idx_app_attest_keys_install_created
  ON app_attest_keys (install_id, created_at);

CREATE INDEX IF NOT EXISTS idx_feed_admission_attempts_host_created
  ON feed_admission_attempts (host, accepted, created_at);

CREATE INDEX IF NOT EXISTS idx_feed_admission_attempts_global_created
  ON feed_admission_attempts (accepted, created_at);

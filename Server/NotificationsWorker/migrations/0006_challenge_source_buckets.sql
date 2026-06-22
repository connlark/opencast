CREATE TABLE IF NOT EXISTS app_attest_challenge_source_buckets (
  source_token TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  request_count INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (source_token, window_start)
);

CREATE INDEX IF NOT EXISTS idx_app_attest_challenge_source_buckets_updated
  ON app_attest_challenge_source_buckets (updated_at);

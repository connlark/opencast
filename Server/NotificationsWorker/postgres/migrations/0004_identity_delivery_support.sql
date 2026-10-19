-- Complete the application tables from frozen D1 schema 0030.
-- Apply once as owner after 0001, A grants to both roles, 0002, B grants, 0003.
-- INTEGER -> BIGINT; BLOB -> BYTEA; preserve exact TEXT, defaults and keys.
-- These nine tables have no CHECKs, foreign keys or triggers in frozen 0030.
-- Key constraints create their indexes. No runtime grants.
-- Preserve the sole seed from D1 migration 0014; paused/reason use defaults.
BEGIN;

CREATE TABLE opencast.app_attest_challenge_source_buckets (
  source_token TEXT NOT NULL,
  window_start BIGINT NOT NULL,
  request_count BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (source_token, window_start)
);

CREATE TABLE opencast.app_attest_challenges (
  challenge_id TEXT PRIMARY KEY,
  challenge_hash TEXT NOT NULL,
  purpose TEXT NOT NULL,
  install_id TEXT NOT NULL,
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL,
  consumed_at BIGINT
);

CREATE TABLE opencast.app_attest_keys (
  install_id TEXT NOT NULL,
  key_id TEXT NOT NULL,
  public_key BYTEA NOT NULL,
  sign_counter BIGINT NOT NULL DEFAULT 0,
  app_id TEXT NOT NULL,
  environment TEXT NOT NULL,
  created_at BIGINT NOT NULL,
  last_used_at BIGINT NOT NULL,
  PRIMARY KEY (install_id, key_id)
);

CREATE TABLE opencast.feed_admission_attempts (
  attempt_id TEXT PRIMARY KEY,
  install_id TEXT NOT NULL,
  key_id TEXT NOT NULL,
  host TEXT,
  accepted BIGINT NOT NULL,
  error_code TEXT,
  created_at BIGINT NOT NULL
);

CREATE TABLE opencast.n_circuit (lane TEXT PRIMARY KEY, paused BIGINT NOT NULL DEFAULT 0, reason TEXT, updated_at BIGINT NOT NULL);

CREATE TABLE opencast.n_deleted_install(fence TEXT PRIMARY KEY, expires_at BIGINT NOT NULL);

CREATE TABLE opencast.n_requester_ticket (
 ticket_digest TEXT PRIMARY KEY, producer TEXT NOT NULL, operation_id TEXT NOT NULL, requester_ref TEXT NOT NULL,
 issued_at BIGINT NOT NULL, expires_at BIGINT NOT NULL, environment TEXT NOT NULL
);

CREATE TABLE opencast.push_send_attempts (
  attempt_id TEXT PRIMARY KEY,
  install_id TEXT,
  device_token_hash TEXT,
  apns_environment TEXT NOT NULL,
  apns_status BIGINT,
  apns_id TEXT,
  apns_error TEXT,
  created_at BIGINT NOT NULL
);

CREATE TABLE opencast.secure_hello_attempts (
  attempt_id TEXT PRIMARY KEY,
  install_id TEXT,
  key_id TEXT,
  accepted BIGINT NOT NULL,
  error_code TEXT,
  created_at BIGINT NOT NULL
);

CREATE INDEX idx_app_attest_challenge_source_buckets_updated
  ON opencast.app_attest_challenge_source_buckets (updated_at);
CREATE INDEX idx_app_attest_challenges_created
  ON opencast.app_attest_challenges (created_at);
CREATE INDEX idx_app_attest_challenges_install_created
  ON opencast.app_attest_challenges (install_id, created_at);
CREATE INDEX idx_app_attest_challenges_lookup
  ON opencast.app_attest_challenges (install_id, purpose, expires_at, consumed_at);
CREATE INDEX idx_app_attest_keys_install
  ON opencast.app_attest_keys (install_id);
CREATE INDEX idx_app_attest_keys_install_created
  ON opencast.app_attest_keys (install_id, created_at);
CREATE INDEX idx_feed_admission_attempts_created_at
  ON opencast.feed_admission_attempts (created_at);
CREATE INDEX idx_feed_admission_attempts_global_created
  ON opencast.feed_admission_attempts (accepted, created_at);
CREATE INDEX idx_feed_admission_attempts_host_created
  ON opencast.feed_admission_attempts (host, accepted, created_at);
CREATE INDEX idx_feed_admission_attempts_install_created
  ON opencast.feed_admission_attempts (install_id, created_at);
CREATE INDEX idx_push_send_attempts_created_at
  ON opencast.push_send_attempts (created_at);
CREATE INDEX idx_push_send_attempts_install
  ON opencast.push_send_attempts (install_id);
CREATE INDEX idx_secure_hello_attempts_created_at
  ON opencast.secure_hello_attempts (created_at);
CREATE INDEX idx_secure_hello_attempts_install
  ON opencast.secure_hello_attempts (install_id);

INSERT INTO opencast.n_circuit(lane,updated_at) VALUES('apns',0);

COMMIT;

-- Write-behind mirror of the TrialLedger Durable Object for ops readback.
-- The object's own storage is the truth; these rows can lag it. Every
-- column is a number, a closed enum, a month key or a SHA-256 hash (of the
-- install id, the bearer token or the run id): nothing from a request or a
-- provider reply is ever written here.

CREATE TABLE IF NOT EXISTS trial_install (
  subject TEXT PRIMARY KEY,
  trial_units_used INTEGER NOT NULL,
  open_runs INTEGER NOT NULL,
  version INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS trial_run (
  subject TEXT NOT NULL,
  run_id TEXT NOT NULL,
  feature TEXT NOT NULL,
  windows INTEGER NOT NULL,
  reservations INTEGER NOT NULL,
  reserved_input_tokens INTEGER NOT NULL,
  charged_micros INTEGER NOT NULL,
  unit_consumed INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  version INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (subject, run_id)
);

CREATE INDEX IF NOT EXISTS idx_trial_run_updated
  ON trial_run (updated_at);

CREATE TABLE IF NOT EXISTS trial_month (
  month TEXT PRIMARY KEY,
  charged_micros INTEGER NOT NULL,
  overrun_micros INTEGER NOT NULL,
  reservations INTEGER NOT NULL,
  paused_at INTEGER,
  version INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS trial_day (
  day INTEGER PRIMARY KEY,
  admitted INTEGER NOT NULL,
  input_tokens INTEGER NOT NULL,
  would_refuse_runs INTEGER NOT NULL,
  forwards INTEGER NOT NULL,
  provider_failures INTEGER NOT NULL,
  expired INTEGER NOT NULL,
  overruns INTEGER NOT NULL,
  overrun_micros INTEGER NOT NULL,
  version INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Dev-lane account identity: one opaque account per registered App Attest
-- install (pass 0). The versioned bootstrap wire shape already carries an
-- optional app-transaction JWS; real appTransactionID identity replaces this
-- keying in the purchase pass.
CREATE TABLE IF NOT EXISTS accounts (
  account_id TEXT PRIMARY KEY,
  install_id TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Job index for relaunch recovery and duplicate-submit mapping. The
-- TranscriptionJob DO remains the state authority; this is a lookup table.
CREATE TABLE IF NOT EXISTS jobs (
  job_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  client_request_id TEXT NOT NULL,
  episode_id TEXT NOT NULL,
  state TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (account_id, client_request_id)
);

CREATE INDEX IF NOT EXISTS idx_jobs_account_state
  ON jobs (account_id, state, updated_at);

-- DevCreditAuthority ledger (development lane only). Integer seconds.
-- Single-statement conditional updates keep reserve/settle/release atomic;
-- reservations are idempotent by job_id.
CREATE TABLE IF NOT EXISTS dev_credit_accounts (
  account_id TEXT PRIMARY KEY,
  available_seconds INTEGER NOT NULL,
  reserved_seconds INTEGER NOT NULL DEFAULT 0,
  consumed_seconds INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK (available_seconds >= 0),
  CHECK (reserved_seconds >= 0),
  CHECK (consumed_seconds >= 0)
);

CREATE TABLE IF NOT EXISTS dev_credit_reservations (
  job_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  reserved_seconds INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('reserved', 'settled', 'released')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dev_credit_reservations_account
  ON dev_credit_reservations (account_id, state);

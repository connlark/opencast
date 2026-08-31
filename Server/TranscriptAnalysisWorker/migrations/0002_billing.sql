-- Pay-gate billing surfaces.
--
-- install_account_links: this worker's authoritative install→account
-- resolution for charged routes, written ONLY by a verified bootstrap
-- (RTW migration 0004 precedent — PurchaseWorker keeps its own write-only
-- audit copy keyed by the namespaced install_key). Several installs may
-- share one purchase account (same Apple identity on a second device).
CREATE TABLE IF NOT EXISTS install_account_links (
  install_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_install_account_links_account
  ON install_account_links (account_id);

-- Development-lane credit fake (CREDIT_BACKEND=dev only; config validation
-- forbids it anywhere else). Real reserve/settle/release semantics against
-- D1 so the billing state machine is exercised honestly without
-- PurchaseWorker (RTW migration 0002 precedent).
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

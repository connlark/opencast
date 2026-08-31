-- Operations floor. These rows are content-free aggregates only;
-- PurchaseAccount Durable Objects remain the sole balance authority.

CREATE TABLE IF NOT EXISTS liability_snapshots (
    snapshot_id INTEGER PRIMARY KEY AUTOINCREMENT,
    lane TEXT NOT NULL,
    captured_at INTEGER NOT NULL,
    account_count INTEGER NOT NULL,
    accounts_sampled INTEGER NOT NULL,
    outstanding_seconds INTEGER NOT NULL,
    debt_seconds INTEGER NOT NULL,
    error_accounts INTEGER NOT NULL,
    complete INTEGER NOT NULL CHECK (complete IN (0, 1))
);

CREATE INDEX IF NOT EXISTS idx_liability_snapshots_captured
    ON liability_snapshots (captured_at DESC);

CREATE TABLE IF NOT EXISTS purchase_ops_counters (
    name TEXT PRIMARY KEY,
    value INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
);

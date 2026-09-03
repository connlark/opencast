-- Liability sweep paging. The six-hour cron reads one page of account DOs per
-- invocation and carries the cursor plus running totals here; the snapshot
-- row is written when a page comes back short. Content-free aggregates only —
-- PurchaseAccount Durable Objects remain the sole balance authority.

CREATE TABLE IF NOT EXISTS liability_sweep_state (
    sweep_key INTEGER PRIMARY KEY CHECK (sweep_key = 1),
    cursor TEXT,
    started_at INTEGER NOT NULL,
    accounts_sampled INTEGER NOT NULL DEFAULT 0,
    outstanding_seconds INTEGER NOT NULL DEFAULT 0,
    debt_seconds INTEGER NOT NULL DEFAULT 0,
    error_accounts INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
);

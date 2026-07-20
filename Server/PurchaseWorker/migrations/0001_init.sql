-- Purchase D1: cross-account indexes and notification/reconciliation work
-- only. The PurchaseAccount DO is the sole balance authority; no monetary
-- balance is ever duplicated here.

CREATE TABLE IF NOT EXISTS purchase_accounts (
    app_tx_hmac TEXT PRIMARY KEY,
    account_id TEXT NOT NULL UNIQUE,
    app_transaction_id_encrypted TEXT NOT NULL,
    environment TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS app_account_token_index (
    app_account_token TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS transaction_index (
    transaction_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    environment TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

-- Routing index so settle/release can find the owning account DO from a bare
-- job_id (keeps the gateway credit seam identical to DevCreditAuthority).
CREATE TABLE IF NOT EXISTS reservation_index (
    job_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS notification_receipts (
    notification_uuid TEXT PRIMARY KEY,
    payload_sha256 TEXT NOT NULL,
    notification_type TEXT NOT NULL,
    subtype TEXT,
    environment TEXT NOT NULL,
    transaction_id TEXT,
    account_id TEXT,
    state TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    error_code TEXT,
    first_seen_at INTEGER NOT NULL,
    processed_at INTEGER
);

CREATE TABLE IF NOT EXISTS reconciliation_state (
    account_id TEXT PRIMARY KEY,
    environment TEXT NOT NULL,
    revision_cursor TEXT,
    last_success_at INTEGER,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    error_code TEXT,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS install_account_links (
    install_key TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    last_verified_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_reconciliation_due
    ON reconciliation_state (next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_notification_receipts_state
    ON notification_receipts (state, first_seen_at);

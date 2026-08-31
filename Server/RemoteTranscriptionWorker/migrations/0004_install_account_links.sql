-- Purchase-backend install→account links. Unlike the development
-- `accounts` table (one install per account), several installs may share one
-- purchase account — the same Apple Account bootstrapping from a second
-- device maps to the same appTransactionID-derived account. Links are
-- established only by a verified bootstrap; job routes never auto-create.
CREATE TABLE IF NOT EXISTS install_account_links (
  install_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_install_account_links_account
  ON install_account_links (account_id);

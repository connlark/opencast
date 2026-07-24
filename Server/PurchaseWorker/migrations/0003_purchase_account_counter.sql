-- Backfill once so the six-hour liability snapshot can read one counter row
-- instead of repeatedly scanning every purchase account.
INSERT INTO purchase_ops_counters (name, value, updated_at)
SELECT 'purchase_account_count', COUNT(*), 0
FROM purchase_accounts
WHERE 1
ON CONFLICT(name) DO UPDATE SET
  value = excluded.value,
  updated_at = excluded.updated_at;

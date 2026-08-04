// Purchase D1 access: cross-account indexes and notification/reconciliation
// bookkeeping. Never balances — the Account DO owns money.

export interface PurchaseAccountRow {
  app_tx_hmac: string;
  account_id: string;
  app_transaction_id_encrypted: string;
  environment: string;
  status: string;
}

export async function accountByHmac(
  db: D1Database,
  appTxHmac: string,
): Promise<PurchaseAccountRow | null> {
  const row = await db
    .prepare(
      `SELECT app_tx_hmac, account_id, app_transaction_id_encrypted, environment, status
       FROM purchase_accounts WHERE app_tx_hmac = ?1`,
    )
    .bind(appTxHmac)
    .first<PurchaseAccountRow>();
  return row ?? null;
}

export async function accountById(
  db: D1Database,
  accountId: string,
): Promise<PurchaseAccountRow | null> {
  const row = await db
    .prepare(
      `SELECT app_tx_hmac, account_id, app_transaction_id_encrypted, environment, status
       FROM purchase_accounts WHERE account_id = ?1`,
    )
    .bind(accountId)
    .first<PurchaseAccountRow>();
  return row ?? null;
}

/**
 * Insert-or-return: the unique HMAC index arbitrates concurrent bootstraps of
 * the same Apple identity; whoever loses the insert adopts the winner's row.
 */
export async function ensureAccount(
  db: D1Database,
  candidate: PurchaseAccountRow,
  now: number,
): Promise<PurchaseAccountRow> {
  const insertAccount = db
    .prepare(
      `INSERT INTO purchase_accounts (app_tx_hmac, account_id, app_transaction_id_encrypted, environment, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, 'active', ?5, ?5)
       ON CONFLICT (app_tx_hmac) DO NOTHING`,
    )
    .bind(
      candidate.app_tx_hmac,
      candidate.account_id,
      candidate.app_transaction_id_encrypted,
      candidate.environment,
      now,
    );
  const incrementAccountCount = db
    .prepare(
      `INSERT INTO purchase_ops_counters (name, value, updated_at)
       SELECT 'purchase_account_count', 1, ?1
       WHERE changes() = 1
       ON CONFLICT(name) DO UPDATE SET
         value = purchase_ops_counters.value + 1,
         updated_at = excluded.updated_at`,
    )
    .bind(now);
  await db.batch([insertAccount, incrementAccountCount]);
  const winner = await accountByHmac(db, candidate.app_tx_hmac);
  if (!winner) {
    throw new Error('purchase account insert did not persist');
  }
  return winner;
}

export async function upsertTokenIndex(
  db: D1Database,
  token: string,
  accountId: string,
  now: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO app_account_token_index (app_account_token, account_id, created_at)
       VALUES (?1, ?2, ?3)
       ON CONFLICT (app_account_token) DO NOTHING`,
    )
    .bind(token, accountId, now)
    .run();
}

export async function accountForToken(db: D1Database, token: string): Promise<string | null> {
  const row = await db
    .prepare(`SELECT account_id FROM app_account_token_index WHERE app_account_token = ?1`)
    .bind(token)
    .first<{ account_id: string }>();
  return row?.account_id ?? null;
}

/** Returns the owning account, inserting the mapping when new. */
export async function claimTransaction(
  db: D1Database,
  transactionId: string,
  accountId: string,
  environment: string,
  now: number,
): Promise<string> {
  await db
    .prepare(
      `INSERT INTO transaction_index (transaction_id, account_id, environment, created_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT (transaction_id) DO NOTHING`,
    )
    .bind(transactionId, accountId, environment, now)
    .run();
  const row = await db
    .prepare(`SELECT account_id FROM transaction_index WHERE transaction_id = ?1`)
    .bind(transactionId)
    .first<{ account_id: string }>();
  if (!row) {
    throw new Error('transaction index insert did not persist');
  }
  return row.account_id;
}

export async function accountForTransaction(
  db: D1Database,
  transactionId: string,
): Promise<string | null> {
  const row = await db
    .prepare(`SELECT account_id FROM transaction_index WHERE transaction_id = ?1`)
    .bind(transactionId)
    .first<{ account_id: string }>();
  return row?.account_id ?? null;
}

export async function upsertReservationIndex(
  db: D1Database,
  jobId: string,
  accountId: string,
  now: number,
): Promise<string> {
  await db
    .prepare(
      `INSERT INTO reservation_index (job_id, account_id, created_at)
       VALUES (?1, ?2, ?3)
       ON CONFLICT (job_id) DO NOTHING`,
    )
    .bind(jobId, accountId, now)
    .run();
  // Read back the owner: DO NOTHING keeps the first writer, so a caller
  // must learn when the job id is already pinned to a different account
  // (PW-2) instead of silently routing settle/release to the first writer.
  const row = await db
    .prepare(`SELECT account_id FROM reservation_index WHERE job_id = ?1`)
    .bind(jobId)
    .first<{ account_id: string }>();
  return row?.account_id ?? accountId;
}

export async function accountForReservation(
  db: D1Database,
  jobId: string,
): Promise<string | null> {
  const row = await db
    .prepare(`SELECT account_id FROM reservation_index WHERE job_id = ?1`)
    .bind(jobId)
    .first<{ account_id: string }>();
  return row?.account_id ?? null;
}

export async function upsertInstallLink(
  db: D1Database,
  installKey: string,
  accountId: string,
  now: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO install_account_links (install_key, account_id, last_verified_at, created_at)
       VALUES (?1, ?2, ?3, ?3)
       ON CONFLICT (install_key) DO UPDATE SET
         account_id = excluded.account_id,
         last_verified_at = excluded.last_verified_at`,
    )
    .bind(installKey, accountId, now)
    .run();
}

export interface NotificationReceipt {
  notification_uuid: string;
  state: string;
  attempts: number;
}

export async function notificationReceipt(
  db: D1Database,
  uuid: string,
): Promise<NotificationReceipt | null> {
  const row = await db
    .prepare(
      `SELECT notification_uuid, state, attempts FROM notification_receipts WHERE notification_uuid = ?1`,
    )
    .bind(uuid)
    .first<NotificationReceipt>();
  return row ?? null;
}

export async function recordNotificationAttempt(
  db: D1Database,
  fields: {
    uuid: string;
    payloadSha256: string;
    notificationType: string;
    subtype: string | null;
    environment: string;
    transactionId: string | null;
    accountId: string | null;
  },
  now: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO notification_receipts (notification_uuid, payload_sha256, notification_type, subtype, environment,
         transaction_id, account_id, state, attempts, first_seen_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'processing', 1, ?8)
       ON CONFLICT (notification_uuid) DO UPDATE SET
         attempts = notification_receipts.attempts + 1,
         transaction_id = COALESCE(excluded.transaction_id, notification_receipts.transaction_id),
         account_id = COALESCE(excluded.account_id, notification_receipts.account_id)`,
    )
    .bind(
      fields.uuid,
      fields.payloadSha256,
      fields.notificationType,
      fields.subtype,
      fields.environment,
      fields.transactionId,
      fields.accountId,
      now,
    )
    .run();
}

export async function finishNotification(
  db: D1Database,
  uuid: string,
  state: 'processed' | 'recorded' | 'unmatched' | 'unsupported' | 'failed',
  errorCode: string | null,
  now: number,
  accountId?: string | null,
  transactionId?: string | null,
): Promise<void> {
  await db
    .prepare(
      `UPDATE notification_receipts
       SET state = ?2, error_code = ?3, processed_at = ?4,
           account_id = COALESCE(?5, account_id),
           transaction_id = COALESCE(?6, transaction_id)
       WHERE notification_uuid = ?1`,
    )
    .bind(uuid, state, errorCode, now, accountId ?? null, transactionId ?? null)
    .run();
}

export interface ReconciliationRow {
  account_id: string;
  environment: string;
  revision_cursor: string | null;
}

export async function reconciliationDue(
  db: D1Database,
  now: number,
  limit: number,
): Promise<ReconciliationRow[]> {
  const rows = await db
    .prepare(
      `SELECT account_id, environment, revision_cursor FROM reconciliation_state
       WHERE next_attempt_at <= ?1 ORDER BY next_attempt_at ASC LIMIT ?2`,
    )
    .bind(now, limit)
    .all<ReconciliationRow>();
  return rows.results ?? [];
}

export async function scheduleReconciliation(
  db: D1Database,
  accountId: string,
  environment: string,
  nextAttemptAt: number,
  now: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO reconciliation_state (account_id, environment, next_attempt_at, updated_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT (account_id) DO NOTHING`,
    )
    .bind(accountId, environment, nextAttemptAt, now)
    .run();
}

export async function finishReconciliation(
  db: D1Database,
  accountId: string,
  outcome: { cursor: string | null; errorCode: string | null; nextAttemptAt: number },
  now: number,
): Promise<void> {
  await db
    .prepare(
      `UPDATE reconciliation_state
       SET revision_cursor = ?2, error_code = ?3, next_attempt_at = ?4, updated_at = ?5,
           last_success_at = CASE WHEN ?3 IS NULL THEN ?5 ELSE last_success_at END
       WHERE account_id = ?1`,
    )
    .bind(accountId, outcome.cursor, outcome.errorCode, outcome.nextAttemptAt, now)
    .run();
}

export async function purchaseAccountCount(db: D1Database): Promise<number> {
  const row = await db
    .prepare(`SELECT value FROM purchase_ops_counters WHERE name = 'purchase_account_count'`)
    .first<{ value: number }>();
  return Number(row?.value ?? 0);
}

export async function purchaseAccountIds(db: D1Database, limit: number): Promise<string[]> {
  const rows = await db
    .prepare(`SELECT account_id FROM purchase_accounts ORDER BY account_id ASC LIMIT ?1`)
    .bind(limit)
    .all<{ account_id: string }>();
  return (rows.results ?? []).map((row) => row.account_id);
}

export interface LiabilitySnapshotRow {
  lane: string;
  captured_at: number;
  account_count: number;
  accounts_sampled: number;
  outstanding_seconds: number;
  debt_seconds: number;
  error_accounts: number;
  complete: boolean;
}

export async function recordLiabilitySnapshot(
  db: D1Database,
  snapshot: LiabilitySnapshotRow,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO liability_snapshots
       (lane, captured_at, account_count, accounts_sampled, outstanding_seconds, debt_seconds,
        error_accounts, complete)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
    .bind(
      snapshot.lane,
      snapshot.captured_at,
      snapshot.account_count,
      snapshot.accounts_sampled,
      snapshot.outstanding_seconds,
      snapshot.debt_seconds,
      snapshot.error_accounts,
      snapshot.complete ? 1 : 0,
    )
    .run();
}

export async function incrementOpsCounter(
  db: D1Database,
  name: string,
  delta: number,
  now: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO purchase_ops_counters (name, value, updated_at) VALUES (?1, ?2, ?3)
       ON CONFLICT(name) DO UPDATE SET
         value = purchase_ops_counters.value + excluded.value,
         updated_at = excluded.updated_at`,
    )
    .bind(name, delta, now)
    .run();
}

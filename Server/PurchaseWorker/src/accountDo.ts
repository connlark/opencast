// PurchaseAccount Durable Object: the authoritative, serialized money store
// for one account. SQLite tables per the parent plan (account_state,
// credit_lots FIFO, ledger_entries append-only, transactions, reservations).
// Every mutation loads state, runs the pure ledger engine, and persists the
// result inside one synchronous event turn — SQL calls here never interleave
// with other requests. Apple JWS verification happens in the worker before a
// request ever reaches this object.

import {
  assertInvariants,
  credit,
  emptyState,
  headroom,
  LedgerError,
  normalizeDebtAgainstAvailable,
  proratedRevocationSeconds,
  refund,
  refundReversal,
  release,
  reserve,
  settle,
  type LedgerEntryDraft,
  type LedgerState,
  type Lot,
  type Reservation,
} from './ledger';
import { FREE_GRANT_LEDGER_KIND, FREE_GRANT_SECONDS } from './catalog';
import type { Balance } from './types';
import {
  CREDIT_ERROR_CONFLICT,
  CREDIT_ERROR_INSUFFICIENT,
  CREDIT_ERROR_INTERNAL,
  CREDIT_ERROR_RESERVATION_NOT_FOUND,
  CREDIT_ERROR_SECONDS_MISMATCH,
} from './types';

const SCHEMA_VERSION = 2;

export interface InitMessage {
  account_id: string;
  app_account_token: string;
  environment: string;
  app_tx_hmac: string;
}

export interface CreditMessage {
  transaction_id: string;
  original_transaction_id: string | null;
  product_id: string;
  grant_seconds: number;
  purchase_date: number | null;
  storefront: string | null;
  quantity: number;
  ownership_type: string | null;
  jws_sha256: string;
  environment: string;
  app_account_token: string | null;
}

export interface RefundMessage {
  transaction_id: string;
  revocation_type: string | null;
  revocation_percentage: number | null;
  revocation_date: number | null;
  revocation_reason: string | null;
}

interface AccountRow {
  schemaVersion: number;
  status: string;
  available: number;
  reserved: number;
  consumed: number;
  debt: number;
  app_account_token: string;
  app_tx_hmac: string;
  environment: string;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

class AccountMissingError extends Error {}

function errorResponse(error: unknown): Response {
  if (error instanceof AccountMissingError) {
    return json(404, { error: 'account_not_found' });
  }
  if (error instanceof LedgerError) {
    switch (error.code) {
      case 'insufficient':
        return json(409, { error: CREDIT_ERROR_INSUFFICIENT });
      case 'reservation_not_found':
        return json(404, { error: CREDIT_ERROR_RESERVATION_NOT_FOUND });
      case 'conflict':
        return json(409, { error: CREDIT_ERROR_CONFLICT, detail: error.message });
      case 'seconds_mismatch':
        return json(409, { error: CREDIT_ERROR_SECONDS_MISMATCH, detail: error.message });
      default:
        return json(500, { error: CREDIT_ERROR_INTERNAL, detail: error.message });
    }
  }
  const detail = error instanceof Error ? error.message : 'unknown error';
  return json(500, { error: CREDIT_ERROR_INTERNAL, detail });
}

export class PurchaseAccount {
  private readonly ctx: DurableObjectState;

  constructor(ctx: DurableObjectState, _env: unknown) {
    this.ctx = ctx;
    ctx.blockConcurrencyWhile(async () => {
      this.mutate(() => this.migrate());
    });
  }

  /**
   * PW-1 atomicity: every money mutation (account_state, lots, reservations,
   * and its ledger entries — plus adjacent transactions-table writes) commits
   * or rolls back as one unit. Without this, a throw after the money writes
   * (e.g. a ledger idempotency collision) was caught at fetch() while the
   * already-executed SQL still committed at end of turn — money mutations
   * with no ledger row, invisible to assertInvariants.
   */
  private mutate<T>(fn: () => T): T {
    return this.ctx.storage.transactionSync(fn);
  }

  private get sql(): SqlStorage {
    return this.ctx.storage.sql;
  }

  private migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS account_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        schema_version INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        available INTEGER NOT NULL DEFAULT 0,
        reserved INTEGER NOT NULL DEFAULT 0,
        consumed INTEGER NOT NULL DEFAULT 0,
        debt INTEGER NOT NULL DEFAULT 0,
        app_account_token TEXT NOT NULL,
        app_tx_hmac TEXT NOT NULL,
        environment TEXT NOT NULL,
        free_grant_version TEXT,
        free_grant_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS credit_lots (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        lot_id TEXT NOT NULL UNIQUE,
        kind TEXT NOT NULL,
        transaction_id TEXT,
        product_id TEXT,
        granted INTEGER NOT NULL,
        available INTEGER NOT NULL,
        reserved INTEGER NOT NULL,
        consumed INTEGER NOT NULL,
        revoked INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS ledger_entries (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        idempotency_key TEXT NOT NULL UNIQUE,
        operation TEXT NOT NULL,
        lot_id TEXT,
        transaction_id TEXT,
        job_id TEXT,
        delta_available INTEGER NOT NULL,
        delta_reserved INTEGER NOT NULL,
        delta_consumed INTEGER NOT NULL,
        delta_debt INTEGER NOT NULL,
        available_after INTEGER NOT NULL,
        reserved_after INTEGER NOT NULL,
        consumed_after INTEGER NOT NULL,
        debt_after INTEGER NOT NULL,
        reason_code TEXT,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS transactions (
        transaction_id TEXT PRIMARY KEY,
        original_transaction_id TEXT,
        environment TEXT NOT NULL,
        app_account_token TEXT,
        product_id TEXT NOT NULL,
        purchase_date INTEGER,
        storefront TEXT,
        quantity INTEGER NOT NULL DEFAULT 1,
        ownership_type TEXT,
        jws_sha256 TEXT NOT NULL,
        credited_seconds INTEGER NOT NULL,
        state TEXT NOT NULL,
        lot_id TEXT NOT NULL,
        revocation_date INTEGER,
        revocation_reason TEXT,
        revocation_type TEXT,
        revocation_percentage INTEGER,
        refund_removed_available INTEGER,
        refund_debt_created INTEGER,
        refund_revoked_seconds INTEGER,
        last_verified_at INTEGER,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS reservations (
        job_id TEXT PRIMARY KEY,
        reserved_seconds INTEGER NOT NULL,
        allocations_json TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    `);

    const account = this.accountRow();
    if (!account || account.schemaVersion >= SCHEMA_VERSION) {
      return;
    }

    const now = Math.floor(Date.now() / 1000);
    const normalized = normalizeDebtAgainstAvailable(this.loadState(account), {
      idempotencyKeyBase: `migration:refund_debt_normalization:v${SCHEMA_VERSION}`,
      reasonCode: `refund_debt_normalization_v${SCHEMA_VERSION}`,
    });
    if (normalized.entries.length > 0) {
      this.persist(normalized.state, normalized.entries, now);
    }
    this.refreshDebtStatus(normalized.state);
    this.sql.exec(
      `UPDATE account_state SET schema_version = ?, updated_at = ? WHERE id = 1`,
      SCHEMA_VERSION,
      now,
    );
  }

  private accountRow(): AccountRow | null {
    const rows = this.sql
      .exec(
        `SELECT schema_version AS schemaVersion, status, available, reserved, consumed, debt,
                app_account_token, app_tx_hmac, environment
         FROM account_state WHERE id = 1`,
      )
      .toArray();
    return (rows[0] as unknown as AccountRow | undefined) ?? null;
  }

  private loadState(account: AccountRow): LedgerState {
    const state = emptyState();
    state.buckets = {
      available: Number(account.available),
      reserved: Number(account.reserved),
      consumed: Number(account.consumed),
      debt: Number(account.debt),
    };
    state.lots = this.sql
      .exec(
        `SELECT lot_id, kind, transaction_id, product_id, granted, available, reserved, consumed, revoked, created_at
         FROM credit_lots ORDER BY seq ASC`,
      )
      .toArray()
      .map((row) => ({
        lotId: String(row.lot_id),
        kind: String(row.kind) as Lot['kind'],
        transactionId: row.transaction_id === null ? null : String(row.transaction_id),
        productId: row.product_id === null ? null : String(row.product_id),
        granted: Number(row.granted),
        available: Number(row.available),
        reserved: Number(row.reserved),
        consumed: Number(row.consumed),
        revoked: Number(row.revoked),
        createdAt: Number(row.created_at),
      }));
    for (const row of this.sql
      .exec(`SELECT job_id, reserved_seconds, allocations_json, state FROM reservations`)
      .toArray()) {
      const reservation: Reservation = {
        jobId: String(row.job_id),
        reservedSeconds: Number(row.reserved_seconds),
        allocations: JSON.parse(String(row.allocations_json)),
        state: String(row.state) as Reservation['state'],
      };
      state.reservations[reservation.jobId] = reservation;
    }
    assertInvariants(state);
    return state;
  }

  private persist(state: LedgerState, entries: LedgerEntryDraft[], now: number): void {
    // Idempotency-first ordering (PW-1): the UNIQUE-keyed ledger INSERT runs
    // before any money write, so a replayed event collides while the state
    // is still untouched and the surrounding transaction rolls back clean.
    for (const entry of entries) {
      this.sql.exec(
        `INSERT INTO ledger_entries (idempotency_key, operation, lot_id, transaction_id, job_id,
           delta_available, delta_reserved, delta_consumed, delta_debt,
           available_after, reserved_after, consumed_after, debt_after, reason_code, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        entry.idempotencyKey,
        entry.operation,
        entry.lotId,
        entry.transactionId,
        entry.jobId,
        entry.delta.available,
        entry.delta.reserved,
        entry.delta.consumed,
        entry.delta.debt,
        entry.balanceAfter.available,
        entry.balanceAfter.reserved,
        entry.balanceAfter.consumed,
        entry.balanceAfter.debt,
        entry.reasonCode,
        now,
      );
    }
    this.sql.exec(
      `UPDATE account_state SET available = ?, reserved = ?, consumed = ?, debt = ?, updated_at = ? WHERE id = 1`,
      state.buckets.available,
      state.buckets.reserved,
      state.buckets.consumed,
      state.buckets.debt,
      now,
    );
    for (const lot of state.lots) {
      const updated = this.sql.exec(
        `UPDATE credit_lots SET available = ?, reserved = ?, consumed = ?, revoked = ? WHERE lot_id = ?`,
        lot.available,
        lot.reserved,
        lot.consumed,
        lot.revoked,
        lot.lotId,
      );
      if (updated.rowsWritten === 0) {
        this.sql.exec(
          `INSERT INTO credit_lots (lot_id, kind, transaction_id, product_id, granted, available, reserved, consumed, revoked, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          lot.lotId,
          lot.kind,
          lot.transactionId,
          lot.productId,
          lot.granted,
          lot.available,
          lot.reserved,
          lot.consumed,
          lot.revoked,
          lot.createdAt,
        );
      }
    }
    for (const reservation of Object.values(state.reservations)) {
      this.sql.exec(
        `INSERT INTO reservations (job_id, reserved_seconds, allocations_json, state, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(job_id) DO UPDATE SET
           reserved_seconds = excluded.reserved_seconds,
           allocations_json = excluded.allocations_json,
           state = excluded.state,
           updated_at = excluded.updated_at`,
        reservation.jobId,
        reservation.reservedSeconds,
        JSON.stringify(reservation.allocations),
        reservation.state,
        now,
        now,
      );
    }
  }

  private balance(state: LedgerState): Balance {
    return {
      available_seconds: state.buckets.available,
      reserved_seconds: state.buckets.reserved,
      debt_seconds: state.buckets.debt,
    };
  }

  private requireActiveAccount(): AccountRow {
    const account = this.accountRow();
    if (!account) {
      throw new AccountMissingError('account not initialized');
    }
    if (account.status !== 'active' && account.status !== 'refund_debt') {
      throw new LedgerError('conflict', `account status ${account.status}`);
    }
    return account;
  }

  private refreshDebtStatus(state: LedgerState): void {
    const status = state.buckets.debt > 0 ? 'refund_debt' : 'active';
    this.sql.exec(
      `UPDATE account_state SET status = ? WHERE id = 1 AND status IN ('active', 'refund_debt')`,
      status,
    );
  }

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    const now = Math.floor(Date.now() / 1000);
    try {
      switch (path) {
        // Every mutating handler is synchronous after the body parse and
        // runs under this.mutate (transactionSync) so its money writes,
        // ledger inserts, and transactions-table updates commit or roll
        // back together (PW-1).
        case '/init': {
          const body = (await request.json()) as InitMessage;
          return this.mutate(() => this.handleInit(body, now));
        }
        case '/balance':
          return this.handleBalance();
        case '/reserve': {
          const body = (await request.json()) as { job_id: string; seconds: number };
          return this.mutate(() => this.handleReserve(body.job_id, body.seconds, now));
        }
        case '/settle': {
          const body = (await request.json()) as { job_id: string };
          return this.mutate(() => this.handleSettle(body.job_id, now));
        }
        case '/release': {
          const body = (await request.json()) as { job_id: string };
          return this.mutate(() => this.handleRelease(body.job_id, now));
        }
        case '/credit': {
          const body = (await request.json()) as CreditMessage;
          return this.mutate(() => this.handleCredit(body, now));
        }
        case '/refund': {
          const body = (await request.json()) as RefundMessage;
          return this.mutate(() => this.handleRefund(body, now));
        }
        case '/refund-reversed': {
          const body = (await request.json()) as { transaction_id: string };
          return this.mutate(() => this.handleRefundReversed(body.transaction_id, now));
        }
        case '/snapshot':
          return this.handleSnapshot();
        case '/liability':
          return this.handleLiability();
        default:
          return json(404, { error: 'not_found' });
      }
    } catch (error) {
      return errorResponse(error);
    }
  }

  /** Idempotent account creation; issues the free grant exactly once. */
  private handleInit(message: InitMessage, now: number): Response {
    const existing = this.accountRow();
    if (existing) {
      // A concurrent bootstrap must converge on identical identity material.
      if (
        existing.app_tx_hmac !== message.app_tx_hmac ||
        existing.environment !== message.environment
      ) {
        throw new LedgerError('internal', 'account identity mismatch on init');
      }
      const state = this.loadState(existing);
      return json(200, {
        balance: this.balance(state),
        app_account_token: existing.app_account_token,
        already_existed: true,
      });
    }

    this.sql.exec(
      `INSERT INTO account_state (id, schema_version, status, app_account_token, app_tx_hmac, environment, free_grant_version, free_grant_at, created_at, updated_at)
       VALUES (1, ?, 'active', ?, ?, ?, ?, ?, ?, ?)`,
      SCHEMA_VERSION,
      message.app_account_token,
      message.app_tx_hmac,
      message.environment,
      FREE_GRANT_LEDGER_KIND,
      now,
      now,
      now,
    );
    const { state, entries } = credit(emptyState(), {
      lotId: `lot-free-${message.account_id}`,
      kind: 'free',
      transactionId: null,
      productId: null,
      grantedSeconds: FREE_GRANT_SECONDS,
      idempotencyKeyBase: `grant:${FREE_GRANT_LEDGER_KIND}`,
      reasonCode: FREE_GRANT_LEDGER_KIND,
      now,
    });
    this.persist(state, entries, now);
    return json(200, {
      balance: this.balance(state),
      app_account_token: message.app_account_token,
      already_existed: false,
    });
  }

  private handleBalance(): Response {
    const account = this.requireActiveAccount();
    const state = this.loadState(account);
    return json(200, { balance: this.balance(state) });
  }

  private handleReserve(jobId: string, seconds: number, now: number): Response {
    if (typeof jobId !== 'string' || jobId.length === 0) {
      throw new LedgerError('conflict', 'job_id required');
    }
    const account = this.requireActiveAccount();
    const state = this.loadState(account);
    const result = reserve(state, jobId, seconds, now);
    this.persist(result.state, result.entries, now);
    return json(200, {
      balance: this.balance(result.state),
      already_existed: result.alreadyExisted,
      headroom_seconds: headroom(result.state.buckets),
    });
  }

  private handleSettle(jobId: string, now: number): Response {
    const account = this.requireActiveAccount();
    const state = this.loadState(account);
    const result = settle(state, jobId);
    this.persist(result.state, result.entries, now);
    this.refreshDebtStatus(result.state);
    return json(200, { balance: this.balance(result.state) });
  }

  private handleRelease(jobId: string, now: number): Response {
    const account = this.requireActiveAccount();
    const state = this.loadState(account);
    const result = release(state, jobId);
    this.persist(result.state, result.entries, now);
    this.refreshDebtStatus(result.state);
    return json(200, { balance: this.balance(result.state) });
  }

  /** Exactly-once purchase credit; duplicates return the applied result. */
  private handleCredit(message: CreditMessage, now: number): Response {
    const account = this.requireActiveAccount();
    if (message.app_account_token !== null && message.app_account_token !== account.app_account_token) {
      return json(409, { error: 'app_account_token_mismatch' });
    }
    if (message.environment !== account.environment) {
      return json(409, { error: 'environment_mismatch' });
    }

    const existing = this.sql
      .exec(
        `SELECT credited_seconds, state FROM transactions WHERE transaction_id = ?`,
        message.transaction_id,
      )
      .toArray()[0];
    if (existing) {
      const state = this.loadState(account);
      const txState = String(existing.state);
      return json(200, {
        outcome: txState === 'credited' ? 'already_credited' : txState,
        credited_seconds: Number(existing.credited_seconds),
        balance: this.balance(state),
      });
    }

    const lotId = `lot-txn-${message.transaction_id}`;
    const state = this.loadState(account);
    const { state: next, entries } = credit(state, {
      lotId,
      kind: 'purchase',
      transactionId: message.transaction_id,
      productId: message.product_id,
      grantedSeconds: message.grant_seconds,
      idempotencyKeyBase: `credit:txn:${message.transaction_id}`,
      reasonCode: 'purchase',
      now,
    });
    this.sql.exec(
      `INSERT INTO transactions (transaction_id, original_transaction_id, environment, app_account_token, product_id,
         purchase_date, storefront, quantity, ownership_type, jws_sha256, credited_seconds, state, lot_id, last_verified_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'credited', ?, ?, ?)`,
      message.transaction_id,
      message.original_transaction_id,
      message.environment,
      message.app_account_token,
      message.product_id,
      message.purchase_date,
      message.storefront,
      message.quantity,
      message.ownership_type,
      message.jws_sha256,
      message.grant_seconds,
      lotId,
      now,
      now,
    );
    this.persist(next, entries, now);
    this.refreshDebtStatus(next);
    return json(200, {
      outcome: 'credited',
      credited_seconds: message.grant_seconds,
      balance: this.balance(next),
    });
  }

  private handleRefund(message: RefundMessage, now: number): Response {
    const account = this.requireActiveAccount();
    const row = this.sql
      .exec(
        `SELECT lot_id, credited_seconds, state, revocation_date FROM transactions WHERE transaction_id = ?`,
        message.transaction_id,
      )
      .toArray()[0];
    if (!row) {
      return json(404, { error: 'transaction_not_found' });
    }
    const txState = String(row.state);
    if (txState === 'refunded' || txState === 'partially_refunded') {
      const state = this.loadState(account);
      return json(200, { applied: false, already_refunded: true, balance: this.balance(state) });
    }
    // A `refund_reversed` transaction falls through DELIBERATELY, gated by
    // the idempotency key (transaction_id + revocation_date): a replay of
    // the already-applied revocation event collides here and no-ops, while
    // a genuinely NEW revocation after a reversal mints a fresh key and
    // must re-apply (PW-1 leg 3). The belt stays in persist(): the
    // ledger-first INSERT under transactionSync rolls any missed replay
    // back clean.
    const idempotencyKey = `refund:txn:${message.transaction_id}:${message.revocation_date ?? 0}`;
    const replayed =
      this.sql
        .exec(`SELECT 1 FROM ledger_entries WHERE idempotency_key = ?`, idempotencyKey)
        .toArray().length > 0;
    if (replayed) {
      const state = this.loadState(account);
      return json(200, { applied: false, already_refunded: true, balance: this.balance(state) });
    }

    const credited = Number(row.credited_seconds);
    // Revocation math (parent plan): prorated consumables revoke
    // floor(granted × revocationPercentage / 100000); absent type means full.
    const revokeRequested = proratedRevocationSeconds(
      credited,
      message.revocation_percentage ?? undefined,
      message.revocation_type ?? undefined,
    );
    const state = this.loadState(account);
    const result = refund(state, {
      lotId: String(row.lot_id),
      transactionId: message.transaction_id,
      revokeSeconds: revokeRequested,
      idempotencyKey,
      reasonCode: message.revocation_type ?? 'REFUND',
    });
    const newState = result.revokedSeconds >= credited ? 'refunded' : 'partially_refunded';
    this.sql.exec(
      `UPDATE transactions SET state = ?, revocation_date = ?, revocation_reason = ?, revocation_type = ?,
         revocation_percentage = ?, refund_removed_available = ?, refund_debt_created = ?, refund_revoked_seconds = ?
       WHERE transaction_id = ?`,
      newState,
      message.revocation_date,
      message.revocation_reason,
      message.revocation_type,
      message.revocation_percentage,
      result.removedFromAvailable,
      result.debtCreated,
      result.revokedSeconds,
      message.transaction_id,
    );
    this.persist(result.state, result.entries, now);
    this.refreshDebtStatus(result.state);
    return json(200, {
      applied: true,
      revoked_seconds: result.revokedSeconds,
      debt_created: result.debtCreated,
      balance: this.balance(result.state),
    });
  }

  private handleRefundReversed(transactionId: string, now: number): Response {
    const account = this.requireActiveAccount();
    const row = this.sql
      .exec(
        `SELECT lot_id, state, refund_removed_available, refund_debt_created FROM transactions WHERE transaction_id = ?`,
        transactionId,
      )
      .toArray()[0];
    if (!row) {
      return json(404, { error: 'transaction_not_found' });
    }
    const txState = String(row.state);
    if (txState !== 'refunded' && txState !== 'partially_refunded') {
      const state = this.loadState(account);
      return json(200, { applied: false, balance: this.balance(state) });
    }

    const state = this.loadState(account);
    const result = refundReversal(state, {
      lotId: String(row.lot_id),
      transactionId,
      removedFromAvailable: Number(row.refund_removed_available ?? 0),
      debtCreated: Number(row.refund_debt_created ?? 0),
      idempotencyKey: `refund_reversed:txn:${transactionId}:${now}`,
      reasonCode: 'REFUND_REVERSED',
    });
    this.sql.exec(
      `UPDATE transactions SET state = 'refund_reversed', refund_removed_available = NULL,
         refund_debt_created = NULL, refund_revoked_seconds = NULL
       WHERE transaction_id = ?`,
      transactionId,
    );
    this.persist(result.state, result.entries, now);
    this.refreshDebtStatus(result.state);
    return json(200, { applied: true, balance: this.balance(result.state) });
  }

  /** Content-free diagnostics for tests and audited operator inspection. */
  private handleSnapshot(): Response {
    const account = this.accountRow();
    if (!account) {
      return json(404, { error: 'account_not_found' });
    }
    const state = this.loadState(account);
    const ledger = this.sql
      .exec(
        `SELECT seq, idempotency_key, operation, lot_id, transaction_id, job_id,
                delta_available, delta_reserved, delta_consumed, delta_debt,
                available_after, reserved_after, consumed_after, debt_after, reason_code
         FROM ledger_entries ORDER BY seq ASC`,
      )
      .toArray();
    const transactions = this.sql
      .exec(
        `SELECT transaction_id, product_id, credited_seconds, state, quantity,
                refund_removed_available, refund_debt_created, refund_revoked_seconds
         FROM transactions ORDER BY created_at ASC`,
      )
      .toArray();
    return json(200, {
      schema_version: account.schemaVersion,
      status: account.status,
      buckets: state.buckets,
      lots: state.lots,
      reservations: Object.values(state.reservations),
      ledger,
      transactions,
      headroom_seconds: headroom(state.buckets),
    });
  }

  /** Minimal content-free aggregate used by the reconciliation cron. */
  private handleLiability(): Response {
    const account = this.accountRow();
    if (!account) {
      return json(404, { error: 'account_not_found' });
    }
    const state = this.loadState(account);
    return json(200, {
      outstanding_seconds: state.buckets.available + state.buckets.reserved,
      debt_seconds: state.buckets.debt,
    });
  }
}

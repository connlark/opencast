// Content-free liability snapshots. The Account DO remains authoritative;
// this module asks each account for only outstanding/debt totals and records
// one aggregate D1 row per completed sweep.
//
// A sweep walks `purchase_accounts` in `account_id` order one page per
// invocation, carrying the cursor and running totals in
// `liability_sweep_state`, so the reconciliation cron never spends more than
// one page of DO reads on it. The page came back short => the sweep is
// complete: the snapshot row is written and the state cleared.

import * as d1 from './d1';
import type { Env } from './types';

const DEFAULT_PAGE_ACCOUNTS = 200;
/**
 * Hard ceiling on accounts read per invocation. Together with the
 * reconciliation transaction budget this keeps one cron tick under the
 * 1000-subrequest invocation limit (see `MAX_RECONCILE_TRANSACTIONS_PER_RUN`).
 */
export const MAX_LIABILITY_PAGE_ACCOUNTS = 250;
const MAX_CONCURRENT_DO_READS = 20;

export interface LiabilitySnapshot {
  lane: string;
  captured_at: number;
  account_count: number;
  accounts_sampled: number;
  outstanding_seconds: number;
  debt_seconds: number;
  error_accounts: number;
  complete: boolean;
}

/** One sweep step: the running totals, plus whether this step finished the sweep. */
export interface LiabilitySweepStep extends LiabilitySnapshot {
  sweep_complete: boolean;
  accounts_read: number;
}

interface AccountLiability {
  outstanding_seconds: number;
  debt_seconds: number;
}

export function liabilityPageAccounts(env: Env): number {
  return Math.min(
    MAX_LIABILITY_PAGE_ACCOUNTS,
    Math.max(1, Number(env.LIABILITY_SNAPSHOT_MAX_ACCOUNTS) || DEFAULT_PAGE_ACCOUNTS),
  );
}

function accountStub(env: Env, accountId: string): DurableObjectStub {
  return env.PURCHASE_ACCOUNT.get(env.PURCHASE_ACCOUNT.idFromName(accountId));
}

async function readAccountLiability(env: Env, accountId: string): Promise<AccountLiability> {
  const response = await accountStub(env, accountId).fetch(
    'https://purchase-account.opencast.internal/liability',
    { method: 'POST' },
  );
  if (!response.ok) {
    throw new Error(`account liability returned HTTP ${response.status}`);
  }
  const body = (await response.json()) as Partial<AccountLiability>;
  if (
    !Number.isSafeInteger(body.outstanding_seconds) ||
    Number(body.outstanding_seconds) < 0 ||
    !Number.isSafeInteger(body.debt_seconds) ||
    Number(body.debt_seconds) < 0
  ) {
    throw new Error('account liability response was invalid');
  }
  return {
    outstanding_seconds: Number(body.outstanding_seconds),
    debt_seconds: Number(body.debt_seconds),
  };
}

/**
 * Advances the liability sweep by one page. Returns the running totals; when
 * the page runs short the sweep is complete, the snapshot row is recorded,
 * and the next call starts a fresh sweep.
 */
export async function advanceLiabilitySweep(env: Env): Promise<LiabilitySweepStep> {
  const now = Math.floor(Date.now() / 1000);
  const pageAccounts = liabilityPageAccounts(env);
  const state = (await d1.liabilitySweepState(env.PURCHASE_DB)) ?? {
    cursor: null,
    started_at: now,
    accounts_sampled: 0,
    outstanding_seconds: 0,
    debt_seconds: 0,
    error_accounts: 0,
  };
  const accountIds = await d1.purchaseAccountIdsAfter(env.PURCHASE_DB, state.cursor, pageAccounts);

  let outstandingSeconds = state.outstanding_seconds;
  let debtSeconds = state.debt_seconds;
  let errorAccounts = state.error_accounts;
  for (let offset = 0; offset < accountIds.length; offset += MAX_CONCURRENT_DO_READS) {
    const batch = accountIds.slice(offset, offset + MAX_CONCURRENT_DO_READS);
    const results = await Promise.allSettled(
      batch.map((accountId) => readAccountLiability(env, accountId)),
    );
    for (const result of results) {
      if (result.status === 'fulfilled') {
        outstandingSeconds += result.value.outstanding_seconds;
        debtSeconds += result.value.debt_seconds;
      } else {
        errorAccounts += 1;
      }
    }
  }
  const accountsSampled = state.accounts_sampled + accountIds.length;
  const sweepComplete = accountIds.length < pageAccounts;
  const accountCount = await d1.purchaseAccountCount(env.PURCHASE_DB);

  const snapshot: LiabilitySnapshot = {
    lane: env.LANE,
    captured_at: now,
    account_count: accountCount,
    accounts_sampled: accountsSampled,
    outstanding_seconds: outstandingSeconds,
    debt_seconds: debtSeconds,
    error_accounts: errorAccounts,
    // A completed sweep walked the whole account keyspace; accounts created
    // behind the cursor mid-sweep are picked up by the next one.
    complete: sweepComplete && errorAccounts === 0,
  };

  if (sweepComplete) {
    await d1.recordLiabilitySnapshot(env.PURCHASE_DB, snapshot);
    await d1.clearLiabilitySweepState(env.PURCHASE_DB);
    await d1.incrementOpsCounter(env.PURCHASE_DB, 'liability_snapshot_runs', 1, now);
    if (!snapshot.complete) {
      await d1.incrementOpsCounter(env.PURCHASE_DB, 'liability_snapshot_incomplete', 1, now);
    }
  } else {
    await d1.saveLiabilitySweepState(
      env.PURCHASE_DB,
      {
        cursor: accountIds[accountIds.length - 1] ?? state.cursor,
        started_at: state.started_at,
        accounts_sampled: accountsSampled,
        outstanding_seconds: outstandingSeconds,
        debt_seconds: debtSeconds,
        error_accounts: errorAccounts,
      },
      now,
    );
    await d1.incrementOpsCounter(env.PURCHASE_DB, 'liability_sweep_continued', 1, now);
  }
  return { ...snapshot, sweep_complete: sweepComplete, accounts_read: accountIds.length };
}

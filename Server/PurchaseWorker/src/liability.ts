// Content-free liability snapshots. The Account DO remains authoritative;
// this module asks each account for only outstanding/debt totals and records
// one aggregate D1 row per reconciliation cron.

import * as d1 from './d1';
import type { Env } from './types';

const DEFAULT_MAX_ACCOUNTS = 500;
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

interface AccountLiability {
  outstanding_seconds: number;
  debt_seconds: number;
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

export async function captureLiabilitySnapshot(env: Env): Promise<LiabilitySnapshot> {
  const now = Math.floor(Date.now() / 1000);
  const maxAccounts = Math.min(
    5_000,
    Math.max(1, Number(env.LIABILITY_SNAPSHOT_MAX_ACCOUNTS) || DEFAULT_MAX_ACCOUNTS),
  );
  const accountCount = await d1.purchaseAccountCount(env.PURCHASE_DB);
  const accountIds = await d1.purchaseAccountIds(env.PURCHASE_DB, maxAccounts);

  let outstandingSeconds = 0;
  let debtSeconds = 0;
  let errorAccounts = 0;
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

  const snapshot: LiabilitySnapshot = {
    lane: env.LANE,
    captured_at: now,
    account_count: accountCount,
    accounts_sampled: accountIds.length,
    outstanding_seconds: outstandingSeconds,
    debt_seconds: debtSeconds,
    error_accounts: errorAccounts,
    complete: accountIds.length === accountCount && errorAccounts === 0,
  };
  await d1.recordLiabilitySnapshot(env.PURCHASE_DB, snapshot);
  await d1.incrementOpsCounter(env.PURCHASE_DB, 'liability_snapshot_runs', 1, now);
  if (!snapshot.complete) {
    await d1.incrementOpsCounter(env.PURCHASE_DB, 'liability_snapshot_incomplete', 1, now);
  }
  return snapshot;
}

// Ledger property tests: overdraft headroom, FIFO lots, idempotency, debt
// repayment order, refund/reversal math, and invariants after every mutation
// (the engine asserts them itself; these tests drive the state space).

import { describe, expect, it } from 'vitest';
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
} from '../../src/ledger';
import { DEBT_CAP_SECONDS, FREE_GRANT_SECONDS } from '../../src/catalog';

function freshAccount() {
  const { state } = credit(emptyState(), {
    lotId: 'lot-free',
    kind: 'free',
    transactionId: null,
    productId: null,
    grantedSeconds: FREE_GRANT_SECONDS,
    idempotencyKeyBase: 'grant:free_grant_v1',
    reasonCode: 'free_grant_v1',
    now: 1,
  });
  return state;
}

function buy(state, transactionId, seconds, now = 10) {
  return credit(state, {
    lotId: `lot-txn-${transactionId}`,
    kind: 'purchase',
    transactionId,
    productId: 'com.connor.opencast.transcription.hours20.v1',
    grantedSeconds: seconds,
    idempotencyKeyBase: `credit:txn:${transactionId}`,
    reasonCode: 'purchase',
    now,
  });
}

describe('credit and debt repayment', () => {
  it('grants the free hour into available', () => {
    const state = freshAccount();
    expect(state.buckets).toEqual({ available: 3600, reserved: 0, consumed: 0, debt: 0 });
    expect(headroom(state.buckets)).toBe(3600 + DEBT_CAP_SECONDS);
  });

  it('repays debt before adding to available, attributed to the crediting lot', () => {
    let state = freshAccount();
    state = reserve(state, 'job-1', 5000, 2).state;
    state = settle(state, 'job-1').state;
    expect(state.buckets).toEqual({ available: 0, reserved: 0, consumed: 5000, debt: 1400 });

    const result = buy(state, 'txn-1', 72_000);
    expect(result.state.buckets).toEqual({
      available: 70_600,
      reserved: 0,
      consumed: 5000,
      debt: 0,
    });
    expect(result.entries.map((entry) => entry.operation)).toEqual(['grant', 'debt_repayment']);
    const lot = result.state.lots.find((candidate) => candidate.lotId === 'lot-txn-txn-1');
    expect(lot.consumed).toBe(1400);
    expect(lot.available).toBe(70_600);
  });
});

describe('overdraft reserve admission', () => {
  it('admits within headroom and blocks beyond it', () => {
    const state = freshAccount();
    // headroom = 3600 + 10800 = 14400
    expect(() => reserve(state, 'job-too-big', 14_401, 2)).toThrowError(LedgerError);
    const admitted = reserve(state, 'job-max', 14_400, 2);
    expect(admitted.state.buckets.reserved).toBe(14_400);
  });

  it('existing debt shrinks headroom; refund-origin debt beyond cap blocks all reserves', () => {
    let state = freshAccount();
    state = buy(state, 'txn-1', 72_000).state;
    const refunded = refund(state, {
      lotId: 'lot-txn-txn-1',
      transactionId: 'txn-1',
      revokeSeconds: 72_000,
      idempotencyKey: 'refund:txn:txn-1:0',
      reasonCode: 'REFUND',
    });
    // Nothing consumed yet: full revocation removes available only.
    expect(refunded.state.buckets.debt).toBe(0);

    // Now consume past the purchase then refund: debt may exceed the cap.
    let deep = freshAccount();
    deep = buy(deep, 'txn-2', 72_000).state;
    deep = reserve(deep, 'job-big', 70_000, 3).state;
    deep = settle(deep, 'job-big').state;
    // available = 75600 - 70000 = 5600 consumed=70000
    const bigRefund = refund(deep, {
      lotId: 'lot-txn-txn-2',
      transactionId: 'txn-2',
      revokeSeconds: 72_000,
      idempotencyKey: 'refund:txn:txn-2:0',
      reasonCode: 'REFUND',
    });
    expect(bigRefund.state.buckets.debt).toBeGreaterThan(DEBT_CAP_SECONDS);
    expect(headroom(bigRefund.state.buckets)).toBeLessThanOrEqual(0);
    expect(() => reserve(bigRefund.state, 'job-after', 1, 4)).toThrowError(LedgerError);
  });

  it('reserve is idempotent per job and conflicts after release', () => {
    let state = freshAccount();
    const first = reserve(state, 'job-1', 100, 2);
    const again = reserve(first.state, 'job-1', 100, 3);
    expect(again.alreadyExisted).toBe(true);
    expect(again.state.buckets.reserved).toBe(100);

    const released = release(again.state, 'job-1');
    expect(released.state.buckets.reserved).toBe(0);
    expect(() => reserve(released.state, 'job-1', 100, 4)).toThrowError(/released/);
  });
});

describe('settle and release', () => {
  it('settle consumes available first and books the remainder as debt', () => {
    let state = freshAccount();
    state = reserve(state, 'job-1', 4000, 2).state;
    const settled = settle(state, 'job-1');
    expect(settled.state.buckets).toEqual({
      available: 0,
      reserved: 0,
      consumed: 4000,
      debt: 400,
    });
    // Settling again is a no-op; releasing after settle is a no-op.
    expect(settle(settled.state, 'job-1').entries).toHaveLength(0);
    expect(release(settled.state, 'job-1').entries).toHaveLength(0);
  });

  it('settle of an unknown job fails; release of an unknown job is a no-op', () => {
    const state = freshAccount();
    expect(() => settle(state, 'nope')).toThrowError(/not found/);
    expect(release(state, 'nope').entries).toHaveLength(0);
  });

  it('cannot settle a released reservation', () => {
    let state = freshAccount();
    state = reserve(state, 'job-1', 100, 2).state;
    state = release(state, 'job-1').state;
    expect(() => settle(state, 'job-1')).toThrowError(/released/);
  });
});

describe('FIFO lots', () => {
  it('allocates and consumes oldest lots first', () => {
    let state = freshAccount();
    state = buy(state, 'txn-1', 72_000, 10).state;
    state = buy(state, 'txn-2', 360_000, 20).state;

    state = reserve(state, 'job-1', 70_000, 30).state;
    state = settle(state, 'job-1').state;

    const [free, first, second] = state.lots;
    expect(free.consumed).toBe(3600);
    expect(first.consumed).toBe(66_400);
    expect(second.consumed).toBe(0);
  });
});

describe('refund math', () => {
  it('prorated revocation floors milliunits', () => {
    expect(proratedRevocationSeconds(72_000, 50_000, 'REFUND_PRORATED')).toBe(36_000);
    expect(proratedRevocationSeconds(72_000, 33_333, 'REFUND_PRORATED')).toBe(23_999);
    expect(proratedRevocationSeconds(72_000, undefined, 'REFUND_FULL')).toBe(72_000);
    expect(proratedRevocationSeconds(72_000, undefined, undefined)).toBe(72_000);
    expect(proratedRevocationSeconds(72_000, 200_000, 'REFUND_PRORATED')).toBe(72_000);
  });

  it('removes still-available seconds first; consumed shortfall becomes debt', () => {
    let state = freshAccount();
    state = buy(state, 'txn-1', 72_000).state;
    state = reserve(state, 'job-1', 40_000, 3).state;
    state = settle(state, 'job-1').state;
    // free 3600 + purchase 36400 consumed; purchase lot has 35600 left.
    const result = refund(state, {
      lotId: 'lot-txn-txn-1',
      transactionId: 'txn-1',
      revokeSeconds: 72_000,
      idempotencyKey: 'refund:txn:txn-1:0',
      reasonCode: 'REFUND',
    });
    expect(result.removedFromAvailable).toBe(35_600);
    expect(result.debtCreated).toBe(36_400);
    expect(result.state.buckets.available).toBe(0);
    expect(result.state.buckets.debt).toBe(36_400);
  });

  it('produces the same balance whether a newer purchase arrives before or after an old refund', () => {
    let consumedOldPurchase = freshAccount();
    consumedOldPurchase = buy(consumedOldPurchase, 'old', 72_000).state;
    consumedOldPurchase = reserve(consumedOldPurchase, 'job-old', 25_000, 3).state;
    consumedOldPurchase = settle(consumedOldPurchase, 'job-old').state;

    const refundInput = {
      lotId: 'lot-txn-old',
      transactionId: 'old',
      revokeSeconds: 72_000,
      idempotencyKey: 'refund:txn:old:1',
      reasonCode: 'REFUND',
    };

    const purchasedFirst = buy(consumedOldPurchase, 'new', 360_000, 4).state;
    const refundAfterPurchase = refund(purchasedFirst, refundInput);

    const refundedFirst = refund(consumedOldPurchase, refundInput);
    const purchaseAfterRefund = buy(refundedFirst.state, 'new', 360_000, 4);

    expect(refundAfterPurchase.debtCreated).toBe(21_400);
    expect(refundAfterPurchase.entries.map((entry) => entry.operation)).toEqual([
      'refund',
      'debt_repayment',
    ]);
    expect(refundAfterPurchase.state.buckets).toEqual(purchaseAfterRefund.state.buckets);
    expect(refundAfterPurchase.state.buckets.debt).toBe(0);
    expect(refundAfterPurchase.state.lots).toEqual(purchaseAfterRefund.state.lots);
  });

  it('never takes reserved availability, then normalizes debt when the reservation releases', () => {
    let state = freshAccount();
    state = buy(state, 'old', 72_000).state;
    state = reserve(state, 'job-consume-old', 75_600, 3).state;
    state = settle(state, 'job-consume-old').state;
    state = buy(state, 'new', 360_000, 4).state;
    state = reserve(state, 'job-new', 350_000, 5).state;

    const refunded = refund(state, {
      lotId: 'lot-txn-old',
      transactionId: 'old',
      revokeSeconds: 72_000,
      idempotencyKey: 'refund:txn:old:2',
      reasonCode: 'REFUND',
    });
    expect(refunded.state.buckets).toEqual({
      available: 350_000,
      reserved: 350_000,
      consumed: 75_600,
      debt: 62_000,
    });

    const released = release(refunded.state, 'job-new');
    expect(released.entries.map((entry) => entry.operation)).toEqual([
      'release',
      'debt_repayment',
    ]);
    expect(released.state.buckets).toEqual({
      available: 288_000,
      reserved: 0,
      consumed: 75_600,
      debt: 0,
    });
  });

  it('protects account reservations after a refund invalidates their original lot allocation', () => {
    let state = freshAccount();
    state = buy(state, 'old', 72_000).state;
    state = reserve(state, 'job-consume', 25_000, 3).state;
    state = settle(state, 'job-consume').state;
    state = reserve(state, 'job-old-lot', 50_000, 4).state;
    state = buy(state, 'new', 50_000, 5).state;

    const refunded = refund(state, {
      lotId: 'lot-txn-old',
      transactionId: 'old',
      revokeSeconds: 72_000,
      idempotencyKey: 'refund:txn:old:reserved',
      reasonCode: 'REFUND',
    });

    // The old lot's annotation is clamped by the refund, but the account's
    // active reservation still protects all 50,000 seconds in the new lot.
    expect(refunded.state.buckets).toEqual({
      available: 50_000,
      reserved: 50_000,
      consumed: 25_000,
      debt: 21_400,
    });
    expect(refunded.entries.map((entry) => entry.operation)).toEqual(['refund']);

    const released = release(refunded.state, 'job-old-lot');
    expect(released.state.buckets).toEqual({
      available: 28_600,
      reserved: 0,
      consumed: 25_000,
      debt: 0,
    });
  });

  it('repairs legacy debt that coexists with unreserved availability', () => {
    let legacy = freshAccount();
    legacy = reserve(legacy, 'job-free', FREE_GRANT_SECONDS, 2).state;
    legacy = settle(legacy, 'job-free').state;
    legacy = buy(legacy, 'new', 360_000).state;
    legacy.buckets.debt = 26_152;

    const repaired = normalizeDebtAgainstAvailable(legacy, {
      idempotencyKeyBase: 'migration:refund_debt_normalization:v2',
      reasonCode: 'refund_debt_normalization_v2',
    });

    expect(repaired.state.buckets).toEqual({
      available: 333_848,
      reserved: 0,
      consumed: 3_600,
      debt: 0,
    });
    expect(repaired.entries.map((entry) => entry.operation)).toEqual(['debt_repayment']);
    expect(repaired.entries[0].transactionId).toBe('new');
  });

  it('reversal restores exactly what the refund removed', () => {
    let state = freshAccount();
    state = buy(state, 'txn-1', 72_000).state;
    state = reserve(state, 'job-1', 40_000, 3).state;
    state = settle(state, 'job-1').state;
    const refunded = refund(state, {
      lotId: 'lot-txn-txn-1',
      transactionId: 'txn-1',
      revokeSeconds: 72_000,
      idempotencyKey: 'refund:txn:txn-1:0',
      reasonCode: 'REFUND',
    });
    const reversed = refundReversal(refunded.state, {
      lotId: 'lot-txn-txn-1',
      transactionId: 'txn-1',
      removedFromAvailable: refunded.removedFromAvailable,
      debtCreated: refunded.debtCreated,
      idempotencyKey: 'refund_reversed:txn:txn-1:0',
      reasonCode: 'REFUND_REVERSED',
    });
    expect(reversed.state.buckets).toEqual(state.buckets);
  });

  it('reversal after a credit already repaid the debt returns seconds as available', () => {
    let state = freshAccount();
    state = buy(state, 'txn-1', 72_000).state;
    state = reserve(state, 'job-1', 75_600, 3).state;
    state = settle(state, 'job-1').state; // consumed everything
    const refunded = refund(state, {
      lotId: 'lot-txn-txn-1',
      transactionId: 'txn-1',
      revokeSeconds: 72_000,
      idempotencyKey: 'refund:txn:txn-1:0',
      reasonCode: 'REFUND',
    });
    expect(refunded.debtCreated).toBe(72_000);
    // A new purchase repays the refund debt in full.
    const repaid = buy(refunded.state, 'txn-2', 360_000, 40);
    expect(repaid.state.buckets.debt).toBe(0);
    const reversed = refundReversal(repaid.state, {
      lotId: 'lot-txn-txn-1',
      transactionId: 'txn-1',
      removedFromAvailable: refunded.removedFromAvailable,
      debtCreated: refunded.debtCreated,
      idempotencyKey: 'refund_reversed:txn:txn-1:0',
      reasonCode: 'REFUND_REVERSED',
    });
    // Debt was already repaid, so the reversal returns it as available.
    expect(reversed.state.buckets.available).toBe(
      repaid.state.buckets.available + refunded.debtCreated,
    );
    expect(reversed.state.buckets.debt).toBe(0);
  });
});

describe('randomized invariant walk', () => {
  function mulberry32(seed) {
    let a = seed >>> 0;
    return () => {
      a |= 0;
      a = (a + 0x6d2b79f5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  it('holds invariants and ledger-delta chains across thousands of random ops', () => {
    for (const seed of [1, 7, 42, 1337, 20260716]) {
      const random = mulberry32(seed);
      const grant = credit(emptyState(), {
        lotId: 'lot-free',
        kind: 'free',
        transactionId: null,
        productId: null,
        grantedSeconds: FREE_GRANT_SECONDS,
        idempotencyKeyBase: 'grant:free_grant_v1',
        reasonCode: 'free_grant_v1',
        now: 0,
      });
      let state = grant.state;
      let jobCounter = 0;
      let txnCounter = 0;
      const activeJobs = [];
      const refundables = [];
      const allEntries = [...grant.entries];

      for (let step = 0; step < 400; step += 1) {
        const roll = random();
        try {
          if (roll < 0.3) {
            const jobId = `job-${seed}-${jobCounter += 1}`;
            const seconds = 1 + Math.floor(random() * 20_000);
            const result = reserve(state, jobId, seconds, step);
            state = result.state;
            allEntries.push(...result.entries);
            activeJobs.push(jobId);
          } else if (roll < 0.55 && activeJobs.length > 0) {
            const jobId = activeJobs.splice(Math.floor(random() * activeJobs.length), 1)[0];
            const result = random() < 0.6 ? settle(state, jobId) : release(state, jobId);
            state = result.state;
            allEntries.push(...result.entries);
          } else if (roll < 0.75) {
            const transactionId = `txn-${seed}-${txnCounter += 1}`;
            const seconds = random() < 0.5 ? 72_000 : 360_000;
            const result = buy(state, transactionId, seconds, step);
            state = result.state;
            allEntries.push(...result.entries);
            refundables.push({ transactionId, lotId: `lot-txn-${transactionId}`, seconds });
          } else if (roll < 0.9 && refundables.length > 0) {
            const target = refundables.splice(Math.floor(random() * refundables.length), 1)[0];
            const pct = Math.floor(random() * 100_001);
            const revoke = proratedRevocationSeconds(target.seconds, pct, 'REFUND_PRORATED');
            const result = refund(state, {
              lotId: target.lotId,
              transactionId: target.transactionId,
              revokeSeconds: revoke,
              idempotencyKey: `refund:txn:${target.transactionId}:${step}`,
              reasonCode: 'REFUND_PRORATED',
            });
            state = result.state;
            allEntries.push(...result.entries);
            if (random() < 0.4) {
              const reversal = refundReversal(state, {
                lotId: target.lotId,
                transactionId: target.transactionId,
                removedFromAvailable: result.removedFromAvailable,
                debtCreated: result.debtCreated,
                idempotencyKey: `refund_reversed:txn:${target.transactionId}:${step}`,
                reasonCode: 'REFUND_REVERSED',
              });
              state = reversal.state;
              allEntries.push(...reversal.entries);
            }
          }
        } catch (error) {
          if (!(error instanceof LedgerError) || error.code === 'internal') {
            throw error;
          }
          // insufficient/conflict outcomes are legitimate results of the walk.
        }
        assertInvariants(state);
      }

      // INV4: every entry's balance-after equals the prior snapshot + delta.
      let previous = { available: 0, reserved: 0, consumed: 0, debt: 0 };
      for (const entry of allEntries) {
        expect(entry.balanceAfter.available).toBe(previous.available + entry.delta.available);
        expect(entry.balanceAfter.reserved).toBe(previous.reserved + entry.delta.reserved);
        expect(entry.balanceAfter.consumed).toBe(previous.consumed + entry.delta.consumed);
        expect(entry.balanceAfter.debt).toBe(previous.debt + entry.delta.debt);
        previous = entry.balanceAfter;
      }
      expect(previous).toEqual(state.buckets);
    }
  });
});

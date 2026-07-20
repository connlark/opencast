// Pure ledger engine: overdraft-aware reserve/settle/release, FIFO lots,
// debt-first credits, refund revocation and reversal. No I/O — the
// PurchaseAccount DO loads state, calls these, and persists the result, so
// every rule here is property-testable in plain Node.
//
// Overdraft semantics:
// - buckets per account (integer seconds, each >= 0): available, reserved,
//   consumed, debt; DEBT_CAP = 10,800.
// - headroom = available + (DEBT_CAP - min(debt, DEBT_CAP)) - reserved.
// - reserve admitted iff seconds <= headroom.
// - settle n: reserved -= n; consume min(n, available) from available; the
//   remainder increases debt.
// - release n: reserved -= n only.
// - credit: repay debt first, remainder to available.
// - refund revocation: from the lot's still-available seconds first; the
//   shortfall becomes debt and MAY exceed DEBT_CAP. Any unreserved available
//   seconds in other lots immediately repay that debt, making refund/purchase
//   ordering immaterial. Reserved seconds are never taken from active jobs.
//
// Invariants asserted after every mutation:
//   INV1 account.available == sum(lot.available)
//   INV2 account.reserved  == sum(active reservation.reserved)
//   INV3 every bucket >= 0
//   INV4 each ledger entry's balance-after == balance-before + deltas
//        (enforced by construction: entries carry cumulative snapshots)
//   INV5 per lot: available + consumed + revoked == granted, each >= 0

import { DEBT_CAP_SECONDS } from './catalog';

export interface Buckets {
  available: number;
  reserved: number;
  consumed: number;
  debt: number;
}

export interface Lot {
  lotId: string;
  kind: 'free' | 'purchase' | 'admin_adjustment';
  transactionId: string | null;
  productId: string | null;
  granted: number;
  available: number;
  /** Seconds of this lot spoken for by active reservations (annotation only;
   * `available` does not decrease until settle). */
  reserved: number;
  consumed: number;
  revoked: number;
  createdAt: number;
}

export interface LotAllocation {
  lotId: string;
  seconds: number;
}

export interface Reservation {
  jobId: string;
  reservedSeconds: number;
  allocations: LotAllocation[];
  state: 'reserved' | 'settled' | 'released';
}

export interface LedgerState {
  buckets: Buckets;
  lots: Lot[];
  reservations: Record<string, Reservation>;
}

export interface Delta {
  available: number;
  reserved: number;
  consumed: number;
  debt: number;
}

export interface LedgerEntryDraft {
  idempotencyKey: string;
  operation:
    | 'grant'
    | 'debt_repayment'
    | 'reserve'
    | 'settle'
    | 'release'
    | 'refund'
    | 'refund_reversed';
  lotId: string | null;
  transactionId: string | null;
  jobId: string | null;
  delta: Delta;
  balanceAfter: Buckets;
  reasonCode: string | null;
}

export type LedgerErrorCode =
  | 'insufficient'
  | 'reservation_not_found'
  | 'conflict'
  | 'internal';

export class LedgerError extends Error {
  readonly code: LedgerErrorCode;

  constructor(code: LedgerErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}

export interface MutationResult {
  state: LedgerState;
  entries: LedgerEntryDraft[];
}

export function emptyState(): LedgerState {
  return {
    buckets: { available: 0, reserved: 0, consumed: 0, debt: 0 },
    lots: [],
    reservations: {},
  };
}

export function headroom(buckets: Buckets): number {
  return (
    buckets.available + (DEBT_CAP_SECONDS - Math.min(buckets.debt, DEBT_CAP_SECONDS)) - buckets.reserved
  );
}

function cloneState(state: LedgerState): LedgerState {
  return {
    buckets: { ...state.buckets },
    lots: state.lots.map((lot) => ({ ...lot })),
    reservations: Object.fromEntries(
      Object.entries(state.reservations).map(([jobId, reservation]) => [
        jobId,
        { ...reservation, allocations: reservation.allocations.map((entry) => ({ ...entry })) },
      ]),
    ),
  };
}

function requireInteger(value: number, label: string): void {
  if (!Number.isSafeInteger(value)) {
    throw new LedgerError('internal', `${label} must be a safe integer`);
  }
}

export function assertInvariants(state: LedgerState): void {
  const { buckets, lots, reservations } = state;
  for (const [name, value] of Object.entries(buckets)) {
    requireInteger(value, `bucket ${name}`);
    if (value < 0) {
      throw new LedgerError('internal', `invariant: bucket ${name} is negative (${value})`);
    }
  }
  let lotAvailable = 0;
  for (const lot of lots) {
    for (const field of ['granted', 'available', 'reserved', 'consumed', 'revoked'] as const) {
      requireInteger(lot[field], `lot ${lot.lotId} ${field}`);
      if (lot[field] < 0) {
        throw new LedgerError('internal', `invariant: lot ${lot.lotId} ${field} negative`);
      }
    }
    if (lot.available + lot.consumed + lot.revoked !== lot.granted) {
      throw new LedgerError(
        'internal',
        `invariant: lot ${lot.lotId} buckets do not sum to granted`,
      );
    }
    lotAvailable += lot.available;
  }
  if (lotAvailable !== buckets.available) {
    throw new LedgerError('internal', 'invariant: account available != sum of lot available');
  }
  let activeReserved = 0;
  for (const reservation of Object.values(reservations)) {
    if (reservation.state === 'reserved') {
      activeReserved += reservation.reservedSeconds;
    }
  }
  if (activeReserved !== buckets.reserved) {
    throw new LedgerError('internal', 'invariant: account reserved != sum of active reservations');
  }
}

function applyDelta(buckets: Buckets, delta: Delta): Buckets {
  return {
    available: buckets.available + delta.available,
    reserved: buckets.reserved + delta.reserved,
    consumed: buckets.consumed + delta.consumed,
    debt: buckets.debt + delta.debt,
  };
}

const ZERO_DELTA: Delta = { available: 0, reserved: 0, consumed: 0, debt: 0 };

export interface DebtNormalizationInput {
  idempotencyKeyBase: string;
  reasonCode: string;
}

/**
 * Repay existing debt from unreserved available lots, FIFO. This is the
 * normalization half of the debt-first credit rule: a refund can create debt
 * after a newer purchase was already credited, so the same net result must be
 * reached regardless of whether the refund or purchase arrives first.
 */
export function normalizeDebtAgainstAvailable(
  state: LedgerState,
  input: DebtNormalizationInput,
): MutationResult {
  const next = cloneState(state);
  const entries: LedgerEntryDraft[] = [];
  let running = next.buckets;

  for (const lot of next.lots) {
    if (running.debt === 0) {
      break;
    }
    // A refund can shrink the originally allocated lot below an active
    // reservation without reallocating that annotation to another lot. The
    // account-wide ceiling therefore protects every reserved second even if
    // per-lot allocations are temporarily stale until settle/release.
    const unreservedAccountAvailable = Math.max(0, running.available - running.reserved);
    const unreservedAvailable = Math.max(0, lot.available - lot.reserved);
    const repay = Math.min(running.debt, unreservedAvailable, unreservedAccountAvailable);
    if (repay === 0) {
      continue;
    }

    lot.available -= repay;
    lot.consumed += repay;
    const delta: Delta = { ...ZERO_DELTA, available: -repay, debt: -repay };
    running = applyDelta(running, delta);
    entries.push({
      idempotencyKey: `${input.idempotencyKeyBase}:lot:${lot.lotId}`,
      operation: 'debt_repayment',
      lotId: lot.lotId,
      transactionId: lot.transactionId,
      jobId: null,
      delta,
      balanceAfter: { ...running },
      reasonCode: input.reasonCode,
    });
  }

  next.buckets = running;
  assertInvariants(next);
  return { state: next, entries };
}

export interface CreditInput {
  lotId: string;
  kind: Lot['kind'];
  transactionId: string | null;
  productId: string | null;
  grantedSeconds: number;
  idempotencyKeyBase: string;
  reasonCode: string;
  now: number;
}

/** Grant a new credit lot; debt is repaid first, remainder becomes available. */
export function credit(state: LedgerState, input: CreditInput): MutationResult {
  if (!Number.isSafeInteger(input.grantedSeconds) || input.grantedSeconds <= 0) {
    throw new LedgerError('conflict', 'granted seconds must be a positive integer');
  }
  const next = cloneState(state);
  const repay = Math.min(input.grantedSeconds, next.buckets.debt);
  const remainder = input.grantedSeconds - repay;

  const lot: Lot = {
    lotId: input.lotId,
    kind: input.kind,
    transactionId: input.transactionId,
    productId: input.productId,
    granted: input.grantedSeconds,
    available: remainder,
    reserved: 0,
    consumed: repay,
    revoked: 0,
    createdAt: input.now,
  };
  next.lots.push(lot);

  const entries: LedgerEntryDraft[] = [];
  let running = next.buckets;

  const grantDelta: Delta = { ...ZERO_DELTA, available: input.grantedSeconds };
  running = applyDelta(running, grantDelta);
  entries.push({
    idempotencyKey: input.idempotencyKeyBase,
    operation: 'grant',
    lotId: lot.lotId,
    transactionId: input.transactionId,
    jobId: null,
    delta: grantDelta,
    balanceAfter: { ...running },
    reasonCode: input.reasonCode,
  });

  if (repay > 0) {
    const repayDelta: Delta = { ...ZERO_DELTA, available: -repay, debt: -repay };
    running = applyDelta(running, repayDelta);
    entries.push({
      idempotencyKey: `${input.idempotencyKeyBase}:debt_repayment`,
      operation: 'debt_repayment',
      lotId: lot.lotId,
      transactionId: input.transactionId,
      jobId: null,
      delta: repayDelta,
      balanceAfter: { ...running },
      reasonCode: input.reasonCode,
    });
  }

  next.buckets = running;
  assertInvariants(next);
  return { state: next, entries };
}

export interface ReserveResult extends MutationResult {
  alreadyExisted: boolean;
}

/** Reserve seconds for a job; idempotent per job; overdraft-aware admission. */
export function reserve(
  state: LedgerState,
  jobId: string,
  seconds: number,
  now: number,
): ReserveResult {
  if (!Number.isSafeInteger(seconds) || seconds <= 0) {
    throw new LedgerError('conflict', 'seconds must be a positive integer');
  }
  const existing = state.reservations[jobId];
  if (existing) {
    if (existing.state === 'reserved' || existing.state === 'settled') {
      return { state: cloneState(state), entries: [], alreadyExisted: true };
    }
    throw new LedgerError('conflict', `reservation already ${existing.state}`);
  }
  if (seconds > headroom(state.buckets)) {
    throw new LedgerError('insufficient', 'insufficient headroom');
  }

  const next = cloneState(state);
  const allocations: LotAllocation[] = [];
  let remaining = seconds;
  for (const lot of next.lots) {
    if (remaining === 0) {
      break;
    }
    const free = lot.available - lot.reserved;
    if (free <= 0) {
      continue;
    }
    const take = Math.min(free, remaining);
    lot.reserved += take;
    allocations.push({ lotId: lot.lotId, seconds: take });
    remaining -= take;
  }
  // `remaining` is the overdraft portion: admission guaranteed it fits the
  // debt cap; it belongs to no lot until a future credit repays it.

  next.reservations[jobId] = {
    jobId,
    reservedSeconds: seconds,
    allocations,
    state: 'reserved',
  };
  const delta: Delta = { ...ZERO_DELTA, reserved: seconds };
  next.buckets = applyDelta(next.buckets, delta);
  assertInvariants(next);
  return {
    state: next,
    entries: [
      {
        idempotencyKey: `reserve:${jobId}`,
        operation: 'reserve',
        lotId: null,
        transactionId: null,
        jobId,
        delta,
        balanceAfter: { ...next.buckets },
        reasonCode: null,
      },
    ],
    alreadyExisted: false,
  };
}

/**
 * Settle a reservation in full: consume from available (FIFO over the
 * reservation's lots, then any lot), remainder becomes debt.
 */
export function settle(state: LedgerState, jobId: string): MutationResult {
  const reservation = state.reservations[jobId];
  if (!reservation) {
    throw new LedgerError('reservation_not_found', 'reservation not found');
  }
  if (reservation.state === 'settled') {
    return { state: cloneState(state), entries: [] };
  }
  if (reservation.state === 'released') {
    throw new LedgerError('conflict', 'cannot settle a released reservation');
  }

  const next = cloneState(state);
  const target = next.reservations[jobId]!;
  const n = target.reservedSeconds;
  const fromAvailable = Math.min(n, next.buckets.available);

  // Release lot reservation annotations, consuming allocated lots first.
  let toConsume = fromAvailable;
  const lotById = new Map(next.lots.map((lot) => [lot.lotId, lot]));
  for (const allocation of target.allocations) {
    const lot = lotById.get(allocation.lotId);
    if (!lot) {
      throw new LedgerError('internal', 'reservation references a missing lot');
    }
    lot.reserved = Math.max(0, lot.reserved - allocation.seconds);
    const consume = Math.min(allocation.seconds, lot.available, toConsume);
    lot.available -= consume;
    lot.consumed += consume;
    toConsume -= consume;
  }
  // A refund may have shrunk an allocated lot below its allocation; the
  // account-level rule still consumes min(n, available), so walk the rest
  // FIFO for any remainder.
  for (const lot of next.lots) {
    if (toConsume === 0) {
      break;
    }
    const consume = Math.min(lot.available, toConsume);
    lot.available -= consume;
    lot.consumed += consume;
    toConsume -= consume;
  }
  if (toConsume !== 0) {
    throw new LedgerError('internal', 'settle could not consume from available');
  }

  target.state = 'settled';
  target.allocations = [];
  const delta: Delta = {
    available: -fromAvailable,
    reserved: -n,
    consumed: n,
    debt: n - fromAvailable,
  };
  next.buckets = applyDelta(next.buckets, delta);
  assertInvariants(next);
  return {
    state: next,
    entries: [
      {
        idempotencyKey: `settle:${jobId}`,
        operation: 'settle',
        lotId: null,
        transactionId: null,
        jobId,
        delta,
        balanceAfter: { ...next.buckets },
        reasonCode: null,
      },
    ],
  };
}

/** Idempotent release; releasing a settled or unknown reservation is a no-op. */
export function release(state: LedgerState, jobId: string): MutationResult {
  const reservation = state.reservations[jobId];
  if (!reservation || reservation.state === 'released' || reservation.state === 'settled') {
    return { state: cloneState(state), entries: [] };
  }

  const next = cloneState(state);
  const target = next.reservations[jobId]!;
  const lotById = new Map(next.lots.map((lot) => [lot.lotId, lot]));
  for (const allocation of target.allocations) {
    const lot = lotById.get(allocation.lotId);
    if (lot) {
      lot.reserved = Math.max(0, lot.reserved - allocation.seconds);
    }
  }
  const n = target.reservedSeconds;
  target.state = 'released';
  target.allocations = [];
  const delta: Delta = { ...ZERO_DELTA, reserved: -n };
  next.buckets = applyDelta(next.buckets, delta);
  assertInvariants(next);
  const releaseEntry: LedgerEntryDraft = {
    idempotencyKey: `release:${jobId}`,
    operation: 'release',
    lotId: null,
    transactionId: null,
    jobId,
    delta,
    balanceAfter: { ...next.buckets },
    reasonCode: null,
  };
  const normalized = normalizeDebtAgainstAvailable(next, {
    idempotencyKeyBase: `release:${jobId}:debt_repayment`,
    reasonCode: 'refund_debt_normalization',
  });
  return {
    state: normalized.state,
    entries: [releaseEntry, ...normalized.entries],
  };
}

export interface RefundInput {
  lotId: string;
  transactionId: string;
  revokeSeconds: number;
  idempotencyKey: string;
  reasonCode: string;
}

export interface RefundResult extends MutationResult {
  removedFromAvailable: number;
  debtCreated: number;
  /** The clamped amount actually revoked (never exceeds the lot's unrevoked). */
  revokedSeconds: number;
}

/**
 * Apply a refund revocation to a purchase lot: still-available seconds are
 * removed first; the already-consumed shortfall becomes debt (which may
 * exceed DEBT_CAP for refund-origin debt).
 */
export function refund(state: LedgerState, input: RefundInput): RefundResult {
  if (!Number.isSafeInteger(input.revokeSeconds) || input.revokeSeconds < 0) {
    throw new LedgerError('conflict', 'revoke seconds must be a non-negative integer');
  }
  const next = cloneState(state);
  const lot = next.lots.find((candidate) => candidate.lotId === input.lotId);
  if (!lot) {
    throw new LedgerError('conflict', 'refund references an unknown lot');
  }
  const unrevoked = lot.available + lot.consumed;
  const revoke = Math.min(input.revokeSeconds, unrevoked);
  const fromAvailable = Math.min(lot.available, revoke);
  const shortfall = revoke - fromAvailable;

  lot.available -= fromAvailable;
  lot.consumed -= shortfall;
  lot.revoked += revoke;
  lot.reserved = Math.min(lot.reserved, lot.available);

  const delta: Delta = { ...ZERO_DELTA, available: -fromAvailable, debt: shortfall };
  next.buckets = applyDelta(next.buckets, delta);
  assertInvariants(next);
  const refundEntry: LedgerEntryDraft = {
    idempotencyKey: input.idempotencyKey,
    operation: 'refund',
    lotId: lot.lotId,
    transactionId: input.transactionId,
    jobId: null,
    delta,
    balanceAfter: { ...next.buckets },
    reasonCode: input.reasonCode,
  };
  const normalized = normalizeDebtAgainstAvailable(next, {
    idempotencyKeyBase: `${input.idempotencyKey}:debt_repayment`,
    reasonCode: 'refund_debt_normalization',
  });
  return {
    state: normalized.state,
    entries: [refundEntry, ...normalized.entries],
    removedFromAvailable: fromAvailable,
    debtCreated: shortfall,
    revokedSeconds: revoke,
  };
}

export interface RefundReversalInput {
  lotId: string;
  transactionId: string;
  /** Exactly what the matching refund removed/created (from its records). */
  removedFromAvailable: number;
  debtCreated: number;
  idempotencyKey: string;
  reasonCode: string;
}

/**
 * Reverse a refund: restore only what the matching refund removed. Debt the
 * refund created is cancelled where it still stands; where a later credit
 * already repaid it, the seconds return as available instead (the customer
 * paid twice otherwise).
 */
export function refundReversal(state: LedgerState, input: RefundReversalInput): MutationResult {
  const next = cloneState(state);
  const lot = next.lots.find((candidate) => candidate.lotId === input.lotId);
  if (!lot) {
    throw new LedgerError('conflict', 'refund reversal references an unknown lot');
  }
  const totalRevoked = input.removedFromAvailable + input.debtCreated;
  if (lot.revoked < totalRevoked) {
    throw new LedgerError('conflict', 'refund reversal exceeds recorded revocation');
  }
  const debtCancelled = Math.min(next.buckets.debt, input.debtCreated);
  const returnedAvailable = input.removedFromAvailable + (input.debtCreated - debtCancelled);

  lot.revoked -= totalRevoked;
  lot.available += returnedAvailable;
  lot.consumed += debtCancelled;

  const delta: Delta = { ...ZERO_DELTA, available: returnedAvailable, debt: -debtCancelled };
  next.buckets = applyDelta(next.buckets, delta);
  assertInvariants(next);
  const reversalEntry: LedgerEntryDraft = {
    idempotencyKey: input.idempotencyKey,
    operation: 'refund_reversed',
    lotId: lot.lotId,
    transactionId: input.transactionId,
    jobId: null,
    delta,
    balanceAfter: { ...next.buckets },
    reasonCode: input.reasonCode,
  };
  const normalized = normalizeDebtAgainstAvailable(next, {
    idempotencyKeyBase: `${input.idempotencyKey}:debt_repayment`,
    reasonCode: 'refund_debt_normalization',
  });
  return {
    state: normalized.state,
    entries: [reversalEntry, ...normalized.entries],
  };
}

/** Prorated consumable refund amount: floor(granted × pct / 100000). */
export function proratedRevocationSeconds(
  grantedSeconds: number,
  revocationPercentage: number | undefined,
  revocationType: string | undefined,
): number {
  if (revocationType === 'REFUND_PRORATED' && typeof revocationPercentage === 'number') {
    const clamped = Math.max(0, Math.min(100_000, Math.floor(revocationPercentage)));
    return Math.floor((grantedSeconds * clamped) / 100_000);
  }
  // Absent or full/family revocation types revoke the whole grant.
  return grantedSeconds;
}

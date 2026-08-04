// Request handlers behind the service binding. Verification happens here
// (worker layer, official Apple library); the Account DO applies serialized
// money mutations; D1 holds cross-account indexes.

import type { JWSTransactionDecodedPayload } from '@apple/app-store-server-library';
import {
  AppleVerificationError,
  LaneConfigError,
  laneConfigFromEnv,
  loadAppleLibrary,
  makeApiClient,
  verifyAppTransaction,
  verifyNotification,
  verifyTransaction,
  type LaneConfig,
} from './apple';
import { assertCatalogIntegrity, CATALOG, EXPECTED_CATALOG_SHA256, grantSecondsForProduct } from './catalog';
import { notificationEnvironmentMismatchMessage, sendPushoverAlert } from './alerts';
import * as d1 from './d1';
import {
  appTransactionLookupHmac,
  decryptIdentifier,
  encryptIdentifier,
  randomToken,
  randomUuid,
  sha256Hex,
} from './identity';
import type {
  Balance,
  BootstrapRequest,
  Env,
  RedeemOutcome,
  RedeemRequest,
} from './types';
import {
  ERROR_ACCOUNT_NOT_FOUND,
  ERROR_ENVIRONMENT_MISMATCH,
  ERROR_INTERNAL,
  ERROR_INVALID_PRODUCT,
  ERROR_INVALID_REQUEST,
  ERROR_INVALID_TRANSACTION,
  ERROR_NOTIFICATION_INVALID,
  ERROR_TOKEN_MISMATCH,
  ERROR_TRANSACTION_ACCOUNT_MISMATCH,
  ERROR_WORKER_MISCONFIGURED,
  CREDIT_ERROR_CONFLICT,
  CREDIT_ERROR_RESERVATION_NOT_FOUND,
  SCHEMA_VERSION,
} from './types';

const MAX_JWS_BYTES = 32 * 1024;
const MAX_NOTIFICATION_BODY_BYTES = 256 * 1024;
const MAX_RECONCILE_PAGES_PER_RUN = 10;
const MAX_QUANTITY = 10;

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

export function errorJson(status: number, code: string, detail?: string): Response {
  return json(status, detail ? { error: code, detail } : { error: code });
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function accountStub(env: Env, accountId: string): DurableObjectStub {
  return env.PURCHASE_ACCOUNT.get(env.PURCHASE_ACCOUNT.idFromName(accountId));
}

async function doPost(stub: DurableObjectStub, path: string, body: unknown): Promise<Response> {
  return stub.fetch(`https://purchase-account.opencast.internal${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

function requireIdentitySecrets(env: Env): { hmacKey: string; encryptionKey: string } {
  if (!env.APP_TX_HMAC_KEY || !env.APP_TX_ENCRYPTION_KEY) {
    throw new AppleVerificationError(
      ERROR_WORKER_MISCONFIGURED,
      503,
      'identity key secrets are not configured',
    );
  }
  return { hmacKey: env.APP_TX_HMAC_KEY, encryptionKey: env.APP_TX_ENCRYPTION_KEY };
}

function mapHandledError(error: unknown): Response | null {
  if (error instanceof AppleVerificationError) {
    return errorJson(error.status, error.code);
  }
  if (error instanceof LaneConfigError) {
    return errorJson(503, ERROR_WORKER_MISCONFIGURED, error.message);
  }
  return null;
}

export async function handleBootstrap(env: Env, request: Request): Promise<Response> {
  let body: BootstrapRequest;
  try {
    body = (await request.json()) as BootstrapRequest;
  } catch {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }
  if (
    body.schema_version !== SCHEMA_VERSION ||
    typeof body.install_key !== 'string' ||
    body.install_key.length === 0 ||
    body.install_key.length > 256 ||
    typeof body.app_transaction_jws !== 'string' ||
    body.app_transaction_jws.length === 0 ||
    body.app_transaction_jws.length > MAX_JWS_BYTES
  ) {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }

  try {
    await assertCatalogIntegrity();
    const config = laneConfigFromEnv(env);
    const keys = requireIdentitySecrets(env);
    const decoded = await verifyAppTransaction(config, body.app_transaction_jws);
    const appTransactionId = decoded.appTransactionId!;
    const hmac = await appTransactionLookupHmac(
      keys.hmacKey,
      config.storekitEnvironment,
      appTransactionId,
    );
    const now = nowSeconds();

    let account = await d1.accountByHmac(env.PURCHASE_DB, hmac);
    if (!account) {
      account = await d1.ensureAccount(
        env.PURCHASE_DB,
        {
          app_tx_hmac: hmac,
          account_id: `pacct-${randomToken(12)}`,
          app_transaction_id_encrypted: await encryptIdentifier(keys.encryptionKey, appTransactionId),
          environment: config.storekitEnvironment,
          status: 'active',
        },
        now,
      );
    }
    if (account.environment !== config.storekitEnvironment) {
      return errorJson(409, ERROR_TRANSACTION_ACCOUNT_MISMATCH, 'environment mismatch for identity');
    }

    // DO init is idempotent and issues the free grant exactly once; the DO's
    // stored token is authoritative when a concurrent bootstrap raced us.
    const initResponse = await doPost(accountStub(env, account.account_id), '/init', {
      account_id: account.account_id,
      app_account_token: randomUuid(),
      environment: config.storekitEnvironment,
      app_tx_hmac: hmac,
    });
    if (!initResponse.ok) {
      const detail = await initResponse.text();
      return errorJson(500, ERROR_INTERNAL, `account init failed: ${detail.slice(0, 200)}`);
    }
    const init = (await initResponse.json()) as { balance: Balance; app_account_token: string };

    await d1.upsertTokenIndex(env.PURCHASE_DB, init.app_account_token, account.account_id, now);
    await d1.upsertInstallLink(env.PURCHASE_DB, body.install_key, account.account_id, now);
    await d1.scheduleReconciliation(
      env.PURCHASE_DB,
      account.account_id,
      config.storekitEnvironment,
      now,
      now,
    );

    return json(200, {
      schema_version: SCHEMA_VERSION,
      account_id: account.account_id,
      app_account_token: init.app_account_token,
      balance: init.balance,
      catalog: CATALOG,
      catalog_sha256: EXPECTED_CATALOG_SHA256,
    });
  } catch (error) {
    const handled = mapHandledError(error);
    if (handled) {
      return handled;
    }
    throw error;
  }
}

// --- Credit-authority seam (bootstrap/balance/reserve/settle/release) ------

export async function handleBalance(env: Env, request: Request): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { account_id?: string } | null;
  if (!body || typeof body.account_id !== 'string' || body.account_id.length === 0) {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }
  const response = await doPost(accountStub(env, body.account_id), '/balance', {});
  return passthrough(response);
}

export async function handleReserve(env: Env, request: Request): Promise<Response> {
  const body = (await request.json().catch(() => null)) as {
    account_id?: string;
    job_id?: string;
    seconds?: number;
  } | null;
  if (
    !body ||
    typeof body.account_id !== 'string' ||
    body.account_id.length === 0 ||
    typeof body.job_id !== 'string' ||
    body.job_id.length === 0 ||
    typeof body.seconds !== 'number'
  ) {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }
  // PW-2: admit on the account DO first; only a successful reserve may pin
  // the job_id → account index. The old upsert-before-admission pinned the
  // job to the first caller even when its reserve was refused.
  const response = await doPost(accountStub(env, body.account_id), '/reserve', {
    job_id: body.job_id,
    seconds: body.seconds,
  });
  if (response.ok) {
    const owner = await d1.upsertReservationIndex(
      env.PURCHASE_DB,
      body.job_id,
      body.account_id,
      nowSeconds(),
    );
    if (owner !== body.account_id) {
      // The job id is already pinned to a different account (requires a
      // gateway defect to reach). Undo this account's admission so the
      // reservation is not stranded, and refuse loudly.
      await doPost(accountStub(env, body.account_id), '/release', { job_id: body.job_id });
      return errorJson(409, CREDIT_ERROR_CONFLICT);
    }
  }
  return passthrough(response);
}

export async function handleSettle(env: Env, request: Request): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { job_id?: string } | null;
  if (!body || typeof body.job_id !== 'string' || body.job_id.length === 0) {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }
  const accountId = await d1.accountForReservation(env.PURCHASE_DB, body.job_id);
  if (!accountId) {
    return errorJson(404, CREDIT_ERROR_RESERVATION_NOT_FOUND);
  }
  const response = await doPost(accountStub(env, accountId), '/settle', { job_id: body.job_id });
  return passthrough(response);
}

export async function handleRelease(env: Env, request: Request): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { job_id?: string } | null;
  if (!body || typeof body.job_id !== 'string' || body.job_id.length === 0) {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }
  const accountId = await d1.accountForReservation(env.PURCHASE_DB, body.job_id);
  if (!accountId) {
    // Idempotent no-op, mirroring DevCreditAuthority::release.
    return json(200, { released: false });
  }
  const response = await doPost(accountStub(env, accountId), '/release', { job_id: body.job_id });
  return passthrough(response);
}

/** Content-free account diagnostics for tests and audited operator reads. */
export async function handleSnapshot(env: Env, request: Request): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { account_id?: string } | null;
  if (!body || typeof body.account_id !== 'string' || body.account_id.length === 0) {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }
  const response = await doPost(accountStub(env, body.account_id), '/snapshot', {});
  return passthrough(response);
}

async function passthrough(response: Response): Promise<Response> {
  return new Response(await response.text(), {
    status: response.status,
    headers: { 'content-type': 'application/json' },
  });
}

// --- Purchase crediting (redeem, notification, reconciliation) -------------

interface CreditOutcome {
  status: number;
  body: {
    outcome?: RedeemOutcome | string;
    transaction_id?: string;
    credited_seconds?: number;
    balance?: Balance;
    error?: string;
  };
  accountId: string | null;
}

/**
 * Shared exactly-once crediting for a verified consumable transaction.
 * `expectedAccountId` is set on the redeem path; notification/reconciliation
 * resolve the account from the token or identity indexes.
 */
async function creditVerifiedTransaction(
  env: Env,
  config: LaneConfig,
  decoded: JWSTransactionDecodedPayload,
  jwsSha256: string,
  expectedAccountId: string | null,
  requireToken: boolean,
): Promise<CreditOutcome> {
  const transactionId = (decoded.transactionId ?? '').trim();
  if (transactionId.length === 0) {
    return { status: 400, body: { error: ERROR_INVALID_TRANSACTION }, accountId: null };
  }
  if ((decoded.type ?? '') !== 'Consumable') {
    return { status: 400, body: { error: ERROR_INVALID_TRANSACTION }, accountId: null };
  }
  const grant = grantSecondsForProduct(decoded.productId ?? '');
  if (grant === undefined) {
    return { status: 400, body: { error: ERROR_INVALID_PRODUCT }, accountId: null };
  }
  const quantityRaw = decoded.quantity ?? 1;
  if (!Number.isSafeInteger(quantityRaw) || quantityRaw < 1 || quantityRaw > MAX_QUANTITY) {
    return { status: 400, body: { error: ERROR_INVALID_TRANSACTION }, accountId: null };
  }
  const creditedSeconds = grant * quantityRaw;

  const token = (decoded.appAccountToken ?? '').trim();
  if (requireToken && token.length === 0) {
    return { status: 409, body: { error: ERROR_TOKEN_MISMATCH }, accountId: null };
  }

  // Resolve the owning account.
  let accountId = expectedAccountId;
  if (!accountId) {
    accountId = await d1.accountForTransaction(env.PURCHASE_DB, transactionId);
  }
  if (!accountId && token.length > 0) {
    accountId = await d1.accountForToken(env.PURCHASE_DB, token);
  }
  if (!accountId && decoded.appTransactionId && env.APP_TX_HMAC_KEY) {
    const hmac = await appTransactionLookupHmac(
      env.APP_TX_HMAC_KEY,
      config.storekitEnvironment,
      decoded.appTransactionId,
    );
    const account = await d1.accountByHmac(env.PURCHASE_DB, hmac);
    accountId = account?.account_id ?? null;
  }
  if (!accountId) {
    return { status: 404, body: { error: ERROR_ACCOUNT_NOT_FOUND }, accountId: null };
  }

  if (expectedAccountId) {
    if (token.length > 0) {
      const tokenOwner = await d1.accountForToken(env.PURCHASE_DB, token);
      if (tokenOwner !== expectedAccountId) {
        return { status: 409, body: { error: ERROR_TOKEN_MISMATCH }, accountId: expectedAccountId };
      }
    }
    if (decoded.appTransactionId && env.APP_TX_HMAC_KEY) {
      const hmac = await appTransactionLookupHmac(
        env.APP_TX_HMAC_KEY,
        config.storekitEnvironment,
        decoded.appTransactionId,
      );
      const account = await d1.accountByHmac(env.PURCHASE_DB, hmac);
      if (account && account.account_id !== expectedAccountId) {
        return {
          status: 409,
          body: { error: ERROR_TRANSACTION_ACCOUNT_MISMATCH },
          accountId: expectedAccountId,
        };
      }
    }
  }

  const owner = await d1.claimTransaction(
    env.PURCHASE_DB,
    transactionId,
    accountId,
    config.storekitEnvironment,
    nowSeconds(),
  );
  if (owner !== accountId) {
    return { status: 409, body: { error: ERROR_TRANSACTION_ACCOUNT_MISMATCH }, accountId };
  }

  const response = await doPost(accountStub(env, accountId), '/credit', {
    transaction_id: transactionId,
    original_transaction_id: decoded.originalTransactionId ?? null,
    product_id: decoded.productId,
    grant_seconds: creditedSeconds,
    purchase_date: decoded.purchaseDate ?? null,
    storefront: decoded.storefront ?? null,
    quantity: quantityRaw,
    ownership_type: decoded.inAppOwnershipType ?? null,
    jws_sha256: jwsSha256,
    environment: config.storekitEnvironment,
    app_account_token: token.length > 0 ? token : null,
  });
  const body = (await response.json()) as CreditOutcome['body'];
  if (response.ok) {
    let outcome = body.outcome;
    if (outcome === 'refunded' || outcome === 'partially_refunded') {
      // The purchase was revoked: the app should finish without credit.
      outcome = 'refunded';
    } else if (outcome === 'refund_reversed') {
      // The refund was reversed, so the original credit stands.
      outcome = 'already_credited';
    }
    return {
      status: 200,
      body: {
        outcome: outcome as RedeemOutcome,
        transaction_id: transactionId,
        credited_seconds: body.credited_seconds ?? creditedSeconds,
        balance: body.balance,
      },
      accountId,
    };
  }
  return { status: response.status, body, accountId };
}

export async function handleRedeem(env: Env, request: Request): Promise<Response> {
  let body: RedeemRequest;
  try {
    body = (await request.json()) as RedeemRequest;
  } catch {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }
  if (
    body.schema_version !== SCHEMA_VERSION ||
    typeof body.account_id !== 'string' ||
    body.account_id.length === 0 ||
    typeof body.transaction_jws !== 'string' ||
    body.transaction_jws.length === 0 ||
    body.transaction_jws.length > MAX_JWS_BYTES
  ) {
    return errorJson(400, ERROR_INVALID_REQUEST);
  }

  try {
    await assertCatalogIntegrity();
    const config = laneConfigFromEnv(env);
    const account = await d1.accountById(env.PURCHASE_DB, body.account_id);
    if (!account) {
      return errorJson(404, ERROR_ACCOUNT_NOT_FOUND);
    }
    const decoded = await verifyTransaction(config, body.transaction_jws);
    const digest = await sha256Hex(body.transaction_jws);
    const outcome = await creditVerifiedTransaction(
      env,
      config,
      decoded,
      digest,
      body.account_id,
      true,
    );
    if (outcome.status === 200) {
      return json(200, { schema_version: SCHEMA_VERSION, ...outcome.body });
    }
    return json(outcome.status, outcome.body);
  } catch (error) {
    const handled = mapHandledError(error);
    if (handled) {
      return handled;
    }
    throw error;
  }
}

// --- App Store Server Notifications V2 --------------------------------------

export async function handleNotification(env: Env, request: Request): Promise<Response> {
  const raw = await request.text();
  if (raw.length === 0 || raw.length > MAX_NOTIFICATION_BODY_BYTES) {
    return errorJson(400, ERROR_NOTIFICATION_INVALID);
  }
  let signedPayload: string;
  try {
    const parsed = JSON.parse(raw) as { signedPayload?: string };
    if (typeof parsed.signedPayload !== 'string' || parsed.signedPayload.length === 0) {
      return errorJson(400, ERROR_NOTIFICATION_INVALID);
    }
    signedPayload = parsed.signedPayload;
  } catch {
    return errorJson(400, ERROR_NOTIFICATION_INVALID);
  }

  try {
    await assertCatalogIntegrity();
    const config = laneConfigFromEnv(env);
    // Verify the outer signed payload before reading ANY field; the library
    // also requires the signed environment/bundle to match this lane.
    let payload: Awaited<ReturnType<typeof verifyNotification>>;
    try {
      payload = await verifyNotification(config, signedPayload);
    } catch (error) {
      if (
        config.storekitEnvironment === 'Production' &&
        error instanceof AppleVerificationError &&
        (error.kind === 'invalid_environment' ||
          error.kind === 'invalid_app_identifier')
      ) {
        // Apple keeps the Sandbox notification URL on prod-staging. If one
        // nevertheless reaches production, prove it is genuinely
        // Apple-signed under Sandbox before recording/alerting. Never decode
        // or apply its transaction payload against production money. Apple's
        // verifier checks production appAppleId before environment, so a
        // legitimate Sandbox payload that omits appAppleId reaches this path
        // as `invalid_app_identifier`; the Sandbox verification below is the
        // authoritative discriminator.
        const sandboxPayload = await verifyNotification(
          { ...config, storekitEnvironment: 'Sandbox', appAppleId: undefined },
          signedPayload,
        );
        return recordProductionEnvironmentMismatch(env, raw, sandboxPayload);
      }
      throw error;
    }
    const uuid = (payload.notificationUUID ?? '').trim();
    const notificationType = String(payload.notificationType ?? '');
    if (uuid.length === 0 || notificationType.length === 0) {
      return errorJson(400, ERROR_NOTIFICATION_INVALID);
    }
    const now = nowSeconds();

    const existing = await d1.notificationReceipt(env.PURCHASE_DB, uuid);
    if (existing && ['processed', 'recorded', 'unsupported', 'unmatched'].includes(existing.state)) {
      return json(200, { state: existing.state, duplicate: true });
    }
    await d1.recordNotificationAttempt(
      env.PURCHASE_DB,
      {
        uuid,
        payloadSha256: await sha256Hex(raw),
        notificationType,
        subtype: payload.subtype ? String(payload.subtype) : null,
        environment: config.storekitEnvironment,
        transactionId: null,
        accountId: null,
      },
      now,
    );

    const finish = async (
      state: 'processed' | 'recorded' | 'unmatched' | 'unsupported' | 'failed',
      errorCode: string | null,
      accountId?: string | null,
      transactionId?: string | null,
    ): Promise<Response> => {
      await d1.finishNotification(env.PURCHASE_DB, uuid, state, errorCode, nowSeconds(), accountId, transactionId);
      if (state === 'failed') {
        return errorJson(503, errorCode ?? ERROR_INTERNAL);
      }
      return json(200, { state, notification_type: notificationType });
    };

    const signedTransactionInfo = payload.data?.signedTransactionInfo;

    switch (notificationType) {
      case 'ONE_TIME_CHARGE': {
        if (!signedTransactionInfo) {
          return finish('failed', ERROR_NOTIFICATION_INVALID);
        }
        const decoded = await verifyTransaction(config, signedTransactionInfo);
        const digest = await sha256Hex(signedTransactionInfo);
        const outcome = await creditVerifiedTransaction(env, config, decoded, digest, null, false);
        if (outcome.status === 200) {
          return finish('processed', null, outcome.accountId, outcome.body.transaction_id);
        }
        if (outcome.status === 404) {
          // No bootstrapped account yet; reconciliation is the backstop.
          return finish('unmatched', outcome.body.error ?? null, null, decoded.transactionId ?? null);
        }
        if (outcome.status >= 500) {
          return finish('failed', outcome.body.error ?? ERROR_INTERNAL);
        }
        return finish('recorded', outcome.body.error ?? null, outcome.accountId, decoded.transactionId ?? null);
      }
      case 'REFUND': {
        if (!signedTransactionInfo) {
          return finish('failed', ERROR_NOTIFICATION_INVALID);
        }
        const decoded = await verifyTransaction(config, signedTransactionInfo);
        const transactionId = (decoded.transactionId ?? '').trim();
        const accountId = await d1.accountForTransaction(env.PURCHASE_DB, transactionId);
        if (!accountId) {
          return finish('unmatched', 'transaction_not_found', null, transactionId);
        }
        const response = await doPost(accountStub(env, accountId), '/refund', {
          transaction_id: transactionId,
          revocation_type: decoded.revocationType ?? null,
          revocation_percentage: decoded.revocationPercentage ?? null,
          revocation_date: decoded.revocationDate ?? null,
          revocation_reason: decoded.revocationReason !== undefined ? String(decoded.revocationReason) : null,
        });
        if (!response.ok && response.status !== 404) {
          return finish('failed', ERROR_INTERNAL);
        }
        return finish(response.ok ? 'processed' : 'unmatched', null, accountId, transactionId);
      }
      case 'REFUND_REVERSED': {
        if (!signedTransactionInfo) {
          return finish('failed', ERROR_NOTIFICATION_INVALID);
        }
        const decoded = await verifyTransaction(config, signedTransactionInfo);
        const transactionId = (decoded.transactionId ?? '').trim();
        const accountId = await d1.accountForTransaction(env.PURCHASE_DB, transactionId);
        if (!accountId) {
          return finish('unmatched', 'transaction_not_found', null, transactionId);
        }
        const response = await doPost(accountStub(env, accountId), '/refund-reversed', {
          transaction_id: transactionId,
        });
        if (!response.ok && response.status !== 404) {
          return finish('failed', ERROR_INTERNAL);
        }
        return finish(response.ok ? 'processed' : 'unmatched', null, accountId, transactionId);
      }
      case 'REFUND_DECLINED':
      case 'CONSUMPTION_REQUEST': {
        // Verify + record only. CONSUMPTION_REQUEST is deliberately never
        // answered (no consent flow in this pass; Apple permits no response).
        let transactionId: string | null = null;
        if (signedTransactionInfo) {
          const decoded = await verifyTransaction(config, signedTransactionInfo);
          transactionId = decoded.transactionId ?? null;
        }
        const accountId = transactionId
          ? await d1.accountForTransaction(env.PURCHASE_DB, transactionId)
          : null;
        return finish('recorded', null, accountId, transactionId);
      }
      case 'TEST':
        return finish('recorded', null);
      default:
        // Unknown/unsupported future type: verified, recorded, acknowledged
        // without mutating money; the receipts table is the alert surface.
        console.log(`purchase-notification-unsupported type=${notificationType}`);
        return finish('unsupported', null);
    }
  } catch (error) {
    const handled = mapHandledError(error);
    if (handled) {
      return handled;
    }
    throw error;
  }
}

async function recordProductionEnvironmentMismatch(
  env: Env,
  raw: string,
  payload: Awaited<ReturnType<typeof verifyNotification>>,
): Promise<Response> {
  const uuid = (payload.notificationUUID ?? '').trim();
  const notificationType = String(payload.notificationType ?? '');
  if (uuid.length === 0 || notificationType.length === 0) {
    return errorJson(400, ERROR_NOTIFICATION_INVALID);
  }
  const existing = await d1.notificationReceipt(env.PURCHASE_DB, uuid);
  if (existing && ['processed', 'recorded', 'unsupported', 'unmatched'].includes(existing.state)) {
    return json(200, { state: existing.state, duplicate: true });
  }
  const now = nowSeconds();
  await d1.recordNotificationAttempt(
    env.PURCHASE_DB,
    {
      uuid,
      payloadSha256: await sha256Hex(raw),
      notificationType,
      subtype: payload.subtype ? String(payload.subtype) : null,
      environment: 'Sandbox',
      transactionId: null,
      accountId: null,
    },
    now,
  );

  try {
    await sendPushoverAlert(
      env,
      `OpenCast purchase alert (${env.LANE})`,
      notificationEnvironmentMismatchMessage(),
    );
    await d1.incrementOpsCounter(env.PURCHASE_DB, 'notification_environment_mismatch', 1, now);
    await d1.incrementOpsCounter(env.PURCHASE_DB, 'pushover_alerts_sent', 1, now);
    await d1.finishNotification(
      env.PURCHASE_DB,
      uuid,
      'recorded',
      ERROR_ENVIRONMENT_MISMATCH,
      nowSeconds(),
    );
    return json(200, {
      state: 'recorded',
      notification_type: notificationType,
      environment_mismatch: true,
    });
  } catch {
    await d1.incrementOpsCounter(env.PURCHASE_DB, 'pushover_alert_failures', 1, now);
    await d1.finishNotification(
      env.PURCHASE_DB,
      uuid,
      'failed',
      'alert_delivery_failed',
      nowSeconds(),
    );
    return errorJson(503, 'alert_delivery_failed');
  }
}

// --- Reconciliation (Get Transaction History V2) ----------------------------

export async function handleReconcile(env: Env, request: Request): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { account_id?: string } | null;
  try {
    await assertCatalogIntegrity();
    const config = laneConfigFromEnv(env);
    if (body?.account_id) {
      const account = await d1.accountById(env.PURCHASE_DB, body.account_id);
      if (!account) {
        return errorJson(404, ERROR_ACCOUNT_NOT_FOUND);
      }
      const result = await reconcileAccount(env, config, account);
      return json(200, { schema_version: SCHEMA_VERSION, accounts: [result] });
    }
    const results = await reconcileDueAccounts(env, config);
    return json(200, { schema_version: SCHEMA_VERSION, accounts: results });
  } catch (error) {
    const handled = mapHandledError(error);
    if (handled) {
      return handled;
    }
    throw error;
  }
}

export interface ReconcileResult {
  account_id: string;
  credited: number;
  refunds_applied: number;
  transactions_seen: number;
  error?: string;
}

export async function reconcileDueAccounts(env: Env, config: LaneConfig): Promise<ReconcileResult[]> {
  const limit = Math.max(1, Number(env.RECONCILE_BATCH_ACCOUNTS) || 20);
  const due = await d1.reconciliationDue(env.PURCHASE_DB, nowSeconds(), limit);
  const results: ReconcileResult[] = [];
  for (const row of due) {
    const account = await d1.accountById(env.PURCHASE_DB, row.account_id);
    if (!account) {
      continue;
    }
    results.push(await reconcileAccount(env, config, account, row.revision_cursor));
  }
  return results;
}

async function reconcileAccount(
  env: Env,
  config: LaneConfig,
  account: d1.PurchaseAccountRow,
  startCursor?: string | null,
): Promise<ReconcileResult> {
  const intervalSeconds = Math.max(300, Number(env.RECONCILE_INTERVAL_SECONDS) || 21_600);
  const result: ReconcileResult = {
    account_id: account.account_id,
    credited: 0,
    refunds_applied: 0,
    transactions_seen: 0,
  };
  const keys = requireIdentitySecrets(env);
  let cursor = startCursor ?? null;
  try {
    const library = await loadAppleLibrary();
    const client = await makeApiClient(env, config);
    const appTransactionId = await decryptIdentifier(
      keys.encryptionKey,
      account.app_transaction_id_encrypted,
    );

    let hasMore = true;
    let pages = 0;
    while (hasMore && pages < MAX_RECONCILE_PAGES_PER_RUN) {
      pages += 1;
      const history = await client.getTransactionHistory(
        appTransactionId,
        cursor,
        {
          productTypes: [library.ProductType.CONSUMABLE],
          sort: library.Order.ASCENDING,
        },
        library.GetTransactionHistoryVersion.V2,
      );
      for (const signedTransaction of history.signedTransactions ?? []) {
        const decoded = await verifyTransaction(config, signedTransaction);
        result.transactions_seen += 1;
        const digest = await sha256Hex(signedTransaction);
        const credit = await creditVerifiedTransaction(
          env,
          config,
          decoded,
          digest,
          account.account_id,
          false,
        );
        if (credit.status === 200 && credit.body.outcome === 'credited') {
          result.credited += 1;
        }
        if (decoded.revocationDate !== undefined && decoded.transactionId) {
          const refundResponse = await doPost(accountStub(env, account.account_id), '/refund', {
            transaction_id: decoded.transactionId,
            revocation_type: decoded.revocationType ?? null,
            revocation_percentage: decoded.revocationPercentage ?? null,
            revocation_date: decoded.revocationDate ?? null,
            revocation_reason:
              decoded.revocationReason !== undefined ? String(decoded.revocationReason) : null,
          });
          if (refundResponse.ok) {
            const refundBody = (await refundResponse.json()) as { applied?: boolean };
            if (refundBody.applied) {
              result.refunds_applied += 1;
            }
          }
        }
      }
      cursor = history.revision ?? cursor;
      hasMore = history.hasMore === true;
    }
    await d1.finishReconciliation(
      env.PURCHASE_DB,
      account.account_id,
      { cursor, errorCode: null, nextAttemptAt: nowSeconds() + intervalSeconds },
      nowSeconds(),
    );
  } catch (error) {
    const code =
      error instanceof AppleVerificationError ? error.code : ERROR_INTERNAL;
    result.error = code;
    await d1.finishReconciliation(
      env.PURCHASE_DB,
      account.account_id,
      { cursor, errorCode: code, nextAttemptAt: nowSeconds() + Math.min(intervalSeconds, 3_600) },
      nowSeconds(),
    );
  }
  return result;
}

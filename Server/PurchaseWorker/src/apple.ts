// All Apple JWS verification and App Store Server API access goes through
// the official @apple/app-store-server-library — no bespoke JWS/x5c code
// anywhere. The library is lazy-imported inside handlers (A5 probe:
// jsrsasign seeds randomness at module scope, which kills Worker startup)
// and the verifier is constructed once per isolate so its 15-minute OCSP
// public-key cache is effective (W1 note, finding 4).

import type {
  AppStoreServerAPIClient,
  AppTransaction,
  Environment,
  JWSTransactionDecodedPayload,
  ResponseBodyV2DecodedPayload,
  SignedDataVerifier,
} from '@apple/app-store-server-library';
import type { Env } from './types';
import {
  ERROR_ENVIRONMENT_MISMATCH,
  ERROR_INVALID_APP_TRANSACTION,
  ERROR_INVALID_TRANSACTION,
  ERROR_NOTIFICATION_INVALID,
  ERROR_VERIFICATION_RETRYABLE,
} from './types';

export type AppleLibrary = typeof import('@apple/app-store-server-library');

let libraryPromise: Promise<AppleLibrary> | null = null;

export function loadAppleLibrary(): Promise<AppleLibrary> {
  if (!libraryPromise) {
    libraryPromise = import('@apple/app-store-server-library');
  }
  return libraryPromise;
}

export interface LaneConfig {
  lane: string;
  storekitEnvironment: 'Sandbox' | 'Production';
  bundleId: string;
  appAppleId: number | undefined;
  enableOnlineChecks: boolean;
  rootCasBase64: string[];
}

export class LaneConfigError extends Error {}

/**
 * Fail-closed lane validation: Sandbox lanes may run without an appAppleId;
 * the production lane must use Production StoreKit, carry the numeric Apple
 * app ID, and never enable the missing-ID escape hatch.
 */
export function laneConfigFromEnv(env: Env): LaneConfig {
  const lane = env.LANE;
  if (lane !== 'development' && lane !== 'prod-staging' && lane !== 'production') {
    throw new LaneConfigError(`unsupported lane ${lane}`);
  }
  const storekitEnvironment = env.STOREKIT_ENVIRONMENT;
  const expectedStorekitEnvironment = lane === 'production' ? 'Production' : 'Sandbox';
  if (storekitEnvironment !== expectedStorekitEnvironment) {
    throw new LaneConfigError(`${lane} requires ${expectedStorekitEnvironment} StoreKit`);
  }
  const allowMissingAppAppleId = env.ALLOW_MISSING_APP_APPLE_ID === 'true';
  const appAppleIdRaw = (env.APPLE_APP_APPLE_ID ?? '').trim();
  const appAppleId = appAppleIdRaw.length > 0 ? Number(appAppleIdRaw) : undefined;
  if (appAppleIdRaw.length > 0 && !Number.isSafeInteger(appAppleId)) {
    throw new LaneConfigError('APPLE_APP_APPLE_ID must be an integer when set');
  }
  if (lane === 'production') {
    if (allowMissingAppAppleId) {
      throw new LaneConfigError('production forbids ALLOW_MISSING_APP_APPLE_ID');
    }
    if (appAppleId === undefined || appAppleId <= 0) {
      throw new LaneConfigError('production requires APPLE_APP_APPLE_ID');
    }
  } else if (appAppleId === undefined && !allowMissingAppAppleId) {
    throw new LaneConfigError('Sandbox without APPLE_APP_APPLE_ID requires ALLOW_MISSING_APP_APPLE_ID=true');
  }
  if (!env.APPLE_BUNDLE_ID) {
    throw new LaneConfigError('APPLE_BUNDLE_ID is required');
  }

  const override = (env.APPLE_ROOT_CAS_OVERRIDE_BASE64 ?? '').trim();
  if (override.length > 0 && lane !== 'development') {
    throw new LaneConfigError('root CA override is allowed only in the development lane');
  }
  const rootsSpec = override.length > 0 ? override : env.APPLE_ROOT_CAS_BASE64 ?? '';
  const rootCasBase64 = rootsSpec
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  if (rootCasBase64.length === 0) {
    throw new LaneConfigError('no Apple root CAs configured');
  }

  return {
    lane,
    storekitEnvironment,
    bundleId: env.APPLE_BUNDLE_ID,
    appAppleId,
    enableOnlineChecks: env.ENABLE_ONLINE_CHECKS === 'true',
    rootCasBase64,
  };
}

interface VerifierCache {
  key: string;
  verifier: SignedDataVerifier;
}

let verifierCache: VerifierCache | null = null;

async function getVerifier(config: LaneConfig): Promise<SignedDataVerifier> {
  const key = JSON.stringify([
    config.storekitEnvironment,
    config.bundleId,
    config.appAppleId ?? null,
    config.enableOnlineChecks,
    config.rootCasBase64,
  ]);
  if (verifierCache && verifierCache.key === key) {
    return verifierCache.verifier;
  }
  const library = await loadAppleLibrary();
  const { Buffer } = await import('node:buffer');
  const roots = config.rootCasBase64.map((entry) => Buffer.from(entry, 'base64'));
  const environment: Environment =
    config.storekitEnvironment === 'Sandbox'
      ? library.Environment.SANDBOX
      : library.Environment.PRODUCTION;
  const verifier = new library.SignedDataVerifier(
    roots,
    config.enableOnlineChecks,
    environment,
    config.bundleId,
    config.appAppleId,
  );
  verifierCache = { key, verifier };
  return verifier;
}

export class AppleVerificationError extends Error {
  readonly code: string;
  readonly status: number;
  readonly kind:
    | 'retryable'
    | 'invalid_environment'
    | 'invalid_app_identifier'
    | 'invalid';

  constructor(
    code: string,
    status: number,
    message: string,
    kind: AppleVerificationError['kind'] = 'invalid',
  ) {
    super(message);
    this.code = code;
    this.status = status;
    this.kind = kind;
  }
}

async function mapVerificationFailure(error: unknown, invalidCode: string): Promise<never> {
  const library = await loadAppleLibrary();
  if (error instanceof library.VerificationException) {
    if (error.status === library.VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
      throw new AppleVerificationError(
        ERROR_VERIFICATION_RETRYABLE,
        503,
        'retryable verification failure',
        'retryable',
      );
    }
    if (error.status === library.VerificationStatus.INVALID_ENVIRONMENT) {
      throw new AppleVerificationError(
        ERROR_ENVIRONMENT_MISMATCH,
        400,
        'signed environment mismatch',
        'invalid_environment',
      );
    }
    if (error.status === library.VerificationStatus.INVALID_APP_IDENTIFIER) {
      throw new AppleVerificationError(
        invalidCode,
        400,
        'signed app identifier mismatch',
        'invalid_app_identifier',
      );
    }
    // INVALID_APP_IDENTIFIER, VERIFICATION_FAILURE, INVALID_CERTIFICATE
    // (which also covers short/malformed chains — A5 finding 2), FAILURE.
    throw new AppleVerificationError(invalidCode, 400, `verification failed (${error.status})`);
  }
  throw error;
}

export async function verifyAppTransaction(config: LaneConfig, jws: string): Promise<AppTransaction> {
  const verifier = await getVerifier(config);
  let decoded: AppTransaction;
  try {
    decoded = await verifier.verifyAndDecodeAppTransaction(jws);
  } catch (error) {
    return mapVerificationFailure(error, ERROR_INVALID_APP_TRANSACTION);
  }
  const appTransactionId = (decoded.appTransactionId ?? '').trim();
  if (appTransactionId.length === 0) {
    throw new AppleVerificationError(
      ERROR_INVALID_APP_TRANSACTION,
      400,
      'app transaction has no appTransactionId',
    );
  }
  return decoded;
}

export async function verifyTransaction(
  config: LaneConfig,
  jws: string,
): Promise<JWSTransactionDecodedPayload> {
  const verifier = await getVerifier(config);
  try {
    return await verifier.verifyAndDecodeTransaction(jws);
  } catch (error) {
    return mapVerificationFailure(error, ERROR_INVALID_TRANSACTION);
  }
}

export async function verifyNotification(
  config: LaneConfig,
  signedPayload: string,
): Promise<ResponseBodyV2DecodedPayload> {
  const verifier = await getVerifier(config);
  try {
    return await verifier.verifyAndDecodeNotification(signedPayload);
  } catch (error) {
    return mapVerificationFailure(error, ERROR_NOTIFICATION_INVALID);
  }
}

export async function makeApiClient(env: Env, config: LaneConfig): Promise<AppStoreServerAPIClient> {
  if (!env.APPLE_IAP_PRIVATE_KEY || !env.APPLE_IAP_KEY_ID || !env.APPLE_IAP_ISSUER_ID) {
    throw new AppleVerificationError(
      'apple_api_key_missing',
      503,
      'In-App Purchase API key secrets are not configured',
    );
  }
  const library = await loadAppleLibrary();
  const environment: Environment =
    config.storekitEnvironment === 'Sandbox'
      ? library.Environment.SANDBOX
      : library.Environment.PRODUCTION;
  return new library.AppStoreServerAPIClient(
    env.APPLE_IAP_PRIVATE_KEY,
    env.APPLE_IAP_KEY_ID,
    env.APPLE_IAP_ISSUER_ID,
    config.bundleId,
    environment,
  );
}

// Internal service contract between the Rust gateway and PurchaseWorker.
// Schema-versioned JSON, integer seconds everywhere. Error codes are stable
// machine strings; the credit codes mirror the gateway's credit.rs seam.

export const SCHEMA_VERSION = 1;

export const CREDIT_ERROR_INSUFFICIENT = 'insufficient_credits';
export const CREDIT_ERROR_RESERVATION_NOT_FOUND = 'reservation_not_found';
export const CREDIT_ERROR_CONFLICT = 'reservation_conflict';
// PW-3: a reserve replay for an existing job carried different seconds — a
// defect signal (job ids are single-use); internal RTW↔PW seam only, mapped
// by the RTW caller and never surfaced to app clients.
export const CREDIT_ERROR_SECONDS_MISMATCH = 'reservation_seconds_mismatch';
export const CREDIT_ERROR_INTERNAL = 'credit_internal_error';

export const ERROR_INVALID_REQUEST = 'invalid_request';
export const ERROR_ACCOUNT_NOT_FOUND = 'account_not_found';
export const ERROR_INVALID_APP_TRANSACTION = 'invalid_app_transaction';
export const ERROR_INVALID_TRANSACTION = 'invalid_transaction';
export const ERROR_INVALID_PRODUCT = 'invalid_product';
export const ERROR_TOKEN_MISMATCH = 'app_account_token_mismatch';
export const ERROR_ENVIRONMENT_MISMATCH = 'environment_mismatch';
export const ERROR_VERIFICATION_RETRYABLE = 'verification_retryable';
export const ERROR_NOTIFICATION_INVALID = 'notification_invalid';
export const ERROR_TRANSACTION_ACCOUNT_MISMATCH = 'transaction_account_mismatch';
export const ERROR_CATALOG_MISMATCH = 'catalog_mismatch';
export const ERROR_WORKER_MISCONFIGURED = 'worker_misconfigured';
export const ERROR_INTERNAL = 'internal_error';

export interface Balance {
  available_seconds: number;
  reserved_seconds: number;
  debt_seconds: number;
}

export interface CatalogProduct {
  product_id: string;
  grant_seconds: number;
}

export interface BootstrapRequest {
  schema_version: number;
  install_key: string;
  app_transaction_jws: string;
}

export interface BootstrapResponse {
  schema_version: number;
  account_id: string;
  app_account_token: string;
  balance: Balance;
  catalog: CatalogProduct[];
  catalog_sha256: string;
}

export interface BalanceRequest {
  schema_version: number;
  account_id: string;
}

export interface BalanceResponse {
  schema_version: number;
  balance: Balance;
}

export interface ReserveRequest {
  schema_version: number;
  account_id: string;
  job_id: string;
  seconds: number;
}

export interface SettleRequest {
  schema_version: number;
  job_id: string;
}

export interface ReleaseRequest {
  schema_version: number;
  job_id: string;
}

export type RedeemOutcome = 'credited' | 'already_credited' | 'refunded';

export interface RedeemRequest {
  schema_version: number;
  account_id: string;
  transaction_jws: string;
}

export interface RedeemResponse {
  schema_version: number;
  outcome: RedeemOutcome;
  transaction_id: string;
  credited_seconds: number;
  balance: Balance;
}

export interface ReconcileRequest {
  schema_version: number;
  account_id?: string;
}

export interface ErrorBody {
  error: string;
  detail?: string;
}

export interface Env {
  LANE: string;
  STOREKIT_ENVIRONMENT: string;
  APPLE_BUNDLE_ID: string;
  APPLE_APP_APPLE_ID: string;
  ALLOW_MISSING_APP_APPLE_ID: string;
  ENABLE_ONLINE_CHECKS: string;
  APPLE_ROOT_CAS_BASE64: string;
  APPLE_ROOT_CAS_OVERRIDE_BASE64: string;
  RECONCILE_BATCH_ACCOUNTS: string;
  RECONCILE_INTERVAL_SECONDS: string;
  /** Lowers the per-run transaction budget below its hard ceiling (tests). */
  RECONCILE_TRANSACTION_BUDGET?: string;
  /** Accounts read per liability-sweep page (one page per cron; ceiling 250). */
  LIABILITY_SNAPSHOT_MAX_ACCOUNTS?: string;
  PURCHASE_DB: D1Database;
  PURCHASE_ACCOUNT: DurableObjectNamespace;
  // Secrets (values never logged): Apple In-App Purchase API key trio plus
  // the identity HMAC/encryption keys.
  APPLE_IAP_KEY_ID?: string;
  APPLE_IAP_ISSUER_ID?: string;
  APPLE_IAP_PRIVATE_KEY?: string;
  APP_TX_HMAC_KEY?: string;
  APP_TX_ENCRYPTION_KEY?: string;
  PUSHOVER_APP_TOKEN?: string;
  PUSHOVER_USER_KEY?: string;
}

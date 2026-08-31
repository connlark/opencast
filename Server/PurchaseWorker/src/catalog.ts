// Immutable server catalog. Source of truth is the checked-in manifest
// fastlane/in_app_purchases/remote_transcription.json; a unit test recomputes
// the canonical mapping hash from this embedded copy and fails on drift, and
// the worker fails closed at runtime if its own copy stops hashing to the
// expected value. Once a product has been sold its grant is immutable — ship
// a .v2 product instead of editing.

import type { CatalogProduct } from './types';

export const EXPECTED_CATALOG_SHA256 =
  'c2b007bc37825865aa679166a6fa7d1b0d74c141999f459c12e056f3c7134ec5';

export const FREE_GRANT_SECONDS = 3600;
export const FREE_GRANT_LEDGER_KIND = 'free_grant_v1';

/** Maximum debt admitted by a new reservation: 3 hours. */
export const DEBT_CAP_SECONDS = 10_800;

export const CATALOG: CatalogProduct[] = [
  { product_id: 'com.connor.opencast.transcription.hours100.v1', grant_seconds: 360_000 },
  { product_id: 'com.connor.opencast.transcription.hours20.v1', grant_seconds: 72_000 },
];

export function grantSecondsForProduct(productId: string): number | undefined {
  return CATALOG.find((product) => product.product_id === productId)?.grant_seconds;
}

/**
 * Canonical mapping hash: SHA-256 of the compact JSON array of
 * {grant_seconds, product_id} sorted by product_id with sorted keys —
 * identical to fastlane's iap_catalog_mapping_sha256.
 */
export async function computeCatalogSha256(catalog: CatalogProduct[]): Promise<string> {
  const mapping = [...catalog]
    .sort((a, b) => (a.product_id < b.product_id ? -1 : a.product_id > b.product_id ? 1 : 0))
    .map((product) => ({ grant_seconds: product.grant_seconds, product_id: product.product_id }));
  const encoded = new TextEncoder().encode(JSON.stringify(mapping));
  const digest = await crypto.subtle.digest('SHA-256', encoded);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

let verifiedCatalogHash: string | null = null;

/** Fail closed: every money operation calls this before trusting CATALOG. */
export async function assertCatalogIntegrity(): Promise<void> {
  if (verifiedCatalogHash === EXPECTED_CATALOG_SHA256) {
    return;
  }
  const actual = await computeCatalogSha256(CATALOG);
  if (actual !== EXPECTED_CATALOG_SHA256) {
    throw new Error(`catalog hash mismatch: embedded catalog hashes to ${actual}`);
  }
  verifiedCatalogHash = actual;
}

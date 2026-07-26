// Contract checks that fail on drift:
// 1. The embedded catalog must equal the checked-in fastlane manifest and
//    hash to the value both the app and this worker embed (fail closed).
// 2. W1 contract: while ENABLE_ONLINE_CHECKS is true anywhere, the wrangler
//    config must keep the node-fetch transport alias — losing it silently
//    breaks the Apple library's OCSP path under workerd.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { CATALOG, computeCatalogSha256, EXPECTED_CATALOG_SHA256, FREE_GRANT_SECONDS } from '../../src/catalog';
import { laneConfigFromEnv } from '../../src/apple';

const workerDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const repoRoot = path.join(workerDir, '..', '..');

describe('catalog contract', () => {
  const manifest = JSON.parse(
    readFileSync(path.join(repoRoot, 'fastlane', 'in_app_purchases', 'remote_transcription.json'), 'utf8'),
  );

  it('embeds exactly the manifest products and grants', () => {
    const manifestMapping = manifest.products
      .map((product) => ({ product_id: product.product_id, grant_seconds: product.grant_seconds }))
      .sort((a, b) => a.product_id.localeCompare(b.product_id));
    const embedded = [...CATALOG].sort((a, b) => a.product_id.localeCompare(b.product_id));
    expect(embedded).toEqual(manifestMapping);
  });

  it('hashes to the manifest catalog_sha256 and the embedded expected value', async () => {
    expect(await computeCatalogSha256(CATALOG)).toBe(EXPECTED_CATALOG_SHA256);
    expect(manifest.catalog_sha256).toBe(EXPECTED_CATALOG_SHA256);
  });

  it('embeds the manifest free grant', () => {
    expect(manifest.free_grant.grant_seconds).toBe(FREE_GRANT_SECONDS);
  });
});

describe('wrangler config contract', () => {
  const config = readFileSync(path.join(workerDir, 'wrangler.toml'), 'utf8');

  it('keeps the node-fetch alias while online checks are enabled', () => {
    const onlineChecksEnabled = /ENABLE_ONLINE_CHECKS\s*=\s*"true"/.test(config);
    const aliasPresent = /"node-fetch"\s*=\s*"\.\/src\/node-fetch-shim\.cjs"/.test(config);
    expect(onlineChecksEnabled).toBe(true);
    expect(aliasPresent).toBe(true);
  });

  it('never exposes workers.dev and defines no routes', () => {
    expect(config).toMatch(/workers_dev\s*=\s*false/);
    expect(config).not.toMatch(/^\s*route\s*=/m);
    expect(config).not.toMatch(/\[\[?routes\]?\]/);
  });

  it('defines an isolated private production environment', () => {
    expect(config).toContain('[env.prod-staging]');
    expect(config).toContain('[env.production]');
    expect(config).toMatch(/\[env\.production\.vars\][\s\S]*LANE\s*=\s*"production"/);
    expect(config).toMatch(/\[env\.production\.vars\][\s\S]*STOREKIT_ENVIRONMENT\s*=\s*"Production"/);
    expect(config).toMatch(/\[env\.production\.vars\][\s\S]*ALLOW_MISSING_APP_APPLE_ID\s*=\s*"false"/);
  });
});

describe('lane config', () => {
  const base = {
    APPLE_BUNDLE_ID: 'com.connor.opencast',
    ENABLE_ONLINE_CHECKS: 'true',
    APPLE_ROOT_CAS_BASE64: 'root',
    APPLE_ROOT_CAS_OVERRIDE_BASE64: '',
  };

  it('accepts development/prod-staging Sandbox and strict Production', () => {
    expect(laneConfigFromEnv({
      ...base,
      LANE: 'development',
      STOREKIT_ENVIRONMENT: 'Sandbox',
      ALLOW_MISSING_APP_APPLE_ID: 'true',
      APPLE_APP_APPLE_ID: '',
    }).storekitEnvironment).toBe('Sandbox');
    expect(laneConfigFromEnv({
      ...base,
      LANE: 'prod-staging',
      STOREKIT_ENVIRONMENT: 'Sandbox',
      ALLOW_MISSING_APP_APPLE_ID: 'true',
      APPLE_APP_APPLE_ID: '',
    }).storekitEnvironment).toBe('Sandbox');
    expect(laneConfigFromEnv({
      ...base,
      LANE: 'production',
      STOREKIT_ENVIRONMENT: 'Production',
      ALLOW_MISSING_APP_APPLE_ID: 'false',
      APPLE_APP_APPLE_ID: '6766770733',
    }).appAppleId).toBe(6766770733);
  });

  it('rejects every mixed or weakened production posture', () => {
    for (const overrides of [
      { STOREKIT_ENVIRONMENT: 'Sandbox', ALLOW_MISSING_APP_APPLE_ID: 'false', APPLE_APP_APPLE_ID: '6766770733' },
      { STOREKIT_ENVIRONMENT: 'Production', ALLOW_MISSING_APP_APPLE_ID: 'true', APPLE_APP_APPLE_ID: '6766770733' },
      { STOREKIT_ENVIRONMENT: 'Production', ALLOW_MISSING_APP_APPLE_ID: 'false', APPLE_APP_APPLE_ID: '' },
    ]) {
      expect(() => laneConfigFromEnv({ ...base, LANE: 'production', ...overrides })).toThrow();
    }
  });
});

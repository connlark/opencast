// Contract checks that fail on drift:
// 1. The embedded public catalog must hash to the value both the app and this
//    Worker embed (fail closed).
// 2. While ENABLE_ONLINE_CHECKS is true anywhere, the wrangler
//    config must keep the node-fetch transport alias — losing it silently
//    breaks the Apple library's OCSP path under workerd.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { CATALOG, computeCatalogSha256, EXPECTED_CATALOG_SHA256, FREE_GRANT_SECONDS } from '../../src/catalog';
import { laneConfigFromEnv } from '../../src/apple';

const workerDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

describe('catalog contract', () => {
  it('embeds exactly the immutable public products and grants', () => {
    const expectedMapping = [
      { product_id: 'com.connor.opencast.transcription.hours100.v1', grant_seconds: 360_000 },
      { product_id: 'com.connor.opencast.transcription.hours20.v1', grant_seconds: 72_000 },
    ].sort((a, b) => a.product_id.localeCompare(b.product_id));
    const embedded = [...CATALOG].sort((a, b) => a.product_id.localeCompare(b.product_id));
    expect(embedded).toEqual(expectedMapping);
  });

  it('hashes to the embedded expected value', async () => {
    expect(await computeCatalogSha256(CATALOG)).toBe(EXPECTED_CATALOG_SHA256);
  });

  it('keeps the public free grant stable', () => {
    expect(FREE_GRANT_SECONDS).toBe(3600);
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

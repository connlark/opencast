import path from 'node:path';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers';
import { defineConfig } from 'vitest/config';
import { mintFixtures } from './test/fixtures/mint.mjs';

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, 'migrations'));
  const fixtures = mintFixtures();
  const outboundService = async (request) => {
    const url = new URL(request.url);
    if (url.hostname === 'api.pushover.net' && url.pathname === '/1/messages.json') {
      const body = new URLSearchParams(await request.text());
      if (
        request.method === 'POST' &&
        body.get('token') === 'test-pushover-token' &&
        body.get('user') === 'test-pushover-user' &&
        body.get('message') === 'notification_environment_mismatch=1'
      ) {
        return Response.json({ status: 1, request: 'test-request' });
      }
      return new Response('invalid test alert', { status: 400 });
    }
    return new Response('unexpected outbound request in production tests', { status: 502 });
  };

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: './wrangler.toml' },
        miniflare: {
          outboundService,
          bindings: {
            TEST_MIGRATIONS: migrations,
            LANE: 'production',
            STOREKIT_ENVIRONMENT: 'Production',
            APPLE_APP_APPLE_ID: '6766770733',
            ALLOW_MISSING_APP_APPLE_ID: 'false',
            ENABLE_ONLINE_CHECKS: 'false',
            APPLE_ROOT_CAS_BASE64: fixtures.trusted.rootDerBase64,
            APPLE_ROOT_CAS_OVERRIDE_BASE64: '',
            APP_TX_HMAC_KEY: 'cHJvZHVjdGlvbi10ZXN0LWhtYWMta2V5LTMyYnl0ZXMh',
            APP_TX_ENCRYPTION_KEY: 'v1:cHJvZHVjdGlvbi10ZXN0LWVuY3J5cHQtMzJieXRlcyE=',
            PUSHOVER_APP_TOKEN: 'test-pushover-token',
            PUSHOVER_USER_KEY: 'test-pushover-user',
          },
        },
      }),
    ],
    test: {
      include: ['test/workerd-production/**/*.spec.mjs'],
      setupFiles: ['./test/workerd-production/apply-migrations.mjs'],
      testTimeout: 30_000,
      maxWorkers: 1,
      isolate: false,
    },
  };
});

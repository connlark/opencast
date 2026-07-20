// PurchaseWorker entry. Private worker: reachable only through the gateway's
// service binding — no routes, no workers.dev. IMPORTANT: nothing here may
// import @apple/app-store-server-library at module scope (A5 probe:
// jsrsasign's module-scope randomness kills Worker startup); all Apple work
// is lazy-imported inside handlers via ./apple.

import {
  errorJson,
  handleBalance,
  handleBootstrap,
  handleNotification,
  handleReconcile,
  handleRedeem,
  handleRelease,
  handleReserve,
  handleSettle,
  handleSnapshot,
  json,
} from './handlers';
import { laneConfigFromEnv } from './apple';
import { reconcileDueAccounts } from './handlers';
import { captureLiabilitySnapshot } from './liability';
import type { Env } from './types';
import { ERROR_INTERNAL } from './types';

export { PurchaseAccount } from './accountDo';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (request.method !== 'POST' && path !== '/internal/v1/health') {
      return errorJson(405, 'method_not_allowed');
    }
    try {
      switch (path) {
        case '/internal/v1/health':
          return json(200, { ok: true, lane: env.LANE });
        case '/internal/v1/bootstrap':
          return await handleBootstrap(env, request);
        case '/internal/v1/balance':
          return await handleBalance(env, request);
        case '/internal/v1/reserve':
          return await handleReserve(env, request);
        case '/internal/v1/settle':
          return await handleSettle(env, request);
        case '/internal/v1/release':
          return await handleRelease(env, request);
        case '/internal/v1/redeem':
          return await handleRedeem(env, request);
        case '/internal/v1/notifications':
          return await handleNotification(env, request);
        case '/internal/v1/reconcile':
          return await handleReconcile(env, request);
        case '/internal/v1/snapshot':
          return await handleSnapshot(env, request);
        case '/internal/v1/liability-snapshot':
          return json(200, await captureLiabilitySnapshot(env));
        default:
          return errorJson(404, 'not_found');
      }
    } catch (error) {
      // Never leak JWS, keys, or Apple identifiers: log the message only.
      const message = error instanceof Error ? error.message : 'unknown';
      console.log(`purchase-worker-error path=${path} message=${message.slice(0, 200)}`);
      return errorJson(500, ERROR_INTERNAL);
    }
  },

  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      (async () => {
        try {
          const config = laneConfigFromEnv(env);
          const results = await reconcileDueAccounts(env, config);
          console.log(
            `purchase-reconcile-cron accounts=${results.length} credited=${results.reduce((sum, item) => sum + item.credited, 0)} errors=${results.filter((item) => item.error).length}`,
          );
        } catch (error) {
          const message = error instanceof Error ? error.message : 'unknown';
          console.log(`purchase-reconcile-cron-error message=${message.slice(0, 200)}`);
        }
        try {
          const snapshot = await captureLiabilitySnapshot(env);
          console.log(
            `purchase-liability-cron accounts=${snapshot.account_count} sampled=${snapshot.accounts_sampled} outstanding_seconds=${snapshot.outstanding_seconds} debt_seconds=${snapshot.debt_seconds} complete=${snapshot.complete}`,
          );
        } catch (error) {
          const message = error instanceof Error ? error.message : 'unknown';
          console.log(`purchase-liability-cron-error message=${message.slice(0, 200)}`);
        }
      })(),
    );
  },
};

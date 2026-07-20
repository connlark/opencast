import path from "node:path";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(
    path.join(import.meta.dirname, "migrations"),
  );

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            PUBLIC_REMOTE_TRANSCRIPTION_ENABLED: "true",
            DEV_BEARER_ENABLED: "true",
            DEV_BEARER_TOKEN: "integration-test-bearer-token",
            // Fake upstreams (development lane only): media chunking without
            // ffmpeg and deterministic AI responses; the AI/media bindings
            // are never touched.
            FAKE_MEDIA: "true",
            FAKE_AI: "true",
            // Small grant so the suite can drive awaiting_credits honestly;
            // sized so the pass-0.5 fan-out and pass-2 upload tests can
            // still settle real spends afterwards (cumulative suite).
            DEV_CREDIT_GRANT_SECONDS: "7000",
            // Exact-device upload (pass 2): presigned URLs point at a fake
            // S3 host the spec's fetch mock maps onto the R2 binding's real
            // multipart machinery. 5 MiB parts (the R2 non-final minimum)
            // keep multi-part fixtures small.
            R2_S3_HOST: "r2-sim.test",
            R2_S3_BUCKET: "test-bucket",
            R2_S3_ACCESS_KEY_ID: "test-access-key-id",
            R2_S3_SECRET_ACCESS_KEY: "test-secret-access-key",
            UPLOAD_PART_BYTES: "5242880",
            // Short upload deadlines so expiry runs in test time; live tests
            // finish their PUTs well inside these windows.
            EXACT_UPLOAD_REQUIRED_DEADLINE_SECONDS: "4",
            EXACT_UPLOADING_DEADLINE_SECONDS: "8",
            // Fan-out default under test; individual jobs pin their own
            // concurrency through the FAKE_AI language-code hooks.
            CHUNK_AI_CONCURRENCY: "4",
            // Serialize jobs so the integration suite can prove FIFO queue
            // status while still allowing two jobs for the test account.
            GLOBAL_INFERENCE_CONCURRENCY: "1",
            MAX_ACTIVE_JOBS_PER_ACCOUNT: "2",
            QUEUE_DEFAULT_REMAINING_SECONDS: "64",
            // Short deadlines so expiry paths run in wall-clock test time.
            WAITING_FOR_DEVICE_SOURCE_DEADLINE_SECONDS: "2",
            AWAITING_CREDITS_DEADLINE_SECONDS: "2",
            POLL_AFTER_SECONDS: "1",
            PUSHOVER_APP_TOKEN: "test-pushover-token",
            PUSHOVER_USER_KEY: "test-pushover-user",
          },
          serviceBindings: {
            // FAKE_MEDIA short-circuits before the service binding; this stub
            // exists only so the binding resolves.
            TRANSCRIPTION_MEDIA_WORKER() {
              return new Response("media worker unavailable in tests", {
                status: 501,
              });
            },
          },
        },
      }),
    ],
    test: {
      // Top level only: test/purchase + test/killswitch run under their own
      // configs (vitest.purchase.config.mjs / vitest.killswitch.config.mjs).
      include: ["test/*.spec.mjs"],
      setupFiles: ["./test/apply-migrations.mjs"],
      testTimeout: 30_000,
      // Jobs span multiple requests and alarms; tests share storage and use
      // unique client request IDs instead of per-test isolation.
      poolOptions: {
        workers: {
          isolatedStorage: false,
          singleWorker: true,
        },
      },
    },
  };
});

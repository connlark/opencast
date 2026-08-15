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
        // Production-posture tests must remain local and credential-free;
        // none of their assertions require the configured Workers AI binding.
        remoteBindings: false,
        wrangler: {
          configPath: "./wrangler.toml",
          environment: "production",
        },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // Wrangler's test runner loads the development `.dev.vars` file
            // even for a named environment. Explicitly erase that test-only
            // credential so production posture matches the deployed lane.
            DEV_BEARER_TOKEN: "",
          },
          serviceBindings: {
            AD_ANALYSIS_WORKER() {
              return new Response("ad analysis worker must not be reached", {
                status: 501,
              });
            },
            PURCHASE_WORKER() {
              return new Response("purchase worker must not be reached", {
                status: 501,
              });
            },
            TRANSCRIPTION_MEDIA_WORKER() {
              return new Response("media worker must not be reached", {
                status: 501,
              });
            },
          },
        },
      }),
    ],
    test: {
      include: ["test/production/**/*.spec.mjs"],
      setupFiles: ["./test/apply-migrations.mjs"],
      testTimeout: 30_000,
      maxWorkers: 1,
      isolate: false,
    },
  };
});

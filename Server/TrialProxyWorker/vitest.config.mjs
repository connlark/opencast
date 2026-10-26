import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// The bundle build.rs embeds: the highest checked-in vN.json (the isolate has
// no filesystem, so the suite gets its version as a binding).
function embeddedBundleVersion() {
  const directory = path.join(
    import.meta.dirname,
    "../ModelGatewayWorker/manifests/analysis-policy",
  );
  const highest = readdirSync(directory)
    .map((name) => /^v(\d+)\.json$/.exec(name))
    .filter(Boolean)
    .reduce((best, match) => (Number(match[1]) > Number(best[1]) ? match : best));
  return JSON.parse(readFileSync(path.join(directory, highest[0]), "utf8")).bundle_version;
}

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
            TEST_BUNDLE_VERSION: embeddedBundleVersion(),
            TRIAL_BEARER_TOKEN: "integration-test-bearer-token",
            GEMINI_API_KEY: "integration-test-gemini-key",
          },
        },
      }),
    ],
    test: {
      include: ["test/trial.spec.mjs"],
      setupFiles: ["./test/apply-migrations.mjs"],
    },
  };
});

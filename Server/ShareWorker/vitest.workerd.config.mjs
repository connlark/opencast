import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Black-box tests against the Vite build output (`yarn build` first, which
// `test:integration` does), so the preact alias and the asset layout are the
// ones that deploy. The plugin writes the flattened dev-lane config to
// dist/dev/<worker name with underscores>/wrangler.json; find it rather than
// hard-code the name, which each deployment chooses.
const DIST = path.join(import.meta.dirname, "dist", "dev");
const CLIENT_ASSETS = path.join(DIST, "client", "e", "_");

const workerDirectories = existsSync(DIST)
  ? readdirSync(DIST).filter((entry) => existsSync(path.join(DIST, entry, "wrangler.json")))
  : [];
if (workerDirectories.length !== 1) {
  throw new Error(
    `expected one built worker under dist/dev, found ${workerDirectories.length}: run \`yarn workspace opencast-share-worker build\` first`,
  );
}
const BUILT_CONFIG = path.join(DIST, workerDirectories[0], "wrangler.json");
// Only the entry URL carries ?v=, so a second chunk would be cached forever under a stale name.
const clientFiles = readdirSync(CLIENT_ASSETS).sort();
if (clientFiles.join(",") !== "entry.css,entry.js") {
  throw new Error(`expected exactly entry.css and entry.js under dist/dev/client/e/_, found ${clientFiles.join(", ")}`);
}

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: BUILT_CONFIG },
      miniflare: {
        bindings: {
          // Shrunk so the cap and the header timeout are testable.
          DOWNLOAD_MAX_BYTES: "4096",
          UPSTREAM_HEADER_TIMEOUT_MS: "500",
        },
      },
    }),
  ],
  test: {
    include: ["test/workerd/**/*.spec.mjs"],
    testTimeout: 30_000,
    maxWorkers: 1,
    isolate: false,
  },
});

// Browser tests for the share page (`yarn test:e2e`, which builds first).
//
// The built Worker runs under `wrangler dev` over HTTPS: the page's CSP carries
// `upgrade-insecure-requests`, and over plain http on loopback WebKit
// re-requests every subresource as https and never finishes loading (Chromium
// exempts loopback and hides it). The CSP is tested verbatim; `vite dev` drops
// it and serves the source entry, so it is never the server here.
//
// WebKit first: the page is opened mostly on iPhones, and Chromium models
// `dvh`, `backdrop-filter` and sticky boxes differently enough to hide bugs.
import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { defineConfig, devices } from "@playwright/test";
import { BASE_URL, OUT_DIR, WORKER_PORT } from "./test/e2e/env.ts";

// Same discovery as vitest.workerd.config.mjs: the plugin names the directory
// after the Worker, which each deployment chooses.
const DIST = path.join(import.meta.dirname, "dist", "dev");
const built = existsSync(DIST)
  ? readdirSync(DIST).filter((entry) => existsSync(path.join(DIST, entry, "wrangler.json")))
  : [];
if (built.length !== 1) {
  throw new Error(`expected one built worker under dist/dev, found ${built.length}: run \`yarn build\` first`);
}
const BUILT_CONFIG = path.join("dist", "dev", built[0]!, "wrangler.json");

// WebKit on macOS refuses `isMobile`; the viewport, DPR, touch and UA are what
// the page can observe anyway.
function iPhone(name: keyof typeof devices) {
  const { isMobile: _unsupported, ...descriptor } = devices[name]!;
  return descriptor;
}

export default defineConfig({
  testDir: "test/e2e",
  testMatch: /.*\.e2e\.ts$/,
  outputDir: path.join(OUT_DIR, "test-results"),
  globalSetup: "./test/e2e/global-setup.ts",
  fullyParallel: true,
  // Each WebKit worker is a full browser; the Worker itself is stateless (the
  // token carries the data), so tests share one server.
  workers: process.env.CI ? 2 : 4,
  retries: process.env.CI ? 1 : 0,
  forbidOnly: !!process.env.CI,
  timeout: 45_000,
  expect: { timeout: 8_000 },
  reporter: [["list"], ["html", { outputFolder: path.join(OUT_DIR, "report"), open: "never" }]],
  use: {
    baseURL: BASE_URL,
    // Wrangler's and the media host's certificates are self-signed.
    ignoreHTTPSErrors: true,
    actionTimeout: 10_000,
    navigationTimeout: 20_000,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    // Request-only: no browser, run once.
    { name: "routes", testMatch: /routes\.e2e\.ts$/ },
    ...[
      { name: "iphone-se", use: { ...iPhone("iPhone SE"), browserName: "webkit" as const } },
      { name: "iphone-15", use: { ...iPhone("iPhone 15"), browserName: "webkit" as const } },
      { name: "iphone-pro-max", use: { ...iPhone("iPhone 17 Pro Max"), browserName: "webkit" as const } },
      { name: "iphone-landscape", use: { ...iPhone("iPhone 15 landscape"), browserName: "webkit" as const } },
      { name: "pixel", use: { ...devices["Pixel 7"], browserName: "chromium" as const } },
      { name: "desktop-webkit", use: { ...devices["Desktop Safari"], browserName: "webkit" as const } },
      { name: "desktop-chromium", use: { ...devices["Desktop Chrome"], browserName: "chromium" as const } },
    ].map((project) => ({ ...project, testIgnore: /routes\.e2e\.ts$/ })),
  ],
  webServer: {
    // --upstream-protocol keeps request.url https, so canonical and og:url
    // carry the scheme the browser used.
    command: `yarn wrangler dev -c ${BUILT_CONFIG} --local-protocol https --upstream-protocol https --ip 127.0.0.1 --port ${WORKER_PORT}`,
    // Any status under 404 counts; global setup waits for a real page.
    url: `${BASE_URL}/e/`,
    ignoreHTTPSErrors: true,
    // A server left over from an older build would test stale code.
    reuseExistingServer: false,
    timeout: 60_000,
    stdout: "ignore",
    stderr: "pipe",
    gracefulShutdown: { signal: "SIGTERM", timeout: 5_000 },
  },
});

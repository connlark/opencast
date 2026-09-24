// Shared by playwright.config.ts, global setup, and the specs.
import os from "node:os";
import path from "node:path";

// Not 8787 (wrangler's default) or other local rigs' 8931/8932/8941/8942.
export const WORKER_PORT = 8951;
export const BASE_URL = `https://127.0.0.1:${WORKER_PORT}`;

/** Reports, traces, screenshots, the TLS pair and the token manifest. Never the working tree. */
export const OUT_DIR = process.env.SHARE_E2E_OUT || path.join(os.tmpdir(), "opencast-share-e2e");
export const SCREENSHOT_DIR = path.join(OUT_DIR, "screenshots");
export const MANIFEST_PATH = path.join(OUT_DIR, "manifest.json");

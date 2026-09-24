// Runs once, after Playwright's webServer has started `wrangler dev`: mints a
// throwaway TLS pair, starts the stand-in podcast host, mints the fixture
// tokens against it, and waits until the Worker serves a real page.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import https from "node:https";
import path from "node:path";
import { BASE_URL, MANIFEST_PATH, OUT_DIR, SCREENSHOT_DIR } from "./env.ts";
import { startMediaServer } from "./media-server.ts";
import { fixtureTokens, type FixtureToken } from "./tokens.ts";

export interface Manifest {
  base: string;
  media: { https: string; http: string };
  tokens: Record<string, FixtureToken>;
}

export default async function globalSetup() {
  mkdirSync(SCREENSHOT_DIR, { recursive: true, mode: 0o700 });
  const media = await startMediaServer(certificate(path.join(OUT_DIR, "tls")));
  try {
    const tokens = fixtureTokens(media.httpsOrigin);
    await waitForWorker(`${BASE_URL}/e/${tokens.happy!.token}`);
    const manifest: Manifest = { base: BASE_URL, media: { https: media.httpsOrigin, http: media.httpOrigin }, tokens };
    writeFileSync(MANIFEST_PATH, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
    // Workers are spawned after this returns and inherit the environment.
    process.env.SHARE_E2E_MANIFEST = MANIFEST_PATH;
  } catch (error) {
    await media.close();
    throw error;
  }
  return () => media.close();
}

// A self-signed pair for 127.0.0.1, valid for a day. The browsers run with
// ignoreHTTPSErrors, so it only has to be well-formed.
function certificate(directory: string): { key: string; cert: string } {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const key = path.join(directory, "key.pem");
  const cert = path.join(directory, "cert.pem");
  execFileSync(
    "openssl",
    ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1",
      "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"],
    { stdio: "ignore", timeout: 30_000 },
  );
  return { key: readFileSync(key, "utf8"), cert: readFileSync(cert, "utf8") };
}

// Answering is not being ready: webServer only waits for a status code. Ready
// means a minted token renders the page shell with its state script.
async function waitForWorker(url: string) {
  const deadline = Date.now() + 60_000;
  let last = "no response";
  while (Date.now() < deadline) {
    try {
      const { status, body } = await get(url);
      if (status === 200 && body.includes('id="app"') && body.includes('id="__share"')) return;
      last = `${status} ${body.slice(0, 120)}`;
    } catch (error) {
      last = String(error);
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`the Worker never served a page at ${BASE_URL}: ${last}`);
}

// Wrangler's certificate is self-signed; scoped to this one request rather
// than NODE_TLS_REJECT_UNAUTHORIZED, which the test workers would inherit.
function get(url: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const request = https.get(url, { rejectUnauthorized: false, timeout: 5_000 }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => (body += chunk));
      response.on("end", () => resolve({ status: response.statusCode ?? 0, body }));
      response.on("error", reject);
    });
    request.on("timeout", () => request.destroy(new Error("timed out")));
    request.on("error", reject);
  });
}

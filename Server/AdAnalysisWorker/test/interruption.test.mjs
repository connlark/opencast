// Run outside workerd: its 20260811.1 abortAllDurableObjects test helper
// destroys an active promise callback after nested DO calls (also reproduced
// without Rust). Restart the actual runtime, retaining its SQLite databases.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { convertV4MiniflareOptions, Log, LogLevel, Miniflare } from "miniflare";

const root = path.resolve(import.meta.dirname, "..");
const bearer = "interruption-test-bearer-token";
const base = "https://ad-analysis.interruption.test";

function request(policy) {
  const segmentCount = policy === "v2" ? 2100 : 850;
  const fingerprint = randomUUID().replaceAll("-", "").repeat(2);
  return {
    schema_version: 1,
    request_id: `interruption-${policy}`,
    episode_id: `episode-${policy}`,
    podcast_id: "https://example.com/interruption/feed.xml",
    async_supported: true,
    job_handle_version: 1,
    transcript: {
      language_code: "en", audio_duration: segmentCount * 2, fingerprint,
      updated_at: "2026-09-11T00:00:00Z", state: "completed",
      segment_count: segmentCount,
    },
    segments: Array.from({ length: segmentCount }, (_, id) => ({
      id, start: id * 2, end: (id + 1) * 2,
      text: `Discussion segment ${id} continues the episode conversation.`,
    })),
  };
}

async function post(runtime, route, value) {
  const body = JSON.stringify(value);
  return runtime.dispatchFetch(base + route, {
    method: "POST", body,
    headers: {
      "content-type": "application/json",
      "content-length": String(Buffer.byteLength(body)),
      authorization: `Bearer ${bearer}`,
    },
    signal: AbortSignal.timeout(10_000),
  });
}

async function ledger(resourcePersistencePath) {
  // Rust's classic DO exports do not support Miniflare's RPC inspection.
  // Read only the SQLite files created by this test; never alter its records.
  const directory = path.join(resourcePersistencePath, "do", "ad-interruption-test-AdAnalysisUsageLimiter");
  const rows = [];
  for (const file of (await readdir(directory)).sort()) {
    if (!file.endsWith(".sqlite") || file === "metadata.sqlite") continue;
    const database = new DatabaseSync(path.join(directory, file), { readOnly: true });
    try {
      rows.push(...database.prepare("SELECT request_count, input_tokens, record FROM accounted_runs ORDER BY run_id").all());
    } finally {
      database.close();
    }
  }
  return rows;
}

for (const policy of ["v2", "v3"]) {
  test(`${policy}: interrupted multi-window job retains unknown usage and fails without replay`, { timeout: 90_000 }, async () => {
    const resourcePersistencePath = await mkdtemp(path.join(tmpdir(), "opencast-ad-interruption-"));
    const input = request(policy);
    let release;
    const blocked = new Promise((resolve) => { release = resolve; });
    let calls = 0;
    const worker = {
      name: "ad-interruption-test",
      compatibilityDate: "2026-08-14",
      modules: [
        { type: "ESModule", path: path.join(root, "build/index.js"), contents: await readFile(path.join(root, "build/index.js"), "utf8") },
        { type: "CompiledWasm", path: path.join(root, "build/index_bg.wasm"), contents: await readFile(path.join(root, "build/index_bg.wasm")) },
      ],
      bindings: {
        AD_ANALYSIS_POLICY: `promo_ad_breaks_${policy}`,
        AD_ANALYSIS_GEMINI_MODEL: "gemini-3.1-flash-lite",
        AD_ANALYSIS_CLIENT_TOKEN: bearer,
        GEMINI_API_KEY: "interruption-test-provider-key",
        PUBLIC_AD_ANALYSIS_ENABLED: "true",
      },
      durableObjects: {
        AD_ANALYSIS_JOB: { className: "AdAnalysisJob", useSQLite: true },
        AD_ANALYSIS_USAGE_LIMITER: { className: "AdAnalysisUsageLimiter", useSQLite: true },
      },
      outboundService: async (outbound) => {
        const model = policy === "v3" ? "gemini-3.8-flash" : "gemini-3.1-flash-lite";
        assert.equal(outbound.url, `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`);
        await outbound.arrayBuffer();
        calls += 1;
        await blocked;
        return new Response("{}");
      },
    };
    const options = {
      host: "127.0.0.1", port: 0, resourcePersistencePath,
      log: new Log(LogLevel.WARN), workers: [worker],
    };
    const runtime = new Miniflare(convertV4MiniflareOptions(options));
    try {
      const submitted = await post(runtime, "/v1/ad-analysis/transcript", input);
      const accepted = await submitted.json();
      assert.equal(submitted.status, 202, JSON.stringify(accepted));
      const dispatchDeadline = Date.now() + 5000;
      while (calls < 2 && Date.now() < dispatchDeadline) await delay(10);
      assert.equal(calls, 2, "both provider windows must be in flight before interruption");
      const before = await ledger(resourcePersistencePath);
      assert.equal(before.length, 1);
      assert.equal(before[0].request_count, 1);
      assert.ok(before[0].input_tokens > 0);
      const attempts = JSON.parse(before[0].record).attempts;
      assert.equal(attempts.length, policy === "v3" ? 2 : 1);
      assert.ok(attempts.every((attempt) => attempt.state === "dispatched" && attempt.usage == null));

      // setOptions restarts workerd itself. No fabricated Running record or
      // mocked accounting binding substitutes for the accepted, paid run.
      await runtime.setOptions(convertV4MiniflareOptions({
        ...options, workers: [{ ...worker, bindings: { ...worker.bindings, TEST_RESTART_GENERATION: "2" } }],
      }));
      const watchdogDeadline = Date.now() + 45_000;
      let status;
      do {
        const polled = await post(runtime, `/v1/ad-analysis/jobs/${accepted.job_id}`, { job_id: accepted.job_id });
        status = polled.status;
        const result = await polled.json();
        if (status !== 202) {
          assert.equal(status, 503);
          assert.equal(result.error, "job_failed_transient");
          assert.deepEqual(result.failure, { category: "interrupted_job", retry_disposition: "bounded_retry" });
          break;
        }
        await delay(250);
      } while (Date.now() < watchdogDeadline);
      assert.equal(status, 503, "the real watchdog alarm must terminalize the interrupted job");
      assert.deepEqual(await ledger(resourcePersistencePath), before, "unknown dispatched usage must stay charged across restart");
      const repeated = await post(runtime, `/v1/ad-analysis/jobs/${accepted.job_id}`, { job_id: accepted.job_id });
      assert.equal(repeated.status, 503);
      assert.equal((await repeated.json()).error, "job_failed_transient");
      assert.equal(calls, 2, "repeated polling must not buy another attempt");
    } finally {
      release();
      await runtime.dispose();
      await rm(resourcePersistencePath, { recursive: true, force: true });
    }
  });
}

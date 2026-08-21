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
        // The Wrangler config contains a Workers AI binding, which defaults
        // to a remote proxy. Tests short-circuit AI through FAKE_AI, so keep
        // the entire suite local and credential-free.
        remoteBindings: false,
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            DEV_BEARER_TOKEN: "integration-test-bearer-token",
            // Fake upstreams (development lane only): media chunking without
            // ffmpeg and deterministic AI responses; the AI/media bindings
            // are never touched.
            FAKE_MEDIA: "true",
            FAKE_AI: "true",
            // Small grant so the suite can drive awaiting_credits honestly;
            // sized so the pass-0.5 fan-out, pass-2 upload, and stranded-job
            // tests can still settle real spends afterwards (cumulative
            // suite). Must match GRANT in test/integration.spec.mjs.
            DEV_CREDIT_GRANT_SECONDS: "7200",
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
            // Chained cloud ad detection against the stubbed binding below.
            // Deadline short enough for the timeout drill, long enough that
            // the happy path (submit + one poll at 1 s) never trips it.
            AD_ANALYSIS_ENABLED: "true",
            AD_ANALYSIS_DEADLINE_SECONDS: "10",
            AD_ANALYSIS_POLL_SECONDS: "1",
            AD_ANALYSIS_MAX_SUBMIT_ATTEMPTS: "3",
            // Alarm-error retry in test time so re-entry paths (the stitch
            // sfail hook) run inside test timeouts; production default is 60.
            ALARM_RETRY_SECONDS: "1",
            // Short origin wall so the stalled-stream test (RTW-7) runs in
            // test time; live stagings here finish in well under a second,
            // and the parked-staging race test stays inside this budget.
            ORIGIN_FETCH_WALL_SECONDS: "4",
          },
          serviceBindings: {
            // FAKE_MEDIA short-circuits before the service binding; this stub
            // exists only so the binding resolves.
            TRANSCRIPTION_MEDIA_WORKER() {
              return new Response("media worker unavailable in tests", {
                status: 501,
              });
            },
            // Stubbed AdAnalysisWorker internal surface. Scenario selection
            // rides the submitted podcast_id: "ad-cap" => 429 cap,
            // "ad-transient" => 503 every submit, "ad-hang" => runs forever,
            // "ad-park" => the submit response parks ~4 s in flight (the
            // in-flight-cancel race hook), "ad-lost" => submit accepted but
            // every poll 404s (drives the resubmit path's missing-envelope
            // arm); anything else completes on the first poll with spans
            // derived from the submitted segments.
            AD_ANALYSIS_WORKER: (() => {
              const jobs = new Map();
              const json = (body, status) =>
                new Response(JSON.stringify(body), {
                  status,
                  headers: { "content-type": "application/json" },
                });
              return async (request) => {
                const url = new URL(request.url);
                if (url.hostname !== "opencast-ad-analysis.internal") {
                  return json({ error: "not_found" }, 404);
                }
                if (url.pathname === "/internal/v1/analyze") {
                  const body = await request.json();
                  const inner = body.request;
                  const podcast = inner?.podcast_id ?? "";
                  if (podcast.includes("ad-cap")) {
                    return json({ error: "daily_request_cap_exceeded" }, 429);
                  }
                  if (podcast.includes("ad-transient")) {
                    return json({ error: "job_failed_transient" }, 503);
                  }
                  const fingerprint = inner.transcript.fingerprint;
                  if (podcast.includes("ad-park")) {
                    // Park the submit in flight long enough for the spec to
                    // cancel the job while the DO is awaiting this response.
                    await new Promise((resolve) => setTimeout(resolve, 4000));
                    jobs.set(fingerprint, { hang: true, request: inner });
                    return json(
                      {
                        job_id: fingerprint,
                        state: "running",
                        poll_after_seconds: 1,
                      },
                      202,
                    );
                  }
                  if (podcast.includes("ad-lost")) {
                    // Accept the submit but never store the job: the next
                    // poll 404s, clearing the DO's poll target so its next
                    // turn re-reads the (test-deleted) result envelope.
                    return json(
                      {
                        job_id: fingerprint,
                        state: "running",
                        poll_after_seconds: 1,
                      },
                      202,
                    );
                  }
                  jobs.set(fingerprint, {
                    hang: podcast.includes("ad-hang"),
                    request: inner,
                  });
                  return json(
                    {
                      job_id: fingerprint,
                      state: "running",
                      poll_after_seconds: 1,
                    },
                    202,
                  );
                }
                const poll = url.pathname.match(
                  /^\/internal\/v1\/jobs\/([^/]+)\/poll$/,
                );
                if (poll) {
                  const job = jobs.get(poll[1]);
                  if (!job) {
                    return json({ error: "job_not_found" }, 404);
                  }
                  if (job.hang) {
                    return json(
                      {
                        job_id: poll[1],
                        state: "running",
                        poll_after_seconds: 1,
                      },
                      202,
                    );
                  }
                  const segments = job.request.segments;
                  const first = segments[0];
                  const last = segments[Math.min(1, segments.length - 1)];
                  return json(
                    {
                      schema_version: 1,
                      request_id: job.request.request_id,
                      model: "gemini-3.5-flash",
                      policy: "promo_ad_breaks_v2",
                      spans: [
                        {
                          kind: "host_read_ad",
                          label: "Stub sponsor",
                          start_segment_id: first.id,
                          end_segment_id: last.id,
                          start_time: first.start,
                          end_time: Math.max(last.end, first.start + 1),
                          confidence: 0.92,
                          evidence_quote: "brought to you by",
                        },
                      ],
                      warnings: [],
                      usage: {
                        prompt_token_count: 100,
                        candidates_token_count: 20,
                        total_token_count: 120,
                      },
                    },
                    200,
                  );
                }
                return json({ error: "not_found" }, 404);
              };
            })(),
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
      maxWorkers: 1,
      isolate: false,
    },
  };
});

// Exercise the packaged Rust DO with a fake wall clock and real local storage.
import { env, runInDurableObject, runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const COMPLETED_AT = 2_000_000_000;
const OWNER = "app-attest-key:retention-owner";
const RESULT = { request_id: "retained-result", spans: [] };
const request = {
  schema_version: 1, async_supported: true, request_id: "retention-submit",
  episode_id: "episode", podcast_id: "podcast",
  transcript: { language_code: "en", audio_duration: 10, fingerprint: "retention-job", updated_at: "2033-05-18T03:33:20Z", state: "complete", segment_count: 1 },
  segments: [{ id: 0, start: 0, end: 10, text: "A local fixture." }],
};

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(COMPLETED_AT * 1000);
});
afterEach(() => vi.useRealTimers());

async function seed(lifetime, overrides = {}) {
  const namespace = env.TRANSCRIPT_ANALYSIS_JOB;
  const stub = namespace.get(namespace.idFromName(`retention-${crypto.randomUUID()}`));
  const record = {
    state: "completed", job_id: "retention-job", result_json: JSON.stringify(RESULT),
    purge_at: COMPLETED_AT + lifetime, subjects: [OWNER], content_hash: "owned-content",
    ...overrides,
  };
  await runInDurableObject(stub, async (_instance, state) => {
    await state.storage.put("job", JSON.stringify(record));
    await state.storage.setAlarm(record.purge_at * 1000);
  });
  return { stub, record };
}
async function stored(stub) {
  return runInDurableObject(stub, async (_instance, state) => {
    const raw = await state.storage.get("job");
    return raw ? JSON.parse(raw) : null;
  });
}
function poll(stub, subject = OWNER) {
  return stub.fetch("https://job.test/poll", {
    method: "POST", body: JSON.stringify({ job_id: "retention-job", subject }),
  });
}
function submit(stub, subject = OWNER) {
  return stub.fetch("https://job.test/submit", {
    method: "POST", body: JSON.stringify({
      usage_object_name: "retention-usage", usage_profile: "bearer",
      estimated_input_tokens: 10, subject, request,
    }),
  });
}

describe("stored result expiration", () => {
  it.each([1800, 86400])("honors a stored %i-second lifetime without sliding or unauthorized attachment", async (lifetime) => {
    const { stub, record } = await seed(lifetime);
    for (const elapsed of [...new Set([1799, 1800, 1801, lifetime - 1])].sort((a, b) => a - b)) {
      if (elapsed >= lifetime) continue;
      vi.setSystemTime((COMPLETED_AT + elapsed) * 1000);
      const response = await poll(stub);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual(RESULT);
      expect((await poll(stub, "stranger")).status).toBe(404);
      expect((await submit(stub, "stranger")).status).toBe(409);
      expect((await submit(stub)).status).toBe(200);
      await runDurableObjectAlarm(stub); // early/old alarm must preserve the promised expiry
      expect(await stored(stub)).toEqual(record);
      expect(await runInDurableObject(stub, (_instance, state) => state.storage.getAlarm())).toBe(record.purge_at * 1000);
    }
    vi.setSystemTime(record.purge_at * 1000);
    expect((await poll(stub)).status).toBe(404); // no dependence on alarm delivery
    expect(await stored(stub)).toEqual(record);
    await runDurableObjectAlarm(stub);
    expect(await stored(stub)).toBeNull();
    expect((await poll(stub)).status).toBe(404);
  });

  it("watchdogs an interrupted run with the original 30-minute failure lifetime", async () => {
    const { stub } = await seed(86400, { state: "running", started_at: COMPLETED_AT });
    await runDurableObjectAlarm(stub);
    const failed = await stored(stub);
    expect(failed.state).toBe("failed_transient");
    expect(failed.purge_at).toBe(COMPLETED_AT + 1800);
    expect((await poll(stub)).status).toBe(503);
  });
});

it("keeps the four-attempt billing budget during a 24-hour success lifetime", async () => {
  const { stub, record } = await seed(86400, { billing: {
    billing_id: `tan-missing-${crypto.randomUUID()}`, charge_seconds: 10,
    account_id: "missing-fixture-account", pending: "settle", attempts: 1,
  } });
  // The missing local reservation deterministically fails settlement. The
  // already-recorded terminal attempt plus three alarm attempts exhausts it.
  for (let attempts = 2; attempts <= 4; attempts++) {
    vi.setSystemTime((COMPLETED_AT + (attempts - 1) * 60) * 1000);
    await runDurableObjectAlarm(stub);
    const current = await stored(stub);
    expect(current.billing.attempts).toBe(attempts);
    expect(current.billing.pending).toBe(attempts < 4 ? "settle" : null);
    expect(current.purge_at).toBe(record.purge_at);
    expect((await poll(stub)).status).toBe(200);
  }
  await runDurableObjectAlarm(stub);
  expect((await stored(stub)).billing.attempts).toBe(4);
  vi.setSystemTime(record.purge_at * 1000);
  await runDurableObjectAlarm(stub);
  expect(await stored(stub)).toBeNull();
});

it("hides an expired result without discarding pending credit work before final cleanup", async () => {
  const { stub, record } = await seed(1800, { billing: {
    billing_id: `tan-expired-${crypto.randomUUID()}`, charge_seconds: 10,
    account_id: "missing-fixture-account", pending: "settle", attempts: 1,
  } });
  vi.setSystemTime(record.purge_at * 1000);
  expect((await poll(stub)).status).toBe(404);
  expect(await stored(stub)).toEqual(record);
  // Billed resubmit must retain the old unresolved action, not overwrite it.
  const response = await stub.fetch("https://job.test/submit", {
    method: "POST", body: JSON.stringify({
      usage_object_name: "retention-usage", usage_profile: "bearer",
      estimated_input_tokens: 10, subject: OWNER, request,
      billing: { account_id: "new-account", charge_seconds: 10 },
    }),
  });
  expect(response.status).toBe(503);
  expect((await response.json()).error).toBe("billing_unavailable");
  expect(await stored(stub)).toEqual(record);
  await runDurableObjectAlarm(stub);
  expect(await stored(stub)).toBeNull();
});

it("finishes delayed billing recovery at 30 minutes while retaining the successful result", async () => {
  const { stub, record } = await seed(86400, { billing: {
    billing_id: `tan-deadline-${crypto.randomUUID()}`, charge_seconds: 10,
    account_id: "missing-fixture-account", pending: "settle", attempts: 1,
    retry_deadline: COMPLETED_AT + 1800,
  } });
  vi.setSystemTime((COMPLETED_AT + 1800) * 1000);
  await runDurableObjectAlarm(stub);
  const current = await stored(stub);
  expect(current.billing.pending).toBeNull();
  expect(current.billing.attempts).toBe(1); // final attempt, not a renewed retry cycle
  expect(current.purge_at).toBe(record.purge_at);
  expect((await poll(stub)).status).toBe(200);
  expect(await runInDurableObject(stub, (_instance, state) => state.storage.getAlarm())).toBe(record.purge_at * 1000);
  vi.setSystemTime(record.purge_at * 1000);
  await runDurableObjectAlarm(stub);
  expect(await stored(stub)).toBeNull();
});

it("does not purge a served failure while its credit action remains pending", async () => {
  const { stub, record } = await seed(1800, { state: "failed_transient", billing: {
    billing_id: `tan-failure-${crypto.randomUUID()}`, charge_seconds: 10,
    account_id: "missing-fixture-account", pending: "release", attempts: 1,
    retry_deadline: COMPLETED_AT + 1800,
  } });
  expect((await poll(stub, "stranger")).status).toBe(404);
  expect((await poll(stub)).status).toBe(503);
  expect((await stored(stub)).billing).toEqual(record.billing);
  expect((await stored(stub)).purge_at).toBe(record.purge_at);
});

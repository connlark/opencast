import { SELF, env, runInDurableObject } from "cloudflare:test";
import { afterAll, expect } from "vitest";

const originalFetch = globalThis.fetch;
const audio = new Uint8Array(1024).fill(7);
const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", audio))]
  .map((byte) => byte.toString(16).padStart(2, "0")).join("");
globalThis.fetch = (input, init) => {
  const url = typeof input === "string" ? input : input.url;
  return url === "https://origin.example.com/gap.mp3"
    ? Promise.resolve(new Response(audio, { headers: { "content-type": "audio/mpeg", "content-length": String(audio.length) } }))
    : originalFetch(input, init);
};
afterAll(() => { globalThis.fetch = originalFetch; });

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export const stub = (id) => env.TRANSCRIPTION_JOB.get(env.TRANSCRIPTION_JOB.idFromName(id));
export const record = (id) => runInDurableObject(stub(id), async (_, state) => JSON.parse(await state.storage.get("job")));
export const mutateRecord = (id, mutate) => runInDurableObject(stub(id), async (_, state) => {
  const value = JSON.parse(await state.storage.get("job"));
  mutate(value);
  await state.storage.put("job", JSON.stringify(value));
});
export async function until(read, predicate, label = "condition", timeout = 20000) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    last = await read();
    if (predicate(last)) return last;
    await sleep(25);
  }
  throw new Error(`${label}: ${JSON.stringify(last)}`);
}
export async function post(path, body = {}) {
  const response = await SELF.fetch(`https://gap.test/v1/remote-transcription/${path}`, {
    method: "POST",
    headers: { authorization: "Bearer integration-test-bearer-token", "content-type": "application/json" },
    body: JSON.stringify({ schema_version: 1, ...body }),
  });
  expect(response.status, path).toBe(200);
  return response.json();
}
export async function create(seconds, hooks) {
  await post("account/bootstrap");
  const id = crypto.randomUUID();
  const { job } = await post("jobs", { client_request_id: id, episode_id: id,
    declared_duration_seconds: seconds, language_code: `fake:${hooks}`,
    enclosure_url: "https://origin.example.com/gap.mp3" });
  await until(() => record(job.job_id), (r) => r.state === "waiting_for_device_source", "source wait");
  return job.job_id;
}
export async function source(id, seconds) {
  await post(`jobs/${id}/source`, { source_identity: { sha256: hash, byte_count: audio.length, duration_seconds: seconds } });
}
export async function finish(id) {
  await until(() => post(`jobs/${id}/poll`), (r) => r.job.state === "result_ready", "result ready");
  return (await post(`jobs/${id}/result`)).result;
}
export async function cleanup(id) {
  await post(`jobs/${id}/cancel`);
  await waitForCleanup(id);
}
export async function waitForCleanup(id) {
  await until(async () => {
    const objects = [];
    for (const prefix of ["raw", "uploads", "chunks", "responses", "results"]) {
      objects.push(...(await env.TRANSCRIPTION_AUDIO.list({ prefix: `${prefix}/${id}/` })).objects);
    }
    return objects;
  }, (objects) => objects.length === 0, "cleanup");
}
export async function limiter(mutate) {
  const ns = env.TRANSCRIPTION_USAGE_LIMITER;
  return runInDurableObject(ns.get(ns.idFromName("global")), (_, state) => {
    const rows = state.storage.sql.exec("SELECT payload FROM limiter_state WHERE id = 1").toArray();
    const value = JSON.parse(rows[0].payload);
    if (mutate) {
      mutate(value);
      state.storage.sql.exec("UPDATE limiter_state SET payload = ? WHERE id = 1", JSON.stringify(value));
    }
    return value;
  });
}
export async function counter(name) {
  return Number((await env.TRANSCRIPTION_DB.prepare("SELECT value FROM counters WHERE name = ?").bind(name).first())?.value ?? 0);
}
export function assertBudget(r) {
  const reserved = r.gap_repair_attempts.reduce((n, a) => n + a.window_end - a.window_start, 0);
  expect(reserved).toBeLessThanOrEqual(r.gap_repair_audio_seconds + 1e-8);
  expect(r.gap_repair_audio_seconds).toBeLessThanOrEqual(Math.max(120, 0.15 * r.canonical_duration_seconds) + 1e-8);
  for (const chunk of r.chunks) {
    expect(r.gap_repair_attempts.filter((a) => a.chunk_index === chunk.index).length).toBeLessThanOrEqual(6);
  }
}

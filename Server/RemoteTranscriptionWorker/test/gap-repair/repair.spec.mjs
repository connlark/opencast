import { abortAllDurableObjects, env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { assertBudget, cleanup, counter, create, finish, limiter, mutateRecord, post, record, sleep, source, stub, until, waitForCleanup } from "./helpers.mjs";

describe("durable optional transcription repairs", () => {
  for (const concurrency of [1, 4]) {
    it(`accounts for repair audio with concurrency ${concurrency}`, async () => {
      const id = await create(10, `gap=0:2-8;conc=${concurrency}`);
      const balance = (await post("account/bootstrap")).balance;
      // The first job initializes the limiter through its primary admission.
      let before = 0;
      try { before = (await limiter()).spent_micro_usd; } catch {}
      await source(id, 10);
      const result = await finish(id);
      const r = await record(id);
      assertBudget(r);
      expect(r.gap_repair_audio_seconds).toBe(8);
      expect(r.gap_repair_attempts).toHaveLength(1);
      expect(r.gap_repair_attempts[0].issued).toBe(true);
      expect(result.text).toBe("remote repair0 repair1 transcription chunk0");
      expect((await limiter()).spent_micro_usd - before).toBe((concurrency === 1 ? 84 : 2500) + 67);
      expect(result.provenance.gap_repair.issued_audio_seconds).toBe(8);
      expect(result.provenance.gap_repair.chunks[0].report.words_filled).toBe(2);
      expect((await post("account/bootstrap")).balance.available_seconds).toBe(balance.available_seconds - 10);
      await cleanup(id);
    });
  }

  for (const driver of ["overlap", "wave"]) {
    it(`reserves one shared allowance for simultaneous ${driver} siblings`, async () => {
      const id = await create(1192, `gap=*:2-98;conc=4;latency=250;rlat=250;nooverlap=${driver === "wave"}`);
      await source(id, 1192);
      const result = await finish(id);
      const r = await record(id);
      assertBudget(r);
      expect(r.gap_repair_audio_seconds).toBe(99.5);
      expect(r.gap_repair_attempts).toHaveLength(1);
      expect(r.chunk_work.filter((w) => w.completed)).toHaveLength(4);
      expect(result.text).toContain("repair0");
      await cleanup(id);
    });
  }

  it("uses a feasible later window when only a partial allowance remains", async () => {
    const id = await create(10, "gap=0:2-8;conc=1");
    await mutateRecord(id, (r) => { r.gap_repair_audio_seconds = 113; });
    await source(id, 10);
    expect((await finish(id)).text).toContain("repair0");
    const r = await record(id);
    expect(r.gap_repair_audio_seconds).toBe(119.5);
    expect(r.gap_repair_attempts[0].ordinal).toBe(1);
    assertBudget(r);
    await cleanup(id);
  });

  it("skips a long unaffordable hole and repairs the shorter speech hole", async () => {
    const id = await create(300, "gap=0:200-220;conc=1");
    await source(id, 300);
    const result = await finish(id);
    expect(result.text).toContain("repair0");
    const report = result.provenance.gap_repair.chunks[0].report;
    expect(report.unaffordable_windows).toBeGreaterThan(0);
    expect(report.budget_exhausted).toBe(false);
    assertBudget(await record(id));
    await cleanup(id);
  });

  it("daily-cap denial preserves the primary, credit settlement, and FIFO state", async () => {
    const id = await create(10, "gap=0:2-8;conc=1;latency=300");
    const before = await limiter();
    const balance = (await post("account/bootstrap")).balance;
    await source(id, 10);
    await until(() => limiter(), (s) => s.active.some((a) => a.job_id === id));
    // Only the optional call will see the cap; the primary is already admitted.
    await limiter((s) => { s.spent_micro_usd = Number(env.DAILY_SPEND_CAP_USD_MICRO); });
    const result = await finish(id);
    expect(result.text).toBe("remote transcription chunk0");
    const r = await record(id);
    expect(r.gap_repair_attempts).toHaveLength(1);
    expect(r.gap_repair_attempts[0]).toMatchObject({ issued: false, outcome: "service_denied" });
    expect((await post("account/bootstrap")).balance.available_seconds).toBe(balance.available_seconds - 10);
    expect((await limiter()).active).toEqual([]);
    expect((await limiter()).tickets).toEqual([]);
    await limiter((s) => { s.spent_micro_usd = before.spent_micro_usd; });
    await cleanup(id);
  });

  for (const phase of ["primary", "repair"]) {
    it(`cancelling during ${phase} starts no further repairs`, async () => {
      const before = await counter("ai_attempts");
      const id = await create(10, `gap=0:2-8;conc=1;latency=${phase === "primary" ? 1000 : 0};rlat=1000;rreply=empty`);
      await source(id, 10);
      if (phase === "primary") await until(() => counter("ai_attempts"), (n) => n > before);
      else await until(() => record(id), (r) => r.gap_repair_attempts.some((a) => a.issued));
      await cleanup(id);
      await sleep(1300);
      const r = await record(id);
      expect(r.state).toBe("cancelled");
      expect(r.gap_repair_attempts).toHaveLength(phase === "primary" ? 0 : 1);
      assertBudget(r);
      // Observe the original cancellation's cleanup after the in-flight
      // call returns; a second cancel would hide a late-write leak.
      await waitForCleanup(id);
    });
  }

  for (const reply of ["empty", "error", "invalid_json"]) {
    it(`accounts for issued ${reply} replies and retains the primary`, async () => {
      const id = await create(10, `gap=0:2-8;conc=1;rreply=${reply}`);
      const before = (await limiter()).spent_micro_usd;
      await source(id, 10);
      expect((await finish(id)).text).toBe("remote transcription chunk0");
      const r = await record(id);
      expect(r.gap_repair_attempts).toHaveLength(reply === "empty" ? 2 : 1);
      expect(r.gap_repair_attempts.every((a) => a.issued)).toBe(true);
      const repairSpend = r.gap_repair_attempts.reduce((sum, a) => sum + Math.ceil((a.window_end - a.window_start) * 500 / 60), 0);
      expect((await limiter()).spent_micro_usd - before).toBe(84 + repairSpend);
      assertBudget(r);
      await cleanup(id);
    });
  }

  it("bounds optional latency while retaining issued spend", async () => {
    const id = await create(10, "gap=0:2-8;conc=1;rlat=4000;rwall=150");
    await source(id, 10);
    expect((await finish(id)).text).toBe("remote transcription chunk0");
    const r = await record(id);
    expect(r.gap_repair_attempts).toHaveLength(1);
    expect(r.gap_repair_attempts[0]).toMatchObject({ issued: true, outcome: "timeout" });
    expect(r.gap_repair_audio_seconds).toBe(8);
    await cleanup(id);
  });

  it("failed repair publication preserves primary bytes and durable accounting", async () => {
    const id = await create(10, "gap=0:2-8;conc=1;rwritefail=true");
    await source(id, 10);
    const result = await finish(id);
    expect(result.text).toBe("remote transcription chunk0");
    expect(result.provenance.gap_repair.chunks).toEqual([]);
    expect(result.provenance.gap_repair.issued_audio_seconds).toBe(8);
    expect((await record(id)).gap_repair_audio_seconds).toBe(8);
    await cleanup(id);
  });

  it("restart during repair recovers the primary without refunding or repeating inference", async () => {
    const id = await create(10, "gap=0:2-8;conc=1;rlat=4000");
    await source(id, 10);
    await until(() => record(id), (r) => r.gap_repair_attempts.some((a) => a.issued));
    const before = await record(id);
    const calls = await counter("ai_attempts");
    await abortAllDurableObjects();
    await runInDurableObject(stub(id), (_, state) => state.storage.setAlarm(Date.now()));
    const result = await finish(id);
    const after = await record(id);
    expect(result.text).toBe("remote transcription chunk0");
    expect(after.gap_repair_attempts).toEqual(before.gap_repair_attempts);
    expect(after.gap_repair_audio_seconds).toBe(8);
    expect(await counter("ai_attempts")).toBe(calls);
    await cleanup(id);
  });
});

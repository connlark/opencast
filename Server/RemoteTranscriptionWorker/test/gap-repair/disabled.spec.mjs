import { it, expect } from "vitest";
import { cleanup, create, finish, record, source } from "./helpers.mjs";

it("GAP_REPAIR_ENABLED=false disables the real orchestration and fake hook", async () => {
  const id = await create(10, "gap=0:2-8;conc=4");
  await source(id, 10);
  const result = await finish(id);
  expect(result.text).toBe("remote transcription chunk0");
  expect(result.provenance.gap_repair.enabled).toBe(false);
  expect((await record(id)).gap_repair_attempts).toEqual([]);
  expect((await record(id)).gap_repair_audio_seconds).toBe(0);
  await cleanup(id);
});

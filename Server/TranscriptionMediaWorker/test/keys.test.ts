// Focused TS tests for the media worker: the R2 allow-list,
// the per-job binding, and the shim deadline map. Pure logic, no container
// harness needed.
import { describe, expect, it } from "vitest";

import { isKeyAllowed, jobBindingError, SHIM_DEADLINE_MS } from "../src/keys";

describe("isKeyAllowed", () => {
  it("allows GET of raw/chunks/uploads job keys", () => {
    expect(isKeyAllowed("GET", "raw/job-abc/source")).toBe(true);
    expect(isKeyAllowed("GET", "chunks/job-abc/0.mp3")).toBe(true);
    expect(isKeyAllowed("GET", "uploads/job-abc/source")).toBe(true);
  });

  it("allows PUT only under the writable raw/chunks prefixes", () => {
    expect(isKeyAllowed("PUT", "chunks/job-abc/0.mp3")).toBe(true);
    expect(isKeyAllowed("PUT", "raw/job-abc/source")).toBe(true);
    // uploads/ is read-only: no write.
    expect(isKeyAllowed("PUT", "uploads/job-abc/source")).toBe(false);
  });

  it("rejects keys outside the job prefixes and malformed shapes", () => {
    expect(isKeyAllowed("GET", "secret")).toBe(false);
    expect(isKeyAllowed("GET", "raw/not-a-job/source")).toBe(false);
    expect(isKeyAllowed("GET", "//raw/job-abc/source")).toBe(false);
    // A literal ../ that survives decoding stays inside the matched prefix
    // (R2 keys are opaque) but is still bounded to the job prefix regex.
    expect(isKeyAllowed("GET", "raw/job-abc/../secret")).toBe(true);
    expect(isKeyAllowed("DELETE", "chunks/job-abc/0.mp3")).toBe(true);
  });
});

describe("jobBindingError", () => {
  // Real gateway shape: job_id is `job-<random>`, keys are `<bucket>/{job_id}/…`.
  it("accepts a probe/chunk body whose keys match its job_id", () => {
    expect(
      jobBindingError("/probe", { job_id: "job-abc", source_key: "raw/job-abc/source" }),
    ).toBeNull();
    expect(
      jobBindingError("/probe", {
        job_id: "job-abc",
        source_key: "uploads/job-abc/source",
      }),
    ).toBeNull();
    expect(
      jobBindingError("/chunk", {
        job_id: "job-abc",
        source_key: "raw/job-abc/source",
        chunk_prefix: "chunks/job-abc/",
      }),
    ).toBeNull();
  });

  it("rejects a source_key or chunk_prefix pointing at another job", () => {
    expect(
      jobBindingError("/probe", {
        job_id: "job-abc",
        source_key: "raw/job-victim/source",
      }),
    ).toBe("forbidden_source_key");
    expect(
      jobBindingError("/chunk", {
        job_id: "job-abc",
        source_key: "raw/job-abc/source",
        chunk_prefix: "chunks/job-victim/",
      }),
    ).toBe("forbidden_chunk_prefix");
  });

  it("rejects a missing or malformed job_id", () => {
    expect(jobBindingError("/probe", { source_key: "raw/job-abc/source" })).toBe(
      "invalid_job_id",
    );
    // Missing the `job-` prefix, or containing path separators, is rejected.
    expect(
      jobBindingError("/probe", { job_id: "abc", source_key: "raw/abc/source" }),
    ).toBe("invalid_job_id");
    expect(
      jobBindingError("/probe", { job_id: "job-../x", source_key: "raw/job-../x/source" }),
    ).toBe("invalid_job_id");
    expect(jobBindingError("/probe", null)).toBe("invalid_job_id");
  });

  it("requires the chunk_prefix only for /chunk", () => {
    // A probe body without chunk_prefix is fine.
    expect(
      jobBindingError("/probe", { job_id: "job-abc", source_key: "raw/job-abc/source" }),
    ).toBeNull();
    // A chunk body missing chunk_prefix is rejected.
    expect(
      jobBindingError("/chunk", { job_id: "job-abc", source_key: "raw/job-abc/source" }),
    ).toBe("forbidden_chunk_prefix");
  });
});

describe("SHIM_DEADLINE_MS", () => {
  it("maps the three container routes and nothing else", () => {
    expect(SHIM_DEADLINE_MS["/wake"]).toBe(30_000);
    expect(SHIM_DEADLINE_MS["/probe"]).toBe(2_400_000);
    expect(SHIM_DEADLINE_MS["/chunk"]).toBe(3_900_000);
    expect(SHIM_DEADLINE_MS["/other"]).toBeUndefined();
  });
});

// Pure key/routing predicates for the media worker, separated from the
// Cloudflare runtime wiring in index.ts so the security boundary (the R2
// allow-list, the per-job binding, the shim deadline map) is unit-testable
// with no container harness (Phase 10 TMW-5).

const ALLOWED_KEY_PATTERN = /^(raw|chunks)\/job-[A-Za-z0-9_-]+\//;
// Exact-device uploads (pass 2) are probe/chunk inputs, never container
// outputs: readable, not writable.
const READ_ONLY_KEY_PATTERN = /^uploads\/job-[A-Za-z0-9_-]+\//;

// Gateway job ids are minted as `job-<random>` (RTW worker_app.rs), and R2
// keys are `raw/{job_id}/source`, `uploads/{job_id}/source`,
// `chunks/{job_id}/` — so job_id already carries the `job-` prefix that the
// container's allow-list also requires. Pinning the prefix here keeps the
// bound keys inside isKeyAllowed's `job-` regex.
const JOB_ID_PATTERN = /^job-[A-Za-z0-9_-]+$/;

/// The R2 egress allow-list: reads are allowed under raw/chunks/uploads job
/// prefixes; writes only under the raw/chunks prefixes the container owns.
export function isKeyAllowed(method: string, key: string): boolean {
  const readable = ALLOWED_KEY_PATTERN.test(key) || READ_ONLY_KEY_PATTERN.test(key);
  if (!readable) {
    return false;
  }
  // Any non-GET method may only touch the writable (raw/chunks) prefixes.
  return method === "GET" || ALLOWED_KEY_PATTERN.test(key);
}

/// Outer shim deadlines above the container's own per-op budgets. Probe
/// covers a full source download plus a probe; chunk covers the literal
/// budget sum of one download + probe + extract + normalize cycle; wake is
/// designed to return immediately. Returns undefined for unknown paths.
export const SHIM_DEADLINE_MS: Readonly<Record<string, number>> = {
  "/wake": 30_000,
  "/probe": 2_400_000,
  "/chunk": 3_900_000,
};

function jobIdFromPayload(payload: unknown): string | null {
  if (typeof payload !== "object" || payload === null) {
    return null;
  }
  const jobId = (payload as Record<string, unknown>).job_id;
  return typeof jobId === "string" && JOB_ID_PATTERN.test(jobId) ? jobId : null;
}

function sourceKeyBelongsToJob(sourceKey: string, jobId: string): boolean {
  // jobId already includes the `job-` prefix; keys are `<bucket>/{job_id}/…`.
  return (
    sourceKey.startsWith(`raw/${jobId}/`) ||
    sourceKey.startsWith(`uploads/${jobId}/`)
  );
}

function chunkPrefixBelongsToJob(chunkPrefix: string, jobId: string): boolean {
  return chunkPrefix === `chunks/${jobId}/`;
}

/// Binds a probe/chunk request's object keys to the job_id already in its
/// body, so one container instance (shared across jobs) cannot be steered to
/// read or overwrite another job's audio (Phase 10 TMW-3). Returns an error
/// code string when the binding fails, or null when the body is well-bound.
export function jobBindingError(pathname: string, payload: unknown): string | null {
  const jobId = jobIdFromPayload(payload);
  if (jobId === null) {
    return "invalid_job_id";
  }
  const record = payload as Record<string, unknown>;
  const sourceKey = record.source_key;
  if (typeof sourceKey !== "string" || !sourceKeyBelongsToJob(sourceKey, jobId)) {
    return "forbidden_source_key";
  }
  if (pathname === "/chunk") {
    const chunkPrefix = record.chunk_prefix;
    if (typeof chunkPrefix !== "string" || !chunkPrefixBelongsToJob(chunkPrefix, jobId)) {
      return "forbidden_chunk_prefix";
    }
  }
  return null;
}

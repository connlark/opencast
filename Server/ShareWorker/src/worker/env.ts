// Hand-typed rather than @cloudflare/workers-types, whose globals collide with
// lib.dom; the worker renders Page → Player, which needs DOM types.
export interface AssetsBinding {
  fetch(request: Request): Promise<Response>;
}

export interface RateLimitBinding {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  ASSETS: AssetsBinding;
  DOWNLOAD_RATE_LIMITER: RateLimitBinding;
  LANE?: string;
  /** Test override; defaults to 1 GiB. */
  DOWNLOAD_MAX_BYTES?: string;
  /** Test override; defaults to 10 s. */
  UPSTREAM_HEADER_TIMEOUT_MS?: string;
}

export function positiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

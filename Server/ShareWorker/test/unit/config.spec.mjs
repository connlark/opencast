// Wrangler config contract, read through wrangler itself so environment
// inheritance is applied exactly as a deploy would apply it. The assertions
// hold for any deployment of this worker (names, zone, and rate-limit ids are
// the deployer's), so the same file checks a self-hosted template.
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { unstable_readConfig } from "wrangler";

const workerDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const configPath = path.join(workerDir, "wrangler.jsonc");

const LANES = [
  { env: undefined, lane: "development", suffix: "" },
  { env: "prod-staging", lane: "prod-staging", suffix: "-prod-staging" },
  { env: "production", lane: "production", suffix: "-production" },
];

function read(env) {
  return unstable_readConfig({ config: configPath, env }, { hideWarnings: true });
}

function installedWorkerdBuildDate() {
  for (let directory = workerDir; directory !== path.dirname(directory); directory = path.dirname(directory)) {
    const manifest = path.join(directory, "node_modules", "workerd", "package.json");
    if (existsSync(manifest)) {
      const { version } = JSON.parse(readFileSync(manifest, "utf8"));
      const match = /^1\.(\d{4})(\d{2})(\d{2})\./.exec(version);
      expect(match, `unexpected workerd version ${version}`).not.toBeNull();
      return `${match[1]}-${match[2]}-${match[3]}`;
    }
  }
  throw new Error("workerd is not installed");
}

const configs = LANES.map(({ env }) => read(env));
const [development] = configs;

describe.each(LANES.map((lane, index) => ({ ...lane, config: configs[index] })))("$lane lane", ({ lane, suffix, config }) => {
  it("is named after the top-level worker and labelled with its lane", () => {
    expect(config.name).toBe(`${development.name}${suffix}`);
    expect(config.vars).toEqual({ LANE: lane });
  });

  it("stays within the installed workerd and keeps nodejs_compat for node:zlib", () => {
    expect(config.compatibility_date <= installedWorkerdBuildDate()).toBe(true);
    expect(config.compatibility_flags).toContain("nodejs_compat");
  });

  // Workers Logs attaches the request URL (the token) to every log event, even
  // with invocation logs off, so nothing may be stored at all.
  it("never stores the token: observability is off", () => {
    expect(config.observability?.enabled).toBe(false);
    expect(config.observability?.logs?.enabled ?? false).toBe(false);
    expect(config.observability?.traces?.enabled ?? false).toBe(false);
  });

  it("serves assets before the worker, with no HTML or SPA fallbacks", () => {
    expect(config.assets.binding).toBe("ASSETS");
    expect(config.assets.directory).toBeUndefined();
    expect(config.assets.html_handling).toBe("none");
    expect(config.assets.not_found_handling).toBe("none");
    expect(config.assets.run_worker_first).toBeUndefined();
  });

  it("has the download rate limiter and no other bindings", () => {
    expect(config.ratelimits).toHaveLength(1);
    expect(config.ratelimits[0]).toMatchObject({ name: "DOWNLOAD_RATE_LIMITER", simple: { limit: 20, period: 60 } });
    for (const key of ["kv_namespaces", "d1_databases", "r2_buckets", "services", "durable_objects"]) {
      const value = config[key];
      const bindings = Array.isArray(value) ? value : (value?.bindings ?? []);
      expect(bindings, key).toEqual([]);
    }
    expect([...(config.queues?.producers ?? []), ...(config.queues?.consumers ?? [])]).toEqual([]);
  });

  if (lane === "production") {
    it("serves only the zone's /e/* route, never workers.dev", () => {
      expect(config.workers_dev).toBe(false);
      expect(config.routes).toHaveLength(1);
      const [{ pattern, zone_name: zone }] = config.routes;
      expect(pattern).toBe(`${zone}/e/*`);
    });
  } else {
    it("has no routes", () => {
      expect(config.routes ?? []).toEqual([]);
    });
  }
});

describe("lanes", () => {
  it("count downloads separately: rate-limit namespace ids are account-wide", () => {
    const ids = configs.map((config) => config.ratelimits[0].namespace_id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});

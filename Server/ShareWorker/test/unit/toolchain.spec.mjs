// Both plugins pin wrangler and miniflare exactly, and wrangler pins workerd:
// each must be what the catalog installs, or a second workerd splits the
// compatibility-date ceiling (docs/build.md). Bump them together.
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const workerDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

// Node's own lookup order, done by hand: the plugin is import-only and does
// not export ./package.json, so require.resolve cannot find its manifest.
function manifest(name) {
  for (let directory = workerDir; directory !== path.dirname(directory); directory = path.dirname(directory)) {
    const candidate = path.join(directory, "node_modules", name, "package.json");
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, "utf8"));
    }
  }
  throw new Error(`${name} is not installed`);
}

describe("vitest plugin toolchain pins", () => {
  const plugin = manifest("@cloudflare/vitest-plugin");

  it.each(["wrangler", "miniflare"])("pins the installed %s", (name) => {
    expect(plugin.dependencies[name]).toBe(manifest(name).version);
  });

  it("is the version the catalog declares", () => {
    const yarnrc = readFileSync(path.join(workerDir, "..", "..", ".yarnrc.yml"), "utf8");
    expect(yarnrc).toMatch(new RegExp(`^  "@cloudflare/vitest-plugin": ${plugin.version.replaceAll(".", "\\.")}$`, "m"));
  });
});

describe("vite plugin toolchain pins", () => {
  const plugin = manifest("@cloudflare/vite-plugin");

  it.each(["wrangler", "miniflare"])("pins the installed %s", (name) => {
    expect(plugin.dependencies[name]).toBe(manifest(name).version);
  });

  it("is the version the workspace declares", () => {
    expect(JSON.parse(readFileSync(path.join(workerDir, "package.json"), "utf8")).devDependencies["@cloudflare/vite-plugin"]).toBe(plugin.version);
  });
});

describe("wrangler toolchain pins", () => {
  it("pins the installed workerd", () => {
    expect(manifest("wrangler").dependencies.workerd).toBe(manifest("workerd").version);
  });
});

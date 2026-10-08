// @cloudflare/vite-plugin pins wrangler, miniflare and workerd exactly, and
// @cloudflare/vitest-plugin pins wrangler and miniflare exactly. Those must be
// the versions the root catalog installs, or the tree grows a second workerd
// and the compatibility-date ceiling splits (docs/build.md). Bump both plugins
// and the catalog together.
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

  it.each(["wrangler", "miniflare", "workerd"])("pins the installed %s", (name) => {
    expect(plugin.dependencies[name]).toBe(manifest(name).version);
  });

  it("is the version the workspace declares", () => {
    expect(JSON.parse(readFileSync(path.join(workerDir, "package.json"), "utf8")).devDependencies["@cloudflare/vite-plugin"]).toBe(plugin.version);
  });
});

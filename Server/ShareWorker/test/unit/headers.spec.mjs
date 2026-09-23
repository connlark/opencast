// public/_headers is copied into the client build and applied by the assets
// binding. The fixed-name bundles under /e/_/ are only safe to cache forever
// because every page references them with ?v=<build id>.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const workerDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

function parseHeaders(text) {
  const rules = new Map();
  let current = null;
  for (const line of text.split("\n")) {
    if (line.trim() === "" || line.trim().startsWith("#")) {
      continue;
    }
    if (!/^\s/.test(line)) {
      current = new Map();
      rules.set(line.trim(), current);
    } else if (current) {
      const [name, ...value] = line.trim().split(":");
      current.set(name.trim().toLowerCase(), value.join(":").trim());
    }
  }
  return rules;
}

describe("public/_headers", () => {
  const rules = parseHeaders(readFileSync(path.join(workerDir, "public", "_headers"), "utf8"));

  it("caches the /e/_/ bundles immutably and without sniffing", () => {
    const assets = rules.get("/e/_/*");
    expect(assets?.get("cache-control")).toBe("public, max-age=31536000, immutable");
    expect(assets?.get("x-content-type-options")).toBe("nosniff");
  });

  it("has no rule that could reach share pages or downloads", () => {
    expect([...rules.keys()]).toEqual(["/e/_/*"]);
  });
});

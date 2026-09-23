import { execFileSync } from "node:child_process";
import { cloudflare } from "@cloudflare/vite-plugin";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";
import { alias } from "./alias.ts";

// The plugin builds the worker before the client, so the worker cannot read a
// client manifest. Client assets therefore get fixed names under /e/_/ and
// the page appends ?v=<build id>; public/_headers makes them immutable.
const lane = process.env.CLOUDFLARE_ENV || "dev";

function buildID(): string {
  const stamp = Date.now().toString(36);
  try {
    const git = (...args: string[]) =>
      execFileSync("git", args, { cwd: import.meta.dirname, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    const sha = git("rev-parse", "--short", "HEAD");
    return git("status", "--porcelain", "--", ".") === "" ? sha : `${sha}-${stamp}`;
  } catch {
    return stamp;
  }
}

export default defineConfig({
  plugins: [tailwindcss(), cloudflare({ configPath: "./wrangler.jsonc" })],
  resolve: { alias },
  define: { __BUILD_ID__: JSON.stringify(buildID()) },
  build: { outDir: `dist/${lane}`, emptyOutDir: true },
  environments: {
    client: {
      build: {
        modulePreload: false,
        rollupOptions: {
          input: "src/client/entry.tsx",
          // Scoped to the client: a top-level `output` would rename the worker
          // bundle too. One chunk, because only the entry URL carries ?v=.
          output: {
            entryFileNames: "e/_/[name].js",
            chunkFileNames: "e/_/[name].js",
            assetFileNames: "e/_/[name][extname]",
            codeSplitting: false,
          },
        },
      },
    },
  },
});

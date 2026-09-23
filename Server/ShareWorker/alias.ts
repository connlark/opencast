// The page is authored against React's types and JSX runtime and ships
// preact/compat (11 KB gzipped instead of 72 KB). Anchored patterns so
// `react-dom/client` never falls through to the `react-dom` entry, and each
// JSX runtime maps to preact's own. Shared by vite.config.ts and the unit
// tests so the alias is defined once.
import { fileURLToPath } from "node:url";

export const alias = [
  { find: /^react$/, replacement: "preact/compat" },
  { find: /^react-dom$/, replacement: "preact/compat" },
  { find: /^react-dom\/client$/, replacement: fileURLToPath(new URL("./src/client/preact-shim.ts", import.meta.url)) },
  { find: /^react\/jsx-runtime$/, replacement: "preact/jsx-runtime" },
  { find: /^react\/jsx-dev-runtime$/, replacement: "preact/jsx-dev-runtime" },
];

import { readFileSync } from 'node:fs';

// Exercise the packaged Worker under the same opt-in runtime behavior as prod.
const config = readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8');
export const compatibilityDate = JSON.parse(config.match(/^compatibility_date\s*=\s*("[^"]+")/m)[1]);
export const compatibilityFlags = JSON.parse(config.match(/^compatibility_flags\s*=\s*(\[[^\]]*\])/m)[1]);

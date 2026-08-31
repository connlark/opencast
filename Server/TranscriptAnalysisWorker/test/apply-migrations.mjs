import { applyD1Migrations, env } from "cloudflare:test";

await applyD1Migrations(env.TRANSCRIPT_ANALYSIS_DB, env.TEST_MIGRATIONS);

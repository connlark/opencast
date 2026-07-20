import { applyD1Migrations, env } from "cloudflare:test";

await applyD1Migrations(env.TRANSCRIPTION_DB, env.TEST_MIGRATIONS);

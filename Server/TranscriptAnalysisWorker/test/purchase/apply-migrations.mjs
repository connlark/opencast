import { applyD1Migrations, env } from "cloudflare:test";

await applyD1Migrations(env.TRANSCRIPT_ANALYSIS_DB, env.TEST_MIGRATIONS);
// The auxiliary PurchaseWorker shares this database (same database ID).
await applyD1Migrations(env.PURCHASE_TEST_DB, env.PURCHASE_TEST_MIGRATIONS);

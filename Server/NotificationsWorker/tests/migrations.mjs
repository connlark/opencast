import { readFile, readdir } from 'node:fs/promises';
import { unstable_splitSqlQuery } from 'wrangler';
// Use the pinned deployment tool's parser and per-file transaction, including
// its trigger/CASE handling. Do not mask Wrangler migration failures here.
export async function migrate(db, directory) {
  for (const file of (await readdir(directory)).filter(f => f.endsWith('.sql')).sort()) {
    const sql = await readFile(new URL(file, directory), 'utf8');
    await db.batch(unstable_splitSqlQuery(sql).map(query => db.prepare(query)));
  }
}

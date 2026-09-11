// Applies migrations/NNN_*.sql in filename order, each in its own transaction,
// recording what ran in schema_migrations. Idempotent.
import fs from 'node:fs/promises';
import path from 'node:path';
import { assertConfig, config, BACKEND_ROOT } from '../config.js';
import { pool, withTransaction, closePool } from './pool.js';

const MIGRATIONS_DIR = path.join(BACKEND_ROOT, 'migrations');

export async function migrate({ silent = false } = {}) {
  const say = (m) => {
    if (!silent) console.log(m);
  };

  await pool.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      filename   text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT now()
    )
  `);

  const { rows } = await pool.query('SELECT filename FROM schema_migrations');
  const applied = new Set(rows.map((r) => r.filename));

  const files = (await fs.readdir(MIGRATIONS_DIR))
    .filter((f) => f.endsWith('.sql'))
    .sort();

  let ran = 0;
  for (const file of files) {
    if (applied.has(file)) continue;
    const sql = await fs.readFile(path.join(MIGRATIONS_DIR, file), 'utf8');
    await withTransaction(async (client) => {
      await client.query(sql);
      await client.query('INSERT INTO schema_migrations (filename) VALUES ($1)', [file]);
    });
    say(`  applied ${file}`);
    ran += 1;
  }
  say(ran === 0 ? '  schema already up to date' : `  ${ran} migration(s) applied`);
  return ran;
}

// Direct invocation: `npm run migrate`
if (import.meta.url === `file://${process.argv[1]}`) {
  assertConfig();
  console.log(`migrating ${config.databaseUrl}`);
  migrate()
    .then(() => closePool())
    .then(() => process.exit(0))
    .catch((err) => {
      console.error(`migration failed: ${err.message}`);
      process.exit(1);
    });
}

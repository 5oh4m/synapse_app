// npm run db:reset — drop, create, migrate, seed.
//
// Refuses to touch anything that is not obviously a local development database,
// so a stray DATABASE_URL cannot lose real data.
import { execFileSync } from 'node:child_process';
import { assertConfig, config } from '../src/config.js';

assertConfig();

const url = new URL(config.databaseUrl.replace(/^postgres(ql)?:/, 'http:'));
const dbName = url.pathname.replace(/^\//, '');
const host = url.hostname || 'localhost';
const port = url.port || '5432';
const user = url.username || undefined;

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '0.0.0.0']);
if (!LOCAL_HOSTS.has(host)) {
  console.error(`\nRefusing to reset a non-local database (host: ${host}).\n`);
  process.exit(1);
}
if (!dbName) {
  console.error('\nDATABASE_URL has no database name.\n');
  process.exit(1);
}
if (process.env.NODE_ENV === 'production') {
  console.error('\nRefusing to run db:reset with NODE_ENV=production.\n');
  process.exit(1);
}

const pg = (cmd, args) => {
  const base = ['-h', host, '-p', port];
  if (user) base.push('-U', user);
  execFileSync(cmd, [...base, ...args], { stdio: 'inherit' });
};

console.log(`\nresetting ${dbName} on ${host}:${port}\n`);

try {
  // --if-exists keeps this idempotent; --force disconnects idle sessions (pg 13+).
  pg('dropdb', ['--if-exists', '--force', dbName]);
  console.log(`  dropped ${dbName}`);
} catch (err) {
  console.error(`  could not drop ${dbName}: ${err.message}`);
  process.exit(1);
}

try {
  pg('createdb', [dbName]);
  console.log(`  created ${dbName}`);
} catch (err) {
  console.error(`  could not create ${dbName}: ${err.message}`);
  process.exit(1);
}

// Imported after the database exists, so the pool connects to something real.
const { migrate } = await import('../src/db/migrate.js');
const { seed } = await import('./seed.js');
const { closePool } = await import('../src/db/pool.js');

console.log('  migrations');
await migrate();
console.log('  seed');
await seed();
await closePool();
console.log('\ndone. Sign in as demo.educator@quizzle.app / demo-password-1\n');

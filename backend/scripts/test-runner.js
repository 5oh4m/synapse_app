// npm test — prepares quizzle_test, then runs the suite with node:test.
import { execFileSync, spawnSync } from 'node:child_process';

process.env.NODE_ENV = 'test';

const { assertConfig, config, BACKEND_ROOT } = await import('../src/config.js');
assertConfig();

const url = new URL(config.databaseUrl.replace(/^postgres(ql)?:/, 'http:'));
const dbName = url.pathname.replace(/^\//, '');
const host = url.hostname || 'localhost';
const port = url.port || '5432';

if (!/test/i.test(dbName)) {
  console.error(
    `\nRefusing to run the suite against "${dbName}": the test database name must contain "test".` +
      '\nSet DATABASE_URL in backend/.env.test (e.g. postgres://localhost:5432/quizzle_test).\n',
  );
  process.exit(1);
}

// Create the database if it is not there yet; an existing one is fine, the
// suite truncates in its own beforeEach.
const exists = spawnSync('psql', ['-h', host, '-p', port, '-d', dbName, '-c', 'SELECT 1'], {
  stdio: 'ignore',
});
if (exists.status !== 0) {
  console.log(`creating ${dbName}`);
  try {
    execFileSync('createdb', ['-h', host, '-p', port, dbName], { stdio: 'inherit' });
  } catch (err) {
    console.error(`\nCould not create ${dbName}: ${err.message}\n`);
    process.exit(1);
  }
}

const { migrate } = await import('../src/db/migrate.js');
const { closePool } = await import('../src/db/pool.js');
await migrate({ silent: true });
await closePool();

const { ensureFixtures } = await import('../tests/fixtures/make-fixtures.js');
await ensureFixtures();

// Node's --test wants files or a glob; handing it a bare directory makes it try
// to load `tests` as the entry module instead.
const args = process.argv.slice(2);
const target = args.length > 0 ? args : ['tests/*.test.js'];
const result = spawnSync(
  process.execPath,
  ['--test', '--test-reporter=spec', '--test-concurrency=1', ...target],
  {
    cwd: BACKEND_ROOT,
    stdio: 'inherit',
    env: { ...process.env, NODE_ENV: 'test' },
  },
);
process.exit(result.status ?? 1);

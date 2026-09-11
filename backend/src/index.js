// Boot: validate config, check the database, apply migrations, listen, attach
// the WS hub, start the auto-reveal timer, shut down cleanly.
import http from 'node:http';
import { assertConfig, config } from './config.js';
import { log } from './log.js';
import { createApp } from './app.js';
import { pool, closePool } from './db/pool.js';
import { migrate } from './db/migrate.js';
import { attachHub, closeHub } from './realtime/hub.js';
import { startAutoRevealTimer, stopAutoRevealTimer } from './services/session.service.js';

assertConfig();

const redactedDsn = config.databaseUrl.replace(/\/\/([^:@/]+):[^@]*@/, '//$1:***@');

async function checkDatabase() {
  try {
    const { rows } = await pool.query('SELECT current_database() AS db, version() AS v');
    log.banner(`  database  ${rows[0].db} (${rows[0].v.split(',')[0]})`);
  } catch (err) {
    const hint =
      err.code === '3D000'
        ? 'The database does not exist. Create it with:\n\n    createdb quizzle\n    npm run migrate\n'
        : err.code === 'ECONNREFUSED'
          ? 'Nothing is listening there. Start PostgreSQL, then try again.\n'
          : err.code === '28P01' || err.code === '28000'
            ? 'The credentials in DATABASE_URL were rejected.\n'
            : '';
    console.error(
      [
        '',
        `quizzle backend cannot reach PostgreSQL at ${redactedDsn}`,
        `  ${err.message}`,
        '',
        hint,
      ].join('\n'),
    );
    process.exit(1);
  }
}

async function main() {
  await checkDatabase();
  log.banner('  migrations');
  await migrate({ silent: false });

  const app = createApp();
  const server = http.createServer(app);
  attachHub(server);
  startAutoRevealTimer();

  // Readable message naming the port, not a stack trace.
  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE') {
      console.error(
        [
          '',
          `Port ${config.port} is already in use, so the quizzle backend did not start.`,
          '',
          'Either stop whatever is holding it:',
          '',
          `    lsof -ti tcp:${config.port} | xargs kill`,
          '',
          'or run this server on a different port:',
          '',
          `    PORT=${config.port + 1} npm start`,
          '',
        ].join('\n'),
      );
      process.exit(1);
    }
    if (err.code === 'EACCES') {
      console.error(`\nNo permission to bind port ${config.port}. Pick a port above 1024.\n`);
      process.exit(1);
    }
    console.error(`\nThe server could not start: ${err.message}\n`);
    process.exit(1);
  });

  server.listen(config.port, () => {
    log.banner('');
    log.banner(`  quizzle backend  http://localhost:${config.port}/api`);
    log.banner(`  websocket        ws://localhost:${config.port}/ws?token=<accessToken>`);
    log.banner(`  ai provider      ${config.ai.provider}${config.ai.provider === 'anthropic' ? ` (${config.ai.model})` : ''}`);
    log.banner(`  cors allowlist   ${config.corsOrigins.length ? config.corsOrigins.join(', ') : '(none — browsers will be refused)'}`);
    log.banner('');
  });

  let closing = false;
  const shutdown = async (signal) => {
    if (closing) return;
    closing = true;
    log.banner(`\n  ${signal} received, shutting down`);
    stopAutoRevealTimer();
    // Give in-flight requests a moment, then stop regardless.
    const force = setTimeout(() => {
      log.banner('  forced exit after 10s');
      process.exit(1);
    }, 10_000);
    force.unref();
    try {
      await new Promise((resolve) => server.close(resolve));
      await closeHub();
      await closePool();
    } catch (err) {
      log.error('shutdown error', { message: err.message });
    }
    clearTimeout(force);
    log.banner('  bye');
    process.exit(0);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  // A rejected promise must never take the class offline mid-game.
  process.on('unhandledRejection', (reason) => {
    log.error('unhandled rejection', { message: reason?.message || String(reason) });
  });
  process.on('uncaughtException', (err) => {
    log.error('uncaught exception', { message: err.message, stack: err.stack });
  });
}

main().catch((err) => {
  console.error(`\nquizzle backend failed to start: ${err.message}\n`);
  process.exit(1);
});

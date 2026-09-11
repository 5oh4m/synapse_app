// Single pg connection pool for the process, plus a transaction helper.
// Replaces the old debounced `data.json` write path entirely.
import pg from 'pg';
import { config } from '../config.js';
import { log } from '../log.js';

// `int8` (count(*), sum(...)) arrives as a string by default because it can
// exceed 2^53. Every count in this app is small, and the client expects
// numbers, so coerce.
pg.types.setTypeParser(pg.types.builtins.INT8, (v) => (v === null ? null : Number(v)));
pg.types.setTypeParser(pg.types.builtins.NUMERIC, (v) => (v === null ? null : Number(v)));

export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  max: Number(process.env.PG_POOL_MAX || 10),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
  application_name: 'quizzle-backend',
});

pool.on('error', (err) => {
  // An idle client died (db restart, network). The pool recovers; just say so.
  log.error('postgres idle client error', { message: err.message });
});

export const query = (text, params) => pool.query(text, params);

/** Run `fn` inside BEGIN/COMMIT, rolling back on any throw. */
export async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* connection already gone */
    }
    throw err;
  } finally {
    client.release();
  }
}

/** First row or null. */
export async function one(text, params) {
  const { rows } = await pool.query(text, params);
  return rows[0] ?? null;
}

export async function many(text, params) {
  const { rows } = await pool.query(text, params);
  return rows;
}

export async function closePool() {
  await pool.end();
}

/** Postgres unique-violation SQLSTATE. */
export const UNIQUE_VIOLATION = '23505';

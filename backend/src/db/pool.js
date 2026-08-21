import pg from 'pg';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';

// Return numerics as numbers, not strings. Money is int cents, so this is safe.
pg.types.setTypeParser(pg.types.builtins.NUMERIC, (v) => (v === null ? null : Number(v)));

export const pool = new pg.Pool({
  connectionString: config.db.url,
  max: config.db.max,
  idleTimeoutMillis: config.db.idleTimeoutMillis,
  application_name: 'sparkle-api',
});

pool.on('error', (err) => logger.error({ err }, 'idle pg client error'));

export async function query(text, params) {
  const started = Date.now();
  const res = await pool.query(text, params);
  const ms = Date.now() - started;
  if (ms > 200) logger.warn({ ms, text: text.slice(0, 120) }, 'slow query');
  return res;
}

/** Runs fn inside a transaction, passing a client. Rolls back on any throw. */
export async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

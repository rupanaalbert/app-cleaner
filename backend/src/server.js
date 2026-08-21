import { createApp } from './app.js';
import { config } from './config/index.js';
import { pool } from './db/pool.js';
import { logger } from './utils/logger.js';

const server = createApp().listen(config.port, () =>
  logger.info({ port: config.port, env: config.env }, 'sparkle api listening'));

// Drain in-flight requests before the container dies, or you will capture
// payments twice when a deploy lands mid-request.
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logger.info({ signal }, 'shutting down');
    server.close(async () => { await pool.end(); process.exit(0); });
    setTimeout(() => process.exit(1), 15_000).unref();
  });
}

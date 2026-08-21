import { query } from '../db/pool.js';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';
import { metrics } from './metrics.js';

/**
 * "Past two dispatch rounds" — a booking still `pending_match` for longer than
 * two offer windows has burned through the first two broadcasts and needs a
 * human (or a supply push) looked at. The sweep sets the gauge for scraping and
 * logs an error-level alert line ops alerting can fire on directly. Runs on the
 * worker; harmless to run more than once.
 */
export async function sweepStuckPendingMatch() {
  const thresholdSeconds = config.matching.offerTtlSeconds * 2;
  const { rows: [{ count }] } = await query(
    `SELECT COUNT(*)::int AS count FROM bookings
      WHERE status = 'pending_match'
        AND created_at < now() - ($1 || ' seconds')::interval`,
    [String(thresholdSeconds)],
  );

  metrics.stuckPendingMatch.set(count);
  if (count > 0) {
    logger.error({ count, thresholdSeconds },
      'ALERT: bookings stuck in pending_match past two dispatch rounds');
  }
  return count;
}

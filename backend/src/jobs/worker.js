import http from 'node:http';
import { Worker } from 'bullmq';
import { connection, webhookQueue, paymentQueue } from './queues.js';
import { query } from '../db/pool.js';
import { config } from '../config/index.js';
import { MatchingService } from '../services/matching.service.js';
import { RealtimeService } from '../services/realtime.service.js';
import { WebhookService } from '../services/webhook.service.js';
import { PaymentService } from '../services/payment.service.js';
import { registry, CONTENT_TYPE } from '../observability/metrics.js';
import { sweepStuckPendingMatch } from '../observability/alerts.js';
import { logger } from '../utils/logger.js';

const { bayesian, minTrailingRating, reviewFloorWindow } = config.matching;

new Worker('matching', async (job) => {
  if (job.name === 'dispatch') {
    return MatchingService.dispatch(job.data.bookingId, job.data.round ?? 1);
  }
}, { connection, concurrency: 10 });

/**
 * Rating recompute — this is what makes reviews affect visibility.
 * The Bayesian prior keeps a single 5-star review from outranking 200 jobs
 * at 4.85; the trailing-20 average is what actually gates dispatch, because
 * a cleaner's recent work predicts the next job better than their lifetime.
 */
new Worker('ratings', async (job) => {
  const { cleanerId } = job.data;
  await query(
    `WITH r AS (
       SELECT rating FROM reviews
        WHERE subject_id = $1 AND author_type = 'customer' AND is_hidden = false
     ), recent AS (
       SELECT rating FROM reviews
        WHERE subject_id = $1 AND author_type = 'customer' AND is_hidden = false
        ORDER BY created_at DESC LIMIT $4
     ), jobs AS (
       SELECT
         COUNT(*) FILTER (WHERE status IN ('completed','settled'))                     AS done,
         COUNT(*) FILTER (WHERE canceled_by = 'cleaner'
                          AND canceled_at > now() - interval '60 days')                AS late_cancels,
         COUNT(*)                                                                      AS total
       FROM bookings WHERE cleaner_id = $1
     ), offers AS (
       SELECT COUNT(*) FILTER (WHERE status = 'accepted')::numeric
              / NULLIF(COUNT(*) FILTER (WHERE status IN ('accepted','expired','declined')), 0) AS rate
         FROM booking_offers WHERE cleaner_id = $1 AND created_at > now() - interval '30 days'
     )
     INSERT INTO cleaner_rating_snapshot (
       cleaner_id, review_count, avg_rating, bayesian_rating, rating_last_20,
       completion_rate, acceptance_rate, late_cancels_60d, jobs_completed, is_dispatchable, updated_at)
     SELECT $1,
            (SELECT COUNT(*) FROM r),
            (SELECT AVG(rating) FROM r),
            (SELECT (COALESCE(SUM(rating),0) + $2 * $3) / (COUNT(*) + $3) FROM r),
            (SELECT AVG(rating) FROM recent),
            (SELECT done::numeric / NULLIF(total,0) FROM jobs),
            COALESCE((SELECT rate FROM offers), 1),
            (SELECT late_cancels FROM jobs),
            (SELECT done FROM jobs),
            COALESCE((SELECT AVG(rating) FROM recent), 5) >= $5,
            now()
     ON CONFLICT (cleaner_id) DO UPDATE SET
       review_count = EXCLUDED.review_count, avg_rating = EXCLUDED.avg_rating,
       bayesian_rating = EXCLUDED.bayesian_rating, rating_last_20 = EXCLUDED.rating_last_20,
       completion_rate = EXCLUDED.completion_rate, acceptance_rate = EXCLUDED.acceptance_rate,
       late_cancels_60d = EXCLUDED.late_cancels_60d, jobs_completed = EXCLUDED.jobs_completed,
       is_dispatchable = EXCLUDED.is_dispatchable, updated_at = now()`,
    [cleanerId, bayesian.priorRating, bayesian.priorWeight, reviewFloorWindow, minTrailingRating],
  );
  logger.info({ cleanerId }, 'rating snapshot rebuilt');
}, { connection, concurrency: 5 });

/** Retention sweeps. Deleting data on schedule is a compliance control, not housekeeping. */
new Worker('privacy', async (job) => {
  if (job.name === 'retention_sweep') {
    await query(`DELETE FROM location_breadcrumbs WHERE recorded_at < now() - ($1 || ' days')::interval`,
      [config.privacy.breadcrumbRetentionDays]);
    await query('DELETE FROM job_photos WHERE purge_after < current_date');
    await query(`DELETE FROM idempotency_keys WHERE created_at < now() - interval '24 hours'`);
  }
  if (job.name === 'close_channel') {
    await RealtimeService.revokeAccess(job.data.bookingId);
  }
  if (job.name === 'erasure') {
    // Crypto-shred PII, keep the tombstone and the financial rows (legal retention).
    await query(
      `UPDATE users SET email=NULL, phone_e164=NULL, full_name='Deleted user',
              password_hash=NULL, avatar_key=NULL, status='deleted', deleted_at=now()
        WHERE id=$1`, [job.data.userId]);
    await query(`UPDATE addresses SET line1='[erased]', line2=NULL, access_notes=NULL,
                 deleted_at=now() WHERE user_id=$1`, [job.data.userId]);
  }
}, { connection, concurrency: 2 });

/**
 * Webhook replay. Retries PayPal events whose handler threw on delivery, with
 * the backoff and poison-pill threshold enforced in the database. concurrency 1
 * because a single sweep already batches, and two would just contend for the
 * same SKIP LOCKED rows.
 */
new Worker('webhooks', async (job) => {
  if (job.name === 'replay_failed') return WebhookService.replayPaypal();
}, { connection, concurrency: 1 });

// Drive the sweep on a fixed cadence. A stable jobId keeps this to one
// repeatable no matter how many times the worker restarts.
await webhookQueue.add('replay_failed', {}, {
  repeat: { every: config.webhooks.replayIntervalSeconds * 1000 },
  jobId: 'paypal-webhook-replay',
});

/**
 * Payout disbursement. Sends every completed booking's payout once its hold
 * window has passed — see payment.service.js's class comment for why this
 * exists (PayPal has no reverse_transfer, so this window is what gives a
 * refund a normal chance to land before the cleaner is ever paid).
 * concurrency 1 for the same SKIP LOCKED reason as webhook replay would apply
 * if this ever needs it — the sweep already batches per run.
 */
new Worker('payments', async (job) => {
  if (job.name === 'disburse_pending') return PaymentService.disbursePendingPayouts();
}, { connection, concurrency: 1 });

await paymentQueue.add('disburse_pending', {}, {
  repeat: { every: 15 * 60_000 }, // every 15 minutes — fine-grained enough that the hold window is the real gate
  jobId: 'payout-disbursement-sweep',
});

// The worker records its own metrics (dispatch rounds, webhook replay lag, the
// stuck-booking gauge); expose them on a separate port for Prometheus.
http.createServer((req, res) => {
  if (req.url !== '/metrics') { res.statusCode = 404; return res.end(); }
  const { token } = config.observability;
  if (token && req.headers.authorization !== `Bearer ${token}`) { res.statusCode = 401; return res.end(); }
  res.setHeader('content-type', CONTENT_TYPE);
  return res.end(registry.render());
}).listen(config.observability.workerMetricsPort, () =>
  logger.info({ port: config.observability.workerMetricsPort }, 'worker metrics on /metrics'));

// Stuck-booking alert: sweep every minute, set the gauge, log loudly when any
// booking has sat in pending_match past two dispatch rounds.
const stuckSweep = () =>
  sweepStuckPendingMatch().catch((err) => logger.error({ err }, 'stuck-pending-match sweep failed'));
stuckSweep();
setInterval(stuckSweep, 60_000);

logger.info('workers online');

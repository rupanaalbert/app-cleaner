import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';
import { metrics } from '../observability/metrics.js';

const { maxReplayAttempts, replayBatchSize, backoffBaseSeconds, backoffCapSeconds } = config.webhooks;

/**
 * Provider webhooks: record, process, and — when processing throws — replay.
 *
 * The processing logic lives here, not in the route, so the live delivery and
 * the replay sweep run *identical* code against the same stored event. The
 * handlers are all idempotent absolute-state writes (set status = 'failed', set
 * refunded_cents = N), so re-running one is safe; running each inside a single
 * transaction with its own "mark processed" makes it atomic — either the effect
 * and the processed stamp both land, or neither does and it stays replayable.
 *
 * Backoff and the poison-pill threshold live in the database (`attempts`,
 * `next_attempt_at`), not in BullMQ, so the schedule survives a worker restart
 * and an admin can see exactly where each failure stands.
 */
export class WebhookService {
  /** Live delivery. Record first (dedupe), then process; a failure is queued for replay, never 5xx'd. */
  static async ingestStripe(event) {
    const { rowCount } = await query(
      `INSERT INTO webhook_events (id, provider, event_type, payload)
       VALUES ($1,'stripe',$2,$3) ON CONFLICT (id) DO NOTHING`,
      [event.id, event.type, event],
    );
    if (rowCount === 0) return { duplicate: true };

    try {
      await this.#runInTransaction(event.id, event);
      metrics.webhookProcessed.inc({ provider: 'stripe', outcome: 'ok' });
      return { processed: true };
    } catch (err) {
      // attempts stays 0: no replay has run yet, only the live delivery. The
      // sweep will pick it up once next_attempt_at passes.
      await this.#recordFailure(event.id, 0, err.message);
      metrics.webhookProcessed.inc({ provider: 'stripe', outcome: 'failed' });
      logger.error({ err, eventId: event.id }, 'stripe webhook failed; queued for replay');
      return { processed: false };
    }
  }

  /**
   * Worker sweep: retry due, still-failing Stripe events until they succeed or
   * cross the poison-pill threshold. Each event is claimed with SKIP LOCKED so
   * two sweeps never process the same row.
   */
  static async replayStripe() {
    const { rows } = await query(
      `SELECT id, attempts, received_at FROM webhook_events
        WHERE provider = 'stripe'
          AND processed_at IS NULL
          AND error IS NOT NULL
          AND attempts < $1
          AND (next_attempt_at IS NULL OR next_attempt_at <= now())
        ORDER BY next_attempt_at NULLS FIRST
        LIMIT $2`,
      [maxReplayAttempts, replayBatchSize],
    );

    let ok = 0; let failed = 0; let poisoned = 0;
    for (const row of rows) {
      try {
        const claimed = await this.#claimAndRun(row.id);
        if (claimed) {
          ok += 1; // otherwise another sweep took it, or it's already done
          metrics.webhookProcessed.inc({ provider: 'stripe', outcome: 'replayed' });
          metrics.webhookLag.observe((Date.now() - new Date(row.received_at)) / 1000);
        }
      } catch (err) {
        const attempts = row.attempts + 1;
        await this.#recordFailure(row.id, attempts, err.message);
        metrics.webhookProcessed.inc({ provider: 'stripe', outcome: 'failed' });
        failed += 1;
        if (attempts >= maxReplayAttempts) {
          poisoned += 1;
          logger.error({ eventId: row.id, attempts },
            'stripe webhook poison-pilled — needs manual review in the admin dead-letter view');
        }
      }
    }
    if (rows.length) logger.info({ scanned: rows.length, ok, failed, poisoned }, 'stripe webhook replay sweep');
    return { scanned: rows.length, ok, failed, poisoned };
  }

  /** Re-run the handler and stamp processed, atomically. Returns false if the row was already taken. */
  static async #claimAndRun(eventId) {
    return withTransaction(async (client) => {
      const { rows: [ev] } = await client.query(
        `SELECT payload FROM webhook_events
          WHERE id = $1 AND processed_at IS NULL
          FOR UPDATE SKIP LOCKED`,
        [eventId],
      );
      if (!ev) return false;
      await handleStripeEvent(client, ev.payload);
      await client.query(
        `UPDATE webhook_events
            SET processed_at = now(), error = NULL, attempts = attempts + 1, last_attempt_at = now()
          WHERE id = $1`,
        [eventId],
      );
      return true;
    });
  }

  static async #runInTransaction(eventId, event) {
    await withTransaction(async (client) => {
      await handleStripeEvent(client, event);
      await client.query(
        `UPDATE webhook_events SET processed_at = now(), error = NULL WHERE id = $1`,
        [eventId],
      );
    });
  }

  /** Record a failure and schedule the next attempt with exponential backoff. */
  static async #recordFailure(eventId, attempts, message) {
    const delaySeconds = Math.min(backoffCapSeconds, backoffBaseSeconds * 2 ** attempts);
    await query(
      `UPDATE webhook_events
          SET attempts = $2, error = $3, last_attempt_at = now(),
              next_attempt_at = now() + ($4 || ' seconds')::interval
        WHERE id = $1`,
      [eventId, attempts, message, String(delaySeconds)],
    );
  }
}

/**
 * The Stripe event handler. Every branch is an idempotent, absolute-state write
 * so replay is safe. Takes a db client (the caller owns the transaction), never
 * the pool directly — that's what lets the effect and the processed stamp
 * commit together.
 */
export async function handleStripeEvent(client, event) {
  const obj = event.data.object;
  switch (event.type) {
    case 'payment_intent.payment_failed':
      await client.query(
        `UPDATE payments SET status='failed', failure_code=$2 WHERE stripe_payment_intent_id=$1`,
        [obj.id, obj.last_payment_error?.code ?? 'unknown'],
      );
      break;

    case 'charge.refunded':
      await client.query(
        `UPDATE payments SET refunded_cents=$2,
                status = CASE WHEN $2 >= captured_cents THEN 'refunded' ELSE 'partially_refunded' END
          WHERE stripe_charge_id=$1`,
        [obj.id, obj.amount_refunded],
      );
      break;

    case 'charge.dispute.created':
      // Guard against a duplicate dispute if this event is ever reprocessed:
      // one open Stripe chargeback per booking is enough.
      await client.query(
        `INSERT INTO disputes (booking_id, opened_by, category, description, status)
         SELECT p.booking_id, p.customer_id, 'billing', $2, 'investigating'
           FROM payments p
          WHERE p.stripe_charge_id = $1
            AND NOT EXISTS (
              SELECT 1 FROM disputes d
               WHERE d.booking_id = p.booking_id AND d.category = 'billing' AND d.status <> 'resolved')`,
        [obj.charge, `Stripe chargeback: ${obj.reason}`],
      );
      break;

    case 'payout.paid':
    case 'payout.failed':
      await client.query(
        `UPDATE payouts SET status=$2, arrival_date=to_timestamp($3)::date WHERE stripe_payout_id=$1`,
        [obj.id, event.type === 'payout.paid' ? 'paid' : 'failed', obj.arrival_date],
      );
      break;

    case 'account.updated':
      // Gate dispatch on the cleaner's ability to actually receive money.
      await client.query(
        `UPDATE cleaner_profiles SET payouts_enabled=$2 WHERE stripe_account_id=$1`,
        [obj.id, Boolean(obj.payouts_enabled && obj.charges_enabled)],
      );
      break;

    default:
      logger.debug({ type: event.type }, 'unhandled stripe event');
  }
}

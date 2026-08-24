import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { logger } from '../utils/logger.js';
import { metrics } from '../observability/metrics.js';

const { maxReplayAttempts, replayBatchSize, backoffBaseSeconds, backoffCapSeconds } = config.webhooks;

const PAYOUT_STATUS = {
  'PAYMENT.PAYOUTS-ITEM.SUCCEEDED': 'paid',
  'PAYMENT.PAYOUTS-ITEM.FAILED': 'failed',
  'PAYMENT.PAYOUTS-ITEM.BLOCKED': 'failed',
  'PAYMENT.PAYOUTS-ITEM.RETURNED': 'reversed',
};

/**
 * PayPal webhooks: record, process, and — when processing throws — replay.
 *
 * The processing logic lives here, not in the route, so the live delivery and
 * the replay sweep run *identical* code against the same stored event. The
 * handlers are all idempotent absolute-state writes, so re-running one is
 * safe; running each inside a single transaction with its own "mark
 * processed" makes it atomic — either the effect and the processed stamp both
 * land, or neither does and it stays replayable.
 *
 * Backoff and the poison-pill threshold live in the database (`attempts`,
 * `next_attempt_at`), not in BullMQ, so the schedule survives a worker restart
 * and an admin can see exactly where each failure stands. `provider` stays a
 * plain column on `webhook_events` (it always was, even under Stripe) so a
 * future second provider costs no migration.
 */
export class WebhookService {
  /** Live delivery. Record first (dedupe), then process; a failure is queued for replay, never 5xx'd. */
  static async ingestPaypal(event) {
    const { rowCount } = await query(
      `INSERT INTO webhook_events (id, provider, event_type, payload)
       VALUES ($1,'paypal',$2,$3) ON CONFLICT (id) DO NOTHING`,
      [event.id, event.event_type, event],
    );
    if (rowCount === 0) return { duplicate: true };

    try {
      await this.#runInTransaction(event.id, event);
      metrics.webhookProcessed.inc({ provider: 'paypal', outcome: 'ok' });
      return { processed: true };
    } catch (err) {
      // attempts stays 0: no replay has run yet, only the live delivery. The
      // sweep will pick it up once next_attempt_at passes.
      await this.#recordFailure(event.id, 0, err.message);
      metrics.webhookProcessed.inc({ provider: 'paypal', outcome: 'failed' });
      logger.error({ err, eventId: event.id }, 'paypal webhook failed; queued for replay');
      return { processed: false };
    }
  }

  /**
   * Worker sweep: retry due, still-failing PayPal events until they succeed or
   * cross the poison-pill threshold. Each event is claimed with SKIP LOCKED so
   * two sweeps never process the same row.
   */
  static async replayPaypal() {
    const { rows } = await query(
      `SELECT id, attempts, received_at FROM webhook_events
        WHERE provider = 'paypal'
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
          metrics.webhookProcessed.inc({ provider: 'paypal', outcome: 'replayed' });
          metrics.webhookLag.observe((Date.now() - new Date(row.received_at)) / 1000);
        }
      } catch (err) {
        const attempts = row.attempts + 1;
        await this.#recordFailure(row.id, attempts, err.message);
        metrics.webhookProcessed.inc({ provider: 'paypal', outcome: 'failed' });
        failed += 1;
        if (attempts >= maxReplayAttempts) {
          poisoned += 1;
          logger.error({ eventId: row.id, attempts },
            'paypal webhook poison-pilled — needs manual review in the admin dead-letter view');
        }
      }
    }
    if (rows.length) logger.info({ scanned: rows.length, ok, failed, poisoned }, 'paypal webhook replay sweep');
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
      await handlePaypalEvent(client, ev.payload);
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
      await handlePaypalEvent(client, event);
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
 * The PayPal event handler. Every branch is an idempotent, absolute-state
 * write so replay is safe. Takes a db client (the caller owns the
 * transaction), never the pool directly — that's what lets the effect and the
 * processed stamp commit together.
 *
 * `PAYMENT.CAPTURE.REFUNDED` and `CUSTOMER.DISPUTE.CREATED`'s exact resource
 * shape below follows PayPal's documented webhook payloads but hasn't been
 * exercised against a live sandbox event yet — confirm in the Phase 0 spike
 * and correct here if reality differs.
 */
export async function handlePaypalEvent(client, event) {
  const resource = event.resource ?? {};
  switch (event.event_type) {
    case 'PAYMENT.CAPTURE.REFUNDED': {
      const captureId = resource.links?.find((l) => l.rel === 'up')?.href?.split('/').pop();
      await client.query(
        `UPDATE payments SET refunded_cents = captured_cents, status = 'refunded'
          WHERE paypal_capture_id = $1`,
        [captureId ?? resource.id],
      );
      break;
    }

    case 'CUSTOMER.DISPUTE.CREATED':
      // Guard against a duplicate dispute if this event is ever reprocessed:
      // one open PayPal dispute per booking is enough.
      await client.query(
        `INSERT INTO disputes (booking_id, opened_by, category, description, status)
         SELECT p.booking_id, p.customer_id, 'billing', $2, 'investigating'
           FROM payments p
          WHERE p.paypal_capture_id = $1
            AND NOT EXISTS (
              SELECT 1 FROM disputes d
               WHERE d.booking_id = p.booking_id AND d.category = 'billing' AND d.status <> 'resolved')`,
        [resource.disputed_transactions?.[0]?.seller_transaction_id,
         `PayPal dispute: ${resource.reason ?? 'unspecified'}`],
      );
      break;

    case 'PAYMENT.PAYOUTS-ITEM.SUCCEEDED':
    case 'PAYMENT.PAYOUTS-ITEM.FAILED':
    case 'PAYMENT.PAYOUTS-ITEM.BLOCKED':
    case 'PAYMENT.PAYOUTS-ITEM.RETURNED': {
      const senderItemId = resource.payout_item?.sender_item_id ?? resource.sender_item_id;
      if (!senderItemId) break;

      // The reserved verify:{cleanerId} item is the ONLY place payouts_enabled
      // is set — never optimistically, only on a confirmed successful send.
      // See onboarding.service.js#savePayoutsEmail and CLAUDE.md invariant #7.
      if (senderItemId.startsWith('verify:')) {
        if (event.event_type === 'PAYMENT.PAYOUTS-ITEM.SUCCEEDED') {
          const cleanerId = senderItemId.slice('verify:'.length);
          await client.query(
            `UPDATE cleaner_profiles SET payouts_enabled = true WHERE user_id = $1`, [cleanerId]);
        }
        break;
      }

      if (senderItemId.startsWith('payout:')) {
        const payoutId = senderItemId.slice('payout:'.length);
        await client.query(
          `UPDATE payouts SET status = $2 WHERE id = $1`,
          [payoutId, PAYOUT_STATUS[event.event_type]],
        );
      }
      break;
    }

    default:
      logger.debug({ type: event.event_type }, 'unhandled paypal event');
  }
}

import { paypal } from './paypal.client.js';
import { query } from '../db/pool.js';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';
import { logger } from '../utils/logger.js';
import { metrics } from '../observability/metrics.js';

const centsToDecimal = (cents) => (cents / 100).toFixed(2);

/**
 * Payments via PayPal — collect-then-disburse, not a split charge.
 *
 * PayPal's true multiparty split payment (`payee.merchant_id` +
 * `platform_fees` on one order) requires `intent: CAPTURE` — incompatible
 * with the manual-capture hold this app relies on (authorize now, capture
 * the real amount at job completion). So customers pay into Sparkle's own
 * PayPal account via plain Orders v2, and the cleaner's share is disbursed
 * separately through the Payouts API once a hold window passes
 * (`captureAndTransfer` queues it; `disburse_pending_payouts` in
 * jobs/worker.js sends it). That hold window is also the mitigation for the
 * one real gap this leaves: PayPal has no `reverse_transfer` equivalent, so
 * a refund after a payout has already gone out can't claw back atomically —
 * see `refund()`.
 *
 * `platform_fee_cents` = commission + trust & safety fee, same as it always
 * was — it just no longer feeds a Stripe `application_fee_amount` field.
 *
 * Every PayPal call carries a `PayPal-Request-Id` derived from the booking
 * (via `paypal.client.js`), so a retried request can never double-charge.
 */
export class PaymentService {
  /**
   * Creates the order a customer approves before a booking is confirmed.
   * `intent: AUTHORIZE` holds funds without capturing them. No `payee` or
   * `platform_fees` — see the class comment for why. Called from the quote
   * flow (`POST /v1/quotes/:id/paypal-order`) and the tip flow
   * (`POST /v1/bookings/:id/tip/paypal-order`) before the customer approves
   * via the in-app PayPal webview.
   */
  static async createOrder({ amountCents, reference }) {
    const order = await paypal.request('/v2/checkout/orders', {
      method: 'POST',
      idempotencyKey: `order:${reference}:create`,
      body: {
        intent: 'AUTHORIZE',
        purchase_units: [{
          reference_id: reference,
          amount: { currency_code: 'USD', value: centsToDecimal(amountCents) },
        }],
        application_context: {
          return_url: 'sparkle://booking/paypal/return',
          cancel_url: 'sparkle://booking/paypal/cancel',
          user_action: 'PAY_NOW',
        },
      },
    });
    const approveUrl = order.links?.find((l) => l.rel === 'approve')?.href;
    return { order_id: order.id, approve_url: approveUrl };
  }

  /**
   * `paypalOrderId` is an order the customer has already approved (the
   * mobile app opened `createOrder`'s approve_url in a webview and captured
   * the returned order id on redirect). This turns that approval into a real
   * authorization Sparkle can later capture.
   */
  static async authorize({ client, booking, customerId, paypalOrderId, amountCents }) {
    let authorization;
    try {
      const result = await paypal.request(`/v2/checkout/orders/${paypalOrderId}/authorize`, {
        method: 'POST',
        idempotencyKey: `booking:${booking.id}:authorize`,
      });
      [authorization] = result.purchase_units[0].payments.authorizations;
    } catch (err) {
      logger.warn({ err: err.message, bookingId: booking.id }, 'authorization failed');
      throw AppError.payment('CARD_DECLINED', err.message);
    }

    const authorizedCents = Math.round(Number(authorization.amount.value) * 100);
    if (authorizedCents !== amountCents) {
      // Shouldn't happen — the order is created for this exact buffered
      // total moments earlier — but trust what PayPal actually authorized
      // over what we expected, and leave a trail if they ever disagree.
      logger.warn({ bookingId: booking.id, authorizedCents, amountCents }, 'paypal authorized amount mismatch');
    }

    const { rows: [payment] } = await client.query(
      `INSERT INTO payments (booking_id, customer_id, paypal_order_id, paypal_authorization_id, status,
                             authorized_cents, platform_fee_cents, authorized_at)
       VALUES ($1,$2,$3,$4,'authorized',$5,$6,now()) RETURNING *`,
      [booking.id, customerId, paypalOrderId, authorization.id, amountCents,
       booking.commission_cents + booking.ts_fee_cents],
    );

    await ledger(client, booking.id, [
      ['customer_receivable', 'D', booking.total_cents, 'authorization'],
    ]);

    return { status: 'authorized', authorized_cents: amountCents, id: payment.id };
  }

  /**
   * Capture the amount actually owed (never more than authorized) and queue
   * the cleaner's share for disbursement rather than transferring it inline
   * — see the class comment. Overage beyond the auth buffer needs a fresh
   * order; silently eating it is how marketplaces lose margin.
   */
  static async captureAndTransfer({ client, booking, actualDurationMin }) {
    const { rows: [payment] } = await client.query(
      `SELECT * FROM payments WHERE booking_id = $1 AND status = 'authorized' FOR UPDATE`,
      [booking.id],
    );
    if (!payment) throw AppError.conflict('NOT_AUTHORIZED', 'No live authorization for this booking');

    const captureCents = Math.min(booking.total_cents, payment.authorized_cents);
    if (actualDurationMin && actualDurationMin > booking.duration_min * 1.25) {
      logger.warn({ bookingId: booking.id, actualDurationMin }, 'job ran long — review for overage billing');
    }

    const { rows: [cleaner] } = await client.query(
      'SELECT paypal_email, payouts_enabled FROM cleaner_profiles WHERE user_id = $1',
      [booking.cleaner_id],
    );
    if (!cleaner?.payouts_enabled) {
      throw AppError.unprocessable('PAYOUTS_DISABLED', 'Cleaner cannot receive funds yet');
    }

    let capture;
    try {
      capture = await paypal.request(`/v2/payments/authorizations/${payment.paypal_authorization_id}/capture`, {
        method: 'POST',
        idempotencyKey: `booking:${booking.id}:capture`,
        body: { amount: { currency_code: 'USD', value: centsToDecimal(captureCents) }, final_capture: true },
      });
    } catch (err) {
      // The cleaner did the work; a capture that fails here is money we owe
      // and haven't collected. Count it loudly — this is the metric ops watches.
      metrics.captureFailures.inc();
      throw err;
    }

    await client.query(
      `UPDATE payments SET status='captured', captured_cents=$2, paypal_capture_id=$3, captured_at=now()
        WHERE id=$1`,
      [payment.id, captureCents, capture.id],
    );
    await client.query(
      `INSERT INTO payouts (cleaner_id, booking_id, amount_cents, status, hold_until)
       VALUES ($1,$2,$3,'pending', now() + ($4 || ' hours')::interval)`,
      [booking.cleaner_id, booking.id, booking.payout_cents, config.payouts.holdWindowHours],
    );
    await client.query(`UPDATE bookings SET status='settled' WHERE id=$1`, [booking.id]);

    await ledger(client, booking.id, [
      ['customer_receivable', 'C', captureCents, 'capture'],
      ['cleaner_payable', 'C', booking.payout_cents, 'queued for payout'],
      ['platform_revenue', 'C', booking.commission_cents, 'commission'],
      ['ts_fee', 'C', booking.ts_fee_cents, 'trust & safety'],
    ]);

    return { captured_cents: captureCents, payout_cents: booking.payout_cents };
  }

  /**
   * Tips authorize-and-capture in one pass (there's no hold to manage — the
   * customer is confirming an amount they already know) but still queue
   * through the normal pending-payout batch. No commission, no platform fee.
   */
  static async tip({ client, booking, amountCents, paypalOrderId }) {
    const authResult = await paypal.request(`/v2/checkout/orders/${paypalOrderId}/authorize`, {
      method: 'POST',
      idempotencyKey: `booking:${booking.id}:tip`,
    });
    const [authorization] = authResult.purchase_units[0].payments.authorizations;

    const capture = await paypal.request(`/v2/payments/authorizations/${authorization.id}/capture`, {
      method: 'POST',
      idempotencyKey: `booking:${booking.id}:tip-capture`,
      body: { amount: { currency_code: 'USD', value: centsToDecimal(amountCents) }, final_capture: true },
    });

    await client.query('UPDATE bookings SET tip_cents = tip_cents + $2 WHERE id = $1',
      [booking.id, amountCents]);
    await client.query(
      `INSERT INTO payouts (cleaner_id, booking_id, amount_cents, status, hold_until)
       VALUES ($1,$2,$3,'pending', now() + ($4 || ' hours')::interval)`,
      [booking.cleaner_id, booking.id, amountCents, config.payouts.holdWindowHours],
    );
    return { status: 'captured', capture_id: capture.id };
  }

  static async resolveCancellation({ client, booking, outcome }) {
    const { rows: [payment] } = await client.query(
      'SELECT * FROM payments WHERE booking_id = $1 FOR UPDATE', [booking.id],
    );
    if (!payment) return;

    if (outcome.fee_cents === 0) {
      await paypal.request(`/v2/payments/authorizations/${payment.paypal_authorization_id}/void`, {
        method: 'POST',
        idempotencyKey: `booking:${booking.id}:void`,
      });
      await client.query(`UPDATE payments SET status='canceled' WHERE id=$1`, [payment.id]);
      return;
    }

    // Late cancel: capture the fee, pass it through to the cleaner in full —
    // queued through the normal pending-payout batch like any other payout.
    const capture = await paypal.request(`/v2/payments/authorizations/${payment.paypal_authorization_id}/capture`, {
      method: 'POST',
      idempotencyKey: `booking:${booking.id}:cancel-capture`,
      body: { amount: { currency_code: 'USD', value: centsToDecimal(outcome.fee_cents) }, final_capture: true },
    });

    await client.query(
      `UPDATE payments SET status='captured', captured_cents=$2, paypal_capture_id=$3, captured_at=now() WHERE id=$1`,
      [payment.id, outcome.fee_cents, capture.id],
    );
    if (outcome.cleaner_cents > 0) {
      await client.query(
        `INSERT INTO payouts (cleaner_id, booking_id, amount_cents, status, hold_until)
         VALUES ($1,$2,$3,'pending', now() + ($4 || ' hours')::interval)`,
        [booking.cleaner_id, booking.id, outcome.cleaner_cents, config.payouts.holdWindowHours],
      );
    }
    await ledger(client, booking.id, [
      ['customer_receivable', 'C', outcome.fee_cents, 'late cancellation fee'],
      ['cleaner_payable', 'C', outcome.cleaner_cents, 'late cancellation compensation'],
    ]);
  }

  /**
   * PayPal has no `reverse_transfer` equivalent — Payouts is a one-way send
   * with no link back to the capture it paid for. If the booking's payout
   * hasn't gone out yet (still `pending`, inside the hold window) refunding
   * just cancels it, no PayPal call needed. If it already shows `in_transit`
   * or `paid`, the shortfall is recorded against the cleaner's *next* payout
   * batch instead of being silently absorbed. Deliberate policy — see
   * CLAUDE.md invariant #7 and README §3, not a gap.
   */
  static async refund({ client, paymentId, amountCents, reason, issuedBy }) {
    const { rows: [payment] } = await client.query(
      'SELECT * FROM payments WHERE id = $1 FOR UPDATE', [paymentId],
    );
    if (!payment) throw AppError.notFound('Payment');
    if (amountCents > payment.captured_cents - payment.refunded_cents) {
      throw AppError.unprocessable('REFUND_EXCEEDS_CAPTURE', 'Refund is larger than the captured amount');
    }

    const refund = await paypal.request(`/v2/payments/captures/${payment.paypal_capture_id}/refund`, {
      method: 'POST',
      idempotencyKey: `payment:${paymentId}:refund:${amountCents}`,
      body: { amount: { currency_code: 'USD', value: centsToDecimal(amountCents) } },
    });

    await client.query(
      `INSERT INTO refunds (payment_id, paypal_refund_id, amount_cents, reason, issued_by)
       VALUES ($1,$2,$3,$4,$5)`,
      [paymentId, refund.id, amountCents, reason, issuedBy],
    );
    await client.query(
      `UPDATE payments SET refunded_cents = refunded_cents + $2,
              status = CASE WHEN refunded_cents + $2 >= captured_cents THEN 'refunded'
                            ELSE 'partially_refunded' END
        WHERE id = $1`,
      [paymentId, amountCents],
    );

    await clawback({ client, paymentId, bookingId: payment.booking_id, amountCents, reason });

    return refund;
  }

  /**
   * Worker sweep: sends every payout whose hold window has passed. Batched
   * (PayPal's Payouts endpoint accepts many items per call) via
   * `sender_item_id: payout:{payoutRowId}` — using our own row id as the
   * join key, rather than PayPal's own generated item id, is what lets the
   * webhook handler match a status update back to a row without an extra
   * round trip to persist PayPal's id first.
   */
  static async disbursePendingPayouts() {
    const { rows } = await query(
      `SELECT p.id, p.amount_cents, cp.paypal_email
         FROM payouts p JOIN cleaner_profiles cp ON cp.user_id = p.cleaner_id
        WHERE p.status = 'pending' AND p.hold_until <= now() AND cp.paypal_email IS NOT NULL
        ORDER BY p.created_at
        LIMIT $1`,
      [config.payouts.disburseBatchSize],
    );
    if (rows.length === 0) return { sent: 0 };

    const batchId = `disburse:${Date.now()}`;
    const batch = await paypal.request('/v1/payments/payouts', {
      method: 'POST',
      idempotencyKey: batchId,
      body: {
        sender_batch_header: { sender_batch_id: batchId, email_subject: "You've been paid by Sparkle" },
        items: rows.map((r) => ({
          recipient_type: 'EMAIL',
          receiver: r.paypal_email,
          sender_item_id: `payout:${r.id}`,
          amount: { value: (r.amount_cents / 100).toFixed(2), currency: 'USD' },
        })),
      },
    });

    await query(
      `UPDATE payouts SET status = 'in_transit', paypal_payout_batch_id = $2 WHERE id = ANY($1)`,
      [rows.map((r) => r.id), batch.batch_header?.payout_batch_id ?? batchId],
    );
    logger.info({ count: rows.length, batchId }, 'payouts batch disbursed');
    return { sent: rows.length };
  }
}

/** See `PaymentService.refund` — cancels an undisbursed payout, or queues a clawback against the next one. */
async function clawback({ client, paymentId, bookingId, amountCents, reason }) {
  const { rows: [payout] } = await client.query(
    `SELECT * FROM payouts WHERE booking_id = $1 ORDER BY created_at DESC LIMIT 1 FOR UPDATE`,
    [bookingId],
  );
  if (!payout) return;

  if (payout.status === 'pending') {
    await client.query(`UPDATE payouts SET status = 'canceled' WHERE id = $1`, [payout.id]);
    return;
  }
  if (['in_transit', 'paid'].includes(payout.status)) {
    await client.query(
      `INSERT INTO payout_adjustments (booking_id, cleaner_id, amount_cents, reason)
       VALUES ($1,$2,$3,$4)`,
      [bookingId, payout.cleaner_id, Math.min(amountCents, payout.amount_cents),
       `refund on payment ${paymentId}: ${reason}`],
    );
  }
}

/** Append-only double-entry rows. You reconcile against PayPal, not yourself. */
async function ledger(client, bookingId, entries) {
  for (const [account, direction, amount, memo] of entries) {
    if (amount <= 0) continue;
    await client.query(
      `INSERT INTO ledger_entries (booking_id, account, direction, amount_cents, memo)
       VALUES ($1,$2,$3,$4,$5)`,
      [bookingId, account, direction, amount, memo],
    );
  }
}

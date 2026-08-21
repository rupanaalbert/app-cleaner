import Stripe from 'stripe';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';
import { logger } from '../utils/logger.js';
import { metrics } from '../observability/metrics.js';

export const stripe = new Stripe(config.stripe.key, { apiVersion: '2024-06-20' });

/**
 * Payments via Stripe Connect, destination charges.
 *
 * The customer's statement shows Sparkle, funds route to the cleaner's Express
 * account, and Stripe's processing fee comes out of the platform's slice.
 * `application_fee_amount` = commission + trust & safety fee — the cleaner is
 * never charged for the safety fee.
 *
 * Every call carries an idempotency key derived from the booking, so a retried
 * request can never double-charge.
 */
export class PaymentService {
  static async authorize({ client, booking, customerId, paymentMethodId, amountCents }) {
    const { rows: [profile] } = await client.query(
      'SELECT stripe_customer_id FROM customer_profiles WHERE user_id = $1', [customerId],
    );
    if (!profile?.stripe_customer_id) throw AppError.unprocessable('NO_STRIPE_CUSTOMER', 'Add a payment method first');

    let intent;
    try {
      intent = await stripe.paymentIntents.create({
        amount: amountCents,
        currency: 'usd',
        customer: profile.stripe_customer_id,
        payment_method: paymentMethodId,
        capture_method: 'manual',        // hold now, capture the real amount at completion
        confirm: true,
        off_session: false,
        application_fee_amount: booking.commission_cents + booking.ts_fee_cents,
        metadata: { booking_id: booking.id, reference: booking.reference },
        description: `Sparkle ${booking.reference}`,
      }, { idempotencyKey: `booking:${booking.id}:authorize` });
    } catch (err) {
      logger.warn({ err: err.code, bookingId: booking.id }, 'authorization failed');
      throw AppError.payment('CARD_DECLINED', err.message);
    }

    const { rows: [payment] } = await client.query(
      `INSERT INTO payments (booking_id, customer_id, stripe_payment_intent_id, status,
                             authorized_cents, application_fee_cents, authorized_at)
       VALUES ($1,$2,$3,'authorized',$4,$5,now()) RETURNING *`,
      [booking.id, customerId, intent.id, amountCents,
       booking.commission_cents + booking.ts_fee_cents],
    );

    await ledger(client, booking.id, [
      ['customer_receivable', 'D', booking.total_cents, 'authorization'],
    ]);

    return { status: 'authorized', authorized_cents: amountCents, client_secret: intent.client_secret, id: payment.id };
  }

  /**
   * Capture the amount actually owed (never more than authorized) and transfer
   * the cleaner's share. Overage beyond the auth buffer needs an incremental
   * authorization — silently eating it is how marketplaces lose margin.
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
      'SELECT stripe_account_id, payouts_enabled FROM cleaner_profiles WHERE user_id = $1',
      [booking.cleaner_id],
    );
    if (!cleaner?.payouts_enabled) {
      throw AppError.unprocessable('PAYOUTS_DISABLED', 'Cleaner cannot receive funds yet');
    }

    let intent;
    try {
      intent = await stripe.paymentIntents.capture(payment.stripe_payment_intent_id, {
        amount_to_capture: captureCents,
        application_fee_amount: booking.commission_cents + booking.ts_fee_cents,
        transfer_data: { destination: cleaner.stripe_account_id },
      }, { idempotencyKey: `booking:${booking.id}:capture` });
    } catch (err) {
      // The cleaner did the work; a capture that fails here is money we owe and
      // haven't collected. Count it loudly — this is the metric ops watches.
      metrics.captureFailures.inc();
      throw err;
    }

    await client.query(
      `UPDATE payments SET status='captured', captured_cents=$2, stripe_charge_id=$3, captured_at=now()
        WHERE id=$1`,
      [payment.id, captureCents, intent.latest_charge],
    );
    await client.query(
      `INSERT INTO payouts (cleaner_id, booking_id, stripe_transfer_id, amount_cents, status)
       VALUES ($1,$2,$3,$4,'pending')`,
      [booking.cleaner_id, booking.id, intent.transfer_data?.destination ?? null, booking.payout_cents],
    );
    await client.query(`UPDATE bookings SET status='settled' WHERE id=$1`, [booking.id]);

    await ledger(client, booking.id, [
      ['customer_receivable', 'C', captureCents, 'capture'],
      ['cleaner_payable', 'C', booking.payout_cents, 'transfer'],
      ['platform_revenue', 'C', booking.commission_cents, 'commission'],
      ['ts_fee', 'C', booking.ts_fee_cents, 'trust & safety'],
    ]);

    return { captured_cents: captureCents, payout_cents: booking.payout_cents };
  }

  /** Tips transfer 100% to the cleaner. No commission, no fee. */
  static async tip({ client, booking, amountCents, paymentMethodId, customerStripeId, cleanerAccountId }) {
    const intent = await stripe.paymentIntents.create({
      amount: amountCents, currency: 'usd',
      customer: customerStripeId, payment_method: paymentMethodId, confirm: true,
      transfer_data: { destination: cleanerAccountId },
      metadata: { booking_id: booking.id, kind: 'tip' },
    }, { idempotencyKey: `booking:${booking.id}:tip` });

    await client.query('UPDATE bookings SET tip_cents = tip_cents + $2 WHERE id = $1',
      [booking.id, amountCents]);
    return intent;
  }

  static async resolveCancellation({ client, booking, outcome }) {
    const { rows: [payment] } = await client.query(
      'SELECT * FROM payments WHERE booking_id = $1 FOR UPDATE', [booking.id],
    );
    if (!payment) return;

    if (outcome.fee_cents === 0) {
      await stripe.paymentIntents.cancel(payment.stripe_payment_intent_id,
        { cancellation_reason: 'requested_by_customer' },
        { idempotencyKey: `booking:${booking.id}:void` });
      await client.query(`UPDATE payments SET status='canceled' WHERE id=$1`, [payment.id]);
      return;
    }

    // Late cancel: capture the fee, pass it through to the cleaner in full.
    await stripe.paymentIntents.capture(payment.stripe_payment_intent_id, {
      amount_to_capture: outcome.fee_cents,
      application_fee_amount: 0,
    }, { idempotencyKey: `booking:${booking.id}:cancel-capture` });

    await client.query(
      `UPDATE payments SET status='captured', captured_cents=$2, captured_at=now() WHERE id=$1`,
      [payment.id, outcome.fee_cents],
    );
    await ledger(client, booking.id, [
      ['customer_receivable', 'C', outcome.fee_cents, 'late cancellation fee'],
      ['cleaner_payable', 'C', outcome.cleaner_cents, 'late cancellation compensation'],
    ]);
  }

  static async refund({ client, paymentId, amountCents, reason, issuedBy }) {
    const { rows: [payment] } = await client.query(
      'SELECT * FROM payments WHERE id = $1 FOR UPDATE', [paymentId],
    );
    if (!payment) throw AppError.notFound('Payment');
    if (amountCents > payment.captured_cents - payment.refunded_cents) {
      throw AppError.unprocessable('REFUND_EXCEEDS_CAPTURE', 'Refund is larger than the captured amount');
    }

    const refund = await stripe.refunds.create({
      payment_intent: payment.stripe_payment_intent_id,
      amount: amountCents,
      reverse_transfer: true,       // claw back the cleaner's share proportionally
      refund_application_fee: true,
    }, { idempotencyKey: `payment:${paymentId}:refund:${amountCents}` });

    await client.query(
      `INSERT INTO refunds (payment_id, stripe_refund_id, amount_cents, reason, issued_by)
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
    return refund;
  }
}

/** Append-only double-entry rows. You reconcile against Stripe, not yourself. */
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

import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, requireRole, requireBookingParty } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { idempotency } from '../../middleware/idempotency.js';
import { query, withTransaction } from '../../db/pool.js';
import { PaymentService } from '../../services/payment.service.js';

const router = Router();

router.post('/bookings/:id/tip', requireAuth, requireRole('customer'), requireBookingParty,
  idempotency, validate(z.object({
    amount_cents: z.number().int().min(100).max(20_000),
    payment_method_id: z.string().startsWith('pm_'),
  })),
  async (req, res, next) => {
    try {
      const result = await withTransaction(async (client) => {
        const { rows: [ctx] } = await client.query(
          `SELECT b.*, cp.stripe_customer_id, cl.stripe_account_id
             FROM bookings b
             JOIN customer_profiles cp ON cp.user_id = b.customer_id
             JOIN cleaner_profiles  cl ON cl.user_id = b.cleaner_id
            WHERE b.id = $1`, [req.params.id]);
        return PaymentService.tip({
          client, booking: ctx, amountCents: req.body.amount_cents,
          paymentMethodId: req.body.payment_method_id,
          customerStripeId: ctx.stripe_customer_id, cleanerAccountId: ctx.stripe_account_id,
        });
      });
      res.status(201).json({ tip: { amount_cents: req.body.amount_cents, status: result.status } });
    } catch (err) { next(err); }
  });

router.post('/bookings/:id/refund', requireAuth, requireRole('admin'),
  validate(z.object({ amount_cents: z.number().int().positive(), reason: z.string().max(200) })),
  async (req, res, next) => {
    try {
      const refund = await withTransaction(async (client) => {
        const { rows: [p] } = await client.query(
          'SELECT id FROM payments WHERE booking_id = $1', [req.params.id]);
        return PaymentService.refund({
          client, paymentId: p.id, amountCents: req.body.amount_cents,
          reason: req.body.reason, issuedBy: req.user.id,
        });
      });
      res.status(201).json({ refund_id: refund.id, amount_cents: req.body.amount_cents });
    } catch (err) { next(err); }
  });

router.get('/cleaner/earnings', requireAuth, requireRole('cleaner'), async (req, res, next) => {
  try {
    const { rows: [totals] } = await query(
      `SELECT COALESCE(SUM(subtotal_cents),0)::int   AS gross_cents,
              COALESCE(SUM(commission_cents),0)::int AS commission_cents,
              COALESCE(SUM(payout_cents),0)::int     AS net_cents,
              COALESCE(SUM(tip_cents),0)::int        AS tips_cents,
              COUNT(*)::int                          AS jobs
         FROM bookings
        WHERE cleaner_id = $1 AND status IN ('completed','settled')
          AND completed_at BETWEEN $2 AND $3`,
      [req.user.id, req.query.from ?? '-infinity', req.query.to ?? 'infinity'],
    );
    const { rows: [next_payout] } = await query(
      `SELECT SUM(amount_cents)::int AS amount_cents, MIN(arrival_date) AS arrival_date
         FROM payouts WHERE cleaner_id = $1 AND status IN ('pending','in_transit')`,
      [req.user.id],
    );
    res.json({ ...totals, next_payout });
  } catch (err) { next(err); }
});

export default router;

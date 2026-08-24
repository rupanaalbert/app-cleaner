import { query } from '../../db/pool.js';
import { config } from '../../config/index.js';
import { AppError } from '../../utils/errors.js';
import { PricingService } from '../../services/pricing.service.js';
import { PaymentService } from '../../services/payment.service.js';

export const QuoteController = {
  async create(req, res, next) {
    try {
      const { property_id, service_code, addon_codes, scheduled_at } = req.body;

      const { rows: [property] } = await query(
        `SELECT p.*, a.postal_code, a.location
           FROM properties p JOIN addresses a ON a.id = p.address_id
          WHERE p.id = $1 AND p.customer_id = $2`,
        [property_id, req.user.id],
      );
      if (!property) throw AppError.notFound('Property');

      const { rows: [service] } = await query(
        'SELECT * FROM services WHERE code = $1 AND is_active', [service_code],
      );
      if (!service) throw AppError.notFound('Service');

      const { rows: addons } = await query(
        'SELECT * FROM addons WHERE code = ANY($1) AND is_active', [addon_codes],
      );

      const estimate = await PricingService.estimate({
        property, service, addons, scheduledAt: scheduled_at,
      });

      const expiresAt = new Date(Date.now() + config.booking.quoteTtlMinutes * 60_000);
      const { rows: [quote] } = await query(
        `INSERT INTO quotes (customer_id, property_id, service_code, addon_codes, scheduled_at,
                             duration_min, pricing_rule_id, subtotal_cents, ts_fee_cents,
                             tax_cents, total_cents, breakdown, expires_at)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING id`,
        [req.user.id, property_id, service_code, addon_codes, scheduled_at,
         estimate.duration_min, estimate.pricing_rule_id, estimate.subtotal_cents,
         estimate.ts_fee_cents, estimate.tax_cents, estimate.total_cents,
         estimate.breakdown, expiresAt],
      );

      res.status(201).json({
        quote_id: quote.id,
        expires_at: expiresAt,
        duration_min: estimate.duration_min,
        breakdown: estimate.breakdown,
        total_cents: estimate.total_cents,
      });
    } catch (err) { next(err); }
  },

  /**
   * The customer approves this order (a PayPal webview redirect) before
   * `POST /v1/bookings` is called with the resulting order id — PayPal's
   * authorize-then-capture needs the buyer's approval up front, unlike the
   * old Stripe flow which authorized inline during booking creation. Amount
   * matches exactly what `PaymentService.authorize` will later expect:
   * `PricingService.authorizationAmount(quote.total_cents)`.
   */
  async createPaypalOrder(req, res, next) {
    try {
      const { rows: [quote] } = await query(
        'SELECT * FROM quotes WHERE id = $1 AND customer_id = $2', [req.params.id, req.user.id],
      );
      if (!quote) throw AppError.notFound('Quote');
      if (quote.expires_at < new Date()) throw AppError.conflict('QUOTE_EXPIRED', 'Request a fresh quote');

      const order = await PaymentService.createOrder({
        amountCents: PricingService.authorizationAmount(quote.total_cents),
        reference: quote.id,
      });
      res.status(201).json(order);
    } catch (err) { next(err); }
  },
};

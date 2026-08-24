import { query } from '../../db/pool.js';
import { BookingService } from '../../services/booking.service.js';
import { TrustService } from '../../services/trust.service.js';
import { metrics } from '../../observability/metrics.js';

/** Address is exposed to the cleaner only while they need it. */
function scopeBooking(row, viewerId) {
  const isCleaner = row.cleaner_id === viewerId;
  const windowOpen = ['assigned', 'en_route', 'arrived', 'in_progress', 'completed'].includes(row.status)
    && (!row.completed_at || Date.now() - new Date(row.completed_at) < 24 * 3_600_000);

  if (isCleaner && !windowOpen) {
    const { line1, line2, access_notes, ...rest } = row;
    return rest;
  }
  return row;
}

export const BookingController = {
  async create(req, res, next) {
    try {
      const result = await BookingService.create({
        customerId: req.user.id,
        quoteId: req.body.quote_id,
        paypalOrderId: req.body.paypal_order_id,
        specialInstructions: req.body.special_instructions,
        entryMethod: req.body.entry_method,
      });
      metrics.bookingsCreated.inc();
      res.status(201).json(result);
    } catch (err) { next(err); }
  },

  async list(req, res, next) {
    try {
      const field = req.user.role === 'cleaner' ? 'cleaner_id' : 'customer_id';
      const filters = {
        upcoming: `AND status IN ('pending_match','assigned') AND scheduled_at > now()`,
        active: `AND status IN ('en_route','arrived','in_progress')`,
        past: `AND status IN ('completed','settled')`,
        canceled: `AND status = 'canceled'`,
      };
      const { rows } = await query(
        `SELECT b.*, s.name AS service_name
           FROM bookings b JOIN services s ON s.code = b.service_code
          WHERE b.${field} = $1 ${filters[req.query.status] ?? ''}
          ORDER BY b.scheduled_at DESC LIMIT $2`,
        [req.user.id, Math.min(Number(req.query.limit) || 20, 100)],
      );
      res.json({ bookings: rows.map((r) => scopeBooking(r, req.user.id)), next_cursor: null });
    } catch (err) { next(err); }
  },

  async get(req, res, next) {
    try {
      const { rows: [row] } = await query(
        `SELECT b.*, s.name AS service_name,
                a.line1, a.line2, a.city, a.region, a.postal_code, a.access_notes,
                u.full_name AS cleaner_name, u.avatar_key AS cleaner_avatar,
                snap.bayesian_rating AS cleaner_rating
           FROM bookings b
           JOIN services s   ON s.code = b.service_code
           JOIN properties p ON p.id = b.property_id
           JOIN addresses a  ON a.id = p.address_id
           LEFT JOIN users u ON u.id = b.cleaner_id
           LEFT JOIN cleaner_rating_snapshot snap ON snap.cleaner_id = b.cleaner_id
          WHERE b.id = $1`,
        [req.params.id],
      );
      res.json({ booking: scopeBooking(row, req.user.id) });
    } catch (err) { next(err); }
  },

  async updateStatus(req, res, next) {
    try {
      const booking = await BookingService.updateStatus(
        req.params.id, req.user.id, req.body.status,
        { location: req.body.location, actualDurationMin: req.body.actual_duration_min },
      );
      res.json({ booking });
    } catch (err) { next(err); }
  },

  async cancel(req, res, next) {
    try {
      const result = await BookingService.cancel(
        req.params.id, req.user.id, req.user.role, req.body.reason,
      );
      res.json(result);
    } catch (err) { next(err); }
  },

  async presignPhotos(req, res, next) {
    try {
      const urls = await TrustService.presignJobPhotos(req.params.id, req.body.phase, req.body.count);
      res.json({ uploads: urls });
    } catch (err) { next(err); }
  },

  async openMaskedCall(req, res, next) {
    try {
      const session = await TrustService.openMaskedCall(req.params.id);
      res.json(session);
    } catch (err) { next(err); }
  },
};

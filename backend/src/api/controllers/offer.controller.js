import { query } from '../../db/pool.js';
import { MatchingService } from '../../services/matching.service.js';

const JITTER_DEGREES = 0.003; // ~300 m: enough to place the pin, not the door

export const OfferController = {
  /** Open offers for the Job Discovery screen. Exact address is withheld until accept. */
  async list(req, res, next) {
    try {
      const { rows } = await query(
        `SELECT o.id AS offer_id, o.booking_id, o.distance_km, o.payout_cents, o.expires_at,
                b.scheduled_at, b.duration_min, b.service_code,
                s.name AS service_name,
                p.bedrooms, p.bathrooms, p.square_feet, p.has_pets,
                a.city, a.region, a.postal_code,
                ST_Y(a.location::geometry) AS lat, ST_X(a.location::geometry) AS lng
           FROM booking_offers o
           JOIN bookings b   ON b.id = o.booking_id
           JOIN services s   ON s.code = b.service_code
           JOIN properties p ON p.id = b.property_id
           JOIN addresses a  ON a.id = p.address_id
          WHERE o.cleaner_id = $1
            AND o.status IN ('sent','viewed')
            AND o.expires_at > now()
            AND b.status = 'pending_match'
          ORDER BY o.score DESC
          LIMIT 25`,
        [req.user.id],
      );

      await query(
        `UPDATE booking_offers SET status='viewed'
          WHERE cleaner_id=$1 AND status='sent' AND expires_at > now()`,
        [req.user.id],
      );

      res.json({
        offers: rows.map((r) => ({
          offer_id: r.offer_id,
          booking_id: r.booking_id,
          service: { code: r.service_code, name: r.service_name },
          scheduled_at: r.scheduled_at,
          duration_min: r.duration_min,
          payout_cents: r.payout_cents,
          distance_km: Number(r.distance_km),
          neighborhood: `${r.city}, ${r.region} ${r.postal_code}`,
          approx_location: {
            lat: r.lat + (Math.random() - 0.5) * JITTER_DEGREES,
            lng: r.lng + (Math.random() - 0.5) * JITTER_DEGREES,
          },
          property: {
            bedrooms: r.bedrooms, bathrooms: r.bathrooms,
            square_feet: r.square_feet, has_pets: r.has_pets,
          },
          expires_at: r.expires_at,
        })),
        next_cursor: null,
      });
    } catch (err) { next(err); }
  },

  async accept(req, res, next) {
    try {
      const booking = await MatchingService.acceptOffer(req.params.id, req.user.id);
      res.json({ booking });
    } catch (err) { next(err); }
  },

  async decline(req, res, next) {
    try {
      await MatchingService.declineOffer(req.params.id, req.user.id, req.body.reason);
      res.status(204).end();
    } catch (err) { next(err); }
  },
};

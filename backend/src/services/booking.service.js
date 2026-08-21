import { withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';
import { PricingService } from './pricing.service.js';
import { PaymentService } from './payment.service.js';
import { matchQueue, privacyQueue } from '../jobs/queues.js';
import { RealtimeService } from './realtime.service.js';

/** The only legal moves. Anything else is a 409, not a silent no-op. */
const TRANSITIONS = {
  draft: ['quoted', 'canceled'],
  quoted: ['pending_match', 'canceled'],
  pending_match: ['assigned', 'canceled'],
  assigned: ['en_route', 'canceled'],
  en_route: ['arrived', 'canceled'],
  arrived: ['in_progress', 'canceled'],
  in_progress: ['completed'],
  completed: ['settled', 'disputed'],
  settled: ['disputed'],
  canceled: [],
  disputed: ['settled'],
};

const REQUIRES_LOCATION = new Set(['arrived', 'completed']);

export class BookingService {
  static async create({ customerId, quoteId, paymentMethodId, specialInstructions, entryMethod }) {
    return withTransaction(async (client) => {
      const { rows: [quote] } = await client.query(
        `SELECT * FROM quotes WHERE id = $1 AND customer_id = $2 FOR UPDATE`,
        [quoteId, customerId],
      );
      if (!quote) throw AppError.notFound('Quote');
      if (quote.expires_at < new Date()) throw AppError.conflict('QUOTE_EXPIRED', 'Request a fresh quote');

      const leadMinutes = (new Date(quote.scheduled_at) - Date.now()) / 60_000;
      if (leadMinutes < config.booking.minLeadMinutes) {
        throw AppError.unprocessable('LEAD_TIME_TOO_SHORT',
          `Bookings need at least ${config.booking.minLeadMinutes} minutes of notice`);
      }

      const rules = await PricingService.getRules();
      const commission = Math.round((quote.subtotal_cents * rules.commission_bps) / 10_000);

      const { rows: [booking] } = await client.query(
        `INSERT INTO bookings (
           reference, customer_id, property_id, quote_id, service_code, addon_codes,
           status, scheduled_at, duration_min, special_instructions,
           subtotal_cents, ts_fee_cents, tax_cents, total_cents, commission_cents, payout_cents)
         VALUES ($1,$2,$3,$4,$5,$6,'quoted',$7,$8,$9,$10,$11,$12,$13,$14,$15)
         RETURNING *`,
        [generateReference(), customerId, quote.property_id, quote.id, quote.service_code,
         quote.addon_codes, quote.scheduled_at, quote.duration_min, specialInstructions,
         quote.subtotal_cents, quote.ts_fee_cents, quote.tax_cents, quote.total_cents,
         commission, quote.subtotal_cents - commission],
      );

      // Authorize before we promise anything. A booking without a hold on
      // funds is a booking you cannot collect on; if this throws, the whole
      // transaction rolls back and no orphan row survives.
      const payment = await PaymentService.authorize({
        client, booking, customerId, paymentMethodId,
        amountCents: PricingService.authorizationAmount(booking.total_cents),
      });

      await this.#transition(client, booking, 'pending_match', { actorId: customerId, actorRole: 'customer' });
      await matchQueue.add('dispatch', { bookingId: booking.id, round: 1 },
        { jobId: `dispatch:${booking.id}:1` });

      return { booking: { ...booking, status: 'pending_match', entry_method: entryMethod }, payment };
    });
  }

  /** Cleaner-driven progression. Geofenced where it matters. */
  static async updateStatus(bookingId, cleanerId, nextStatus, { location, actualDurationMin } = {}) {
    return withTransaction(async (client) => {
      const { rows: [booking] } = await client.query(
        `SELECT b.*, a.location AS property_geo
           FROM bookings b
           JOIN properties p ON p.id = b.property_id
           JOIN addresses  a ON a.id = p.address_id
          WHERE b.id = $1 FOR UPDATE`,
        [bookingId],
      );
      if (!booking) throw AppError.notFound('Booking');
      if (booking.cleaner_id !== cleanerId) throw AppError.forbidden('Not your job');

      if (!TRANSITIONS[booking.status]?.includes(nextStatus)) {
        throw AppError.conflict('ILLEGAL_TRANSITION',
          `Cannot move from ${booking.status} to ${nextStatus}`);
      }

      if (REQUIRES_LOCATION.has(nextStatus)) {
        if (!location) throw AppError.badRequest('LOCATION_REQUIRED', 'Location required for this status');
        const { rows: [{ within }] } = await client.query(
          `SELECT ST_DWithin(
             (SELECT a.location FROM properties p JOIN addresses a ON a.id = p.address_id
               WHERE p.id = $1),
             ST_SetSRID(ST_MakePoint($2,$3),4326)::geography, $4) AS within`,
          [booking.property_id, location.lng, location.lat, config.booking.geofenceMeters],
        );
        if (!within) {
          throw AppError.unprocessable('GEOFENCE_FAILED',
            `You must be within ${config.booking.geofenceMeters} m of the property`);
        }
      }

      if (nextStatus === 'completed') {
        const { rows: [{ count }] } = await client.query(
          `SELECT COUNT(*)::int AS count FROM job_photos WHERE booking_id = $1 AND phase = 'after'`,
          [bookingId],
        );
        const { rows: [service] } = await client.query(
          'SELECT requires_photos FROM services WHERE code = $1', [booking.service_code],
        );
        if (service.requires_photos && count < 3) {
          throw AppError.unprocessable('PHOTOS_REQUIRED', 'Add at least 3 after photos to finish');
        }
      }

      const updated = await this.#transition(client, booking, nextStatus,
        { actorId: cleanerId, actorRole: 'cleaner', location });

      // Rules read this node to decide whether location writes are allowed,
      // so it has to move in lockstep with the database.
      await RealtimeService.publishStatus(bookingId, nextStatus);

      if (nextStatus === 'completed') {
        await PaymentService.captureAndTransfer({ client, booking, actualDurationMin });
        // Keep the thread readable while the dispute window is open, then close it.
        await privacyQueue.add('close_channel', { bookingId },
          { delay: 24 * 3_600_000, jobId: `close:${bookingId}` });
      }
      return updated;
    });
  }

  static async cancel(bookingId, actorId, actorRole, reason) {
    return withTransaction(async (client) => {
      const { rows: [booking] } = await client.query(
        'SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [bookingId],
      );
      if (!booking) throw AppError.notFound('Booking');
      if (!TRANSITIONS[booking.status]?.includes('canceled')) {
        throw AppError.conflict('NOT_CANCELABLE', `A ${booking.status} job cannot be canceled here`);
      }

      const outcome = actorRole === 'customer'
        ? PricingService.cancellationOutcome(booking)
        : { fee_cents: 0, cleaner_cents: 0, refund_cents: booking.total_cents };

      await PaymentService.resolveCancellation({ client, booking, outcome });

      await client.query(
        `UPDATE bookings
            SET status='canceled', canceled_at=now(), canceled_by=$2,
                cancel_reason=$3, cancel_fee_cents=$4
          WHERE id=$1`,
        [bookingId, actorRole, reason, outcome.fee_cents],
      );
      await client.query(
        `INSERT INTO booking_status_history (booking_id, from_status, to_status, actor_id, actor_role, metadata)
         VALUES ($1,$2,'canceled',$3,$4,$5)`,
        [bookingId, booking.status, actorId, actorRole, JSON.stringify({ reason, ...outcome })],
      );

      // A cleaner cancel returns the job to the pool with priority.
      if (actorRole === 'cleaner') {
        await client.query(
          `UPDATE bookings SET status='pending_match', cleaner_id=NULL, canceled_at=NULL,
                  canceled_by=NULL, cancel_reason=NULL WHERE id=$1`, [bookingId],
        );
        await matchQueue.add('dispatch', { bookingId, round: 1 }, { priority: 1 });
      }
      return { status: 'canceled', ...outcome };
    });
  }

  static async #transition(client, booking, to, { actorId, actorRole, location }) {
    const stamp = {
      en_route: 'en_route_at', arrived: 'arrived_at',
      in_progress: 'started_at', completed: 'completed_at',
    }[to];

    const { rows: [updated] } = await client.query(
      `UPDATE bookings SET status = $2 ${stamp ? `, ${stamp} = now()` : ''} WHERE id = $1 RETURNING *`,
      [booking.id, to],
    );
    await client.query(
      `INSERT INTO booking_status_history (booking_id, from_status, to_status, actor_id, actor_role, location)
       VALUES ($1,$2,$3,$4,$5, CASE WHEN $6::float IS NULL THEN NULL
              ELSE ST_SetSRID(ST_MakePoint($6,$7),4326)::geography END)`,
      [booking.id, booking.status, to, actorId, actorRole, location?.lng ?? null, location?.lat ?? null],
    );
    return updated;
  }
}

/** Human-friendly, unambiguous: no 0/O/1/I. Support agents read these aloud. */
function generateReference() {
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  let out = '';
  for (let i = 0; i < 6; i++) out += alphabet[Math.floor(Math.random() * alphabet.length)];
  return `SPK-${out}`;
}

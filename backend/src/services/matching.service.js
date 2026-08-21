import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';
import { logger } from '../utils/logger.js';
import { notifyOffer } from './notification.service.js';
import { RealtimeService } from './realtime.service.js';
import { scoreCandidate } from '../domain/matching.score.js';
import { metrics } from '../observability/metrics.js';
import { FIND_CANDIDATES_SQL } from './matching.candidates.sql.js';

const { weights, bayesian, broadcastSize, offerTtlSeconds, maxRounds, radiusExpansionFactor } = config.matching;

/**
 * Matching engine.
 *
 * Strategy for v1 is broadcast-then-claim: rank eligible cleaners, push the
 * top N an offer, first accept wins. Auto-assign needs supply-density data
 * you won't have on day one. The interface below is what stays stable when
 * you swap the strategy — callers only know `dispatch` and `acceptOffer`.
 */
export class MatchingService {
  /**
   * Hard filters in SQL, soft ranking in the same pass. PostGIS gives us
   * straight-line distance cheaply; road distance is only worth a Distance
   * Matrix call for the finalists.
   */
  static async findCandidates(booking, { radiusMultiplier = 1, limit = 30 } = {}) {
    const { rows } = await query(
      FIND_CANDIDATES_SQL,
      [booking.id, radiusMultiplier, bayesian.priorRating, booking.service_code,
       booking.scheduled_at, booking.duration_min, limit],
    );
    return rows;
  }

  /** Weighted score in [0,1]. Arithmetic lives in `domain/matching.score.js`. */
  static score(candidate, { medianEarned7d }) {
    return scoreCandidate(candidate, { weights, medianEarned7d });
  }

  /** Rank, persist offers, push notifications. Idempotent per (booking, round). */
  static async dispatch(bookingId, round = 1) {
    const { rows: [booking] } = await query('SELECT * FROM bookings WHERE id = $1', [bookingId]);
    if (!booking) throw AppError.notFound('Booking');
    if (booking.status !== 'pending_match') {
      logger.info({ bookingId, status: booking.status }, 'dispatch skipped, no longer matchable');
      return { offers: 0 };
    }
    metrics.dispatchRounds.inc();

    const radiusMultiplier = radiusExpansionFactor ** (round - 1);
    const candidates = await this.findCandidates(booking, { radiusMultiplier });

    if (candidates.length === 0) {
      if (round >= maxRounds) return this.escalate(booking, 'NO_SUPPLY');
      return this.scheduleRound(booking, round + 1);
    }

    const earnings = candidates.map((c) => Number(c.earned_7d)).sort((a, b) => a - b);
    const medianEarned7d = earnings[Math.floor(earnings.length / 2)] || 0;

    const ranked = candidates
      .map((c) => ({ ...c, score: this.score(c, { medianEarned7d }) }))
      .sort((a, b) => b.score - a.score)
      .slice(0, broadcastSize);

    const expiresAt = new Date(Date.now() + offerTtlSeconds * 1000);

    await withTransaction(async (client) => {
      for (const c of ranked) {
        await client.query(
          `INSERT INTO booking_offers
             (booking_id, cleaner_id, round, score, distance_km, payout_cents, expires_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7)
           ON CONFLICT (booking_id, cleaner_id, round) DO NOTHING`,
          [booking.id, c.cleaner_id, round, c.score, c.distance_km, booking.payout_cents, expiresAt],
        );
      }
    });

    metrics.offersBroadcast.inc({}, ranked.length);
    await Promise.allSettled(ranked.map((c) => notifyOffer(c.cleaner_id, booking, c)));
    logger.info({ bookingId, round, offers: ranked.length }, 'offers broadcast');
    return { offers: ranked.length, expiresAt };
  }

  /**
   * First claim wins. FOR UPDATE SKIP LOCKED on the booking row means two
   * cleaners tapping Accept in the same 50ms cannot both be assigned — the
   * loser gets 409 rather than a phantom job.
   */
  static async acceptOffer(offerId, cleanerId) {
    return withTransaction(async (client) => {
      const { rows: [offer] } = await client.query(
        `SELECT o.*, b.status AS booking_status
           FROM booking_offers o
           JOIN bookings b ON b.id = o.booking_id
          WHERE o.id = $1 AND o.cleaner_id = $2
          FOR UPDATE OF o`,
        [offerId, cleanerId],
      );
      if (!offer) throw AppError.notFound('Offer');
      if (offer.expires_at < new Date()) throw new AppError(410, 'OFFER_EXPIRED', 'This offer has expired');
      if (offer.status !== 'sent' && offer.status !== 'viewed') {
        throw AppError.conflict('OFFER_CLOSED', 'This offer is no longer open');
      }

      const { rows: [booking] } = await client.query(
        `SELECT * FROM bookings
          WHERE id = $1 AND status = 'pending_match'
          FOR UPDATE SKIP LOCKED`,
        [offer.booking_id],
      );
      if (!booking) throw AppError.conflict('OFFER_TAKEN', 'Another cleaner already took this job');

      await client.query(
        `UPDATE bookings
            SET cleaner_id = $1, status = 'assigned', matched_at = now()
          WHERE id = $2`,
        [cleanerId, booking.id],
      );
      await client.query(
        `UPDATE booking_offers SET status = 'accepted', responded_at = now() WHERE id = $1`,
        [offerId],
      );
      await client.query(
        `UPDATE booking_offers SET status = 'superseded'
          WHERE booking_id = $1 AND id <> $2 AND status IN ('sent','viewed')`,
        [booking.id, offerId],
      );
      await client.query(
        `INSERT INTO booking_status_history (booking_id, from_status, to_status, actor_id, actor_role)
         VALUES ($1,'pending_match','assigned',$2,'cleaner')`,
        [booking.id, cleanerId],
      );

      metrics.bookingsMatched.inc();
      metrics.timeToMatch.observe((Date.now() - new Date(booking.created_at)) / 1000);

      const assigned = { ...booking, cleaner_id: cleanerId, status: 'assigned' };
      // Opens tracking + chat for exactly these two people, and no one else.
      await RealtimeService.grantAccess(assigned);
      return assigned;
    });
  }

  static async declineOffer(offerId, cleanerId, reason) {
    await query(
      `UPDATE booking_offers
          SET status = 'declined', responded_at = now()
        WHERE id = $1 AND cleaner_id = $2 AND status IN ('sent','viewed')`,
      [offerId, cleanerId],
    );
    logger.info({ offerId, reason }, 'offer declined'); // reasons feed radius tuning
  }

  static async scheduleRound(booking, nextRound) {
    const { matchQueue } = await import('../jobs/queues.js');
    await matchQueue.add('dispatch', { bookingId: booking.id, round: nextRound },
      { delay: offerTtlSeconds * 1000, jobId: `dispatch:${booking.id}:${nextRound}` });
    return { offers: 0, nextRound };
  }

  static async escalate(booking, code) {
    logger.error({ bookingId: booking.id, code }, 'matching exhausted — ops escalation');
    await query(
      `INSERT INTO booking_status_history (booking_id, from_status, to_status, actor_role, metadata)
       VALUES ($1, $2, $2, 'admin', $3)`,
      [booking.id, booking.status, JSON.stringify({ escalation: code })],
    );
    return { offers: 0, escalated: true };
  }
}

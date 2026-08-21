import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { AppError } from '../utils/errors.js';
import { logger } from '../utils/logger.js';
import { PaymentService } from './payment.service.js';
import { ratingQueue, webhookQueue } from '../jobs/queues.js';

/**
 * Admin operations.
 *
 * Every method here writes an `audit_log` row in the same transaction as the
 * change it makes. The app role has no UPDATE or DELETE grant on that table,
 * so an admin cannot quietly reverse their own trail. This is the difference
 * between "we have logs" and "we have evidence."
 */
export class AdminService {
  static async audit(client, { actorId, action, entityType, entityId, before, after, ip }) {
    await client.query(
      `INSERT INTO audit_log (actor_id, action, entity_type, entity_id, before, after, ip_address)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [actorId, action, entityType, entityId, before ?? null, after ?? null, ip ?? null],
    );
  }

  // ------------------------------------------------------------- metrics ---
  /**
   * One query per number, deliberately. A single clever CTE would be faster
   * and unreadable at 2am when the match rate drops and someone needs to know
   * which figure is lying.
   */
  static async metrics() {
    const [gmv, bookings, matching, supply, disputes, quality] = await Promise.all([
      query(`SELECT COALESCE(SUM(total_cents),0)::int AS gross_cents,
                    COALESCE(SUM(commission_cents),0)::int AS revenue_cents
               FROM bookings
              WHERE status IN ('completed','settled') AND completed_at > now() - interval '7 days'`),
      query(`SELECT COUNT(*) FILTER (WHERE created_at > now() - interval '24 hours')::int AS booked_today,
                    COUNT(*) FILTER (WHERE status = 'canceled'
                      AND canceled_at > now() - interval '7 days')::int AS canceled_7d
               FROM bookings`),
      query(`SELECT COUNT(*) FILTER (WHERE matched_at IS NOT NULL)::int AS matched,
                    COUNT(*)::int AS total,
                    COALESCE(AVG(EXTRACT(EPOCH FROM (matched_at - created_at)))
                             FILTER (WHERE matched_at IS NOT NULL), 0)::int AS avg_match_seconds
               FROM bookings WHERE created_at > now() - interval '7 days'`),
      query(`SELECT COUNT(*) FILTER (WHERE onboarding_status = 'approved')::int AS approved,
                    COUNT(*) FILTER (WHERE onboarding_status IN ('docs_submitted','check_pending'))::int AS awaiting_review,
                    COUNT(*) FILTER (WHERE is_available)::int AS online
               FROM cleaner_profiles`),
      query(`SELECT COUNT(*) FILTER (WHERE status <> 'resolved')::int AS open,
                    COUNT(*) FILTER (WHERE status <> 'resolved'
                      AND created_at < now() - interval '48 hours')::int AS breaching_sla
               FROM disputes`),
      query(`SELECT COALESCE(AVG(bayesian_rating),0)::numeric(3,2) AS avg_rating,
                    COUNT(*) FILTER (WHERE is_dispatchable = false)::int AS below_floor
               FROM cleaner_rating_snapshot`),
    ]);

    const m = matching.rows[0];
    return {
      gross_cents: gmv.rows[0].gross_cents,
      revenue_cents: gmv.rows[0].revenue_cents,
      booked_today: bookings.rows[0].booked_today,
      canceled_7d: bookings.rows[0].canceled_7d,
      match_rate: m.total ? Number((m.matched / m.total).toFixed(3)) : null,
      avg_match_seconds: m.avg_match_seconds,
      cleaners_approved: supply.rows[0].approved,
      cleaners_awaiting_review: supply.rows[0].awaiting_review,
      cleaners_online: supply.rows[0].online,
      disputes_open: disputes.rows[0].open,
      disputes_breaching_sla: disputes.rows[0].breaching_sla,
      avg_rating: Number(quality.rows[0].avg_rating),
      cleaners_below_floor: quality.rows[0].below_floor,
    };
  }

  // ------------------------------------------------------------- vetting ---
  static async vettingQueue({ limit = 50 } = {}) {
    const { rows } = await query(
      `SELECT c.user_id, u.full_name, u.email, u.created_at AS applied_at,
              c.onboarding_status, c.bg_status, c.bg_completed_at, c.years_experience,
              c.service_types, c.service_radius_km, c.payouts_enabled, c.bio,
              COALESCE(json_agg(json_build_object(
                'id', d.id, 'doc_type', d.doc_type, 'expires_at', d.expires_at,
                'verified_at', d.verified_at, 'rejected_note', d.rejected_note,
                's3_key', d.s3_key
              ) ORDER BY d.doc_type) FILTER (WHERE d.id IS NOT NULL), '[]') AS documents
         FROM cleaner_profiles c
         JOIN users u ON u.id = c.user_id
         LEFT JOIN cleaner_documents d ON d.cleaner_id = c.user_id
        WHERE c.onboarding_status IN ('docs_submitted','check_pending')
          AND u.deleted_at IS NULL
        GROUP BY c.user_id, u.full_name, u.email, u.created_at
        ORDER BY u.created_at ASC
        LIMIT $1`,
      [limit],
    );
    // Oldest first, not newest: applicants who have waited longest are the
    // ones about to give up and drive for someone else.
    return rows;
  }

  static async reviewDocument({ documentId, actorId, approved, note, ip }) {
    return withTransaction(async (client) => {
      const { rows: [before] } = await client.query(
        'SELECT * FROM cleaner_documents WHERE id = $1 FOR UPDATE', [documentId]);
      if (!before) throw AppError.notFound('Document');

      const { rows: [after] } = await client.query(
        `UPDATE cleaner_documents
            SET verified_at = $2, verified_by = $3, rejected_note = $4
          WHERE id = $1 RETURNING *`,
        [documentId, approved ? new Date() : null, actorId, approved ? null : note],
      );

      await this.audit(client, {
        actorId, action: approved ? 'document.verify' : 'document.reject',
        entityType: 'cleaner_document', entityId: documentId,
        before, after, ip,
      });
      return after;
    });
  }

  /**
   * Approval gate. Three conditions, and none of them are waivable from the
   * UI: a clear background check, every document verified, and a Stripe
   * account that can actually receive money. Approving a cleaner who can't be
   * paid produces a job that completes and then fails at transfer.
   */
  static async approveCleaner({ cleanerId, actorId, ip }) {
    return withTransaction(async (client) => {
      const { rows: [profile] } = await client.query(
        'SELECT * FROM cleaner_profiles WHERE user_id = $1 FOR UPDATE', [cleanerId]);
      if (!profile) throw AppError.notFound('Cleaner');

      if (profile.bg_status !== 'clear') {
        throw AppError.unprocessable('BACKGROUND_NOT_CLEAR',
          `Background check is ${profile.bg_status}. Approval needs a clear result.`);
      }
      const { rows: [docs] } = await client.query(
        `SELECT COUNT(*)::int AS total,
                COUNT(*) FILTER (WHERE verified_at IS NOT NULL)::int AS verified
           FROM cleaner_documents WHERE cleaner_id = $1`, [cleanerId]);
      if (docs.total === 0 || docs.verified < docs.total) {
        throw AppError.unprocessable('DOCUMENTS_PENDING',
          `${docs.total - docs.verified} document(s) still need review.`);
      }
      if (!profile.payouts_enabled) {
        throw AppError.unprocessable('PAYOUTS_DISABLED',
          'Stripe onboarding is incomplete — this cleaner could not be paid.');
      }

      const { rows: [after] } = await client.query(
        `UPDATE cleaner_profiles SET onboarding_status = 'approved' WHERE user_id = $1 RETURNING *`,
        [cleanerId]);
      await client.query(`UPDATE users SET status = 'active' WHERE id = $1`, [cleanerId]);

      await this.audit(client, {
        actorId, action: 'cleaner.approve', entityType: 'cleaner', entityId: cleanerId,
        before: profile, after, ip,
      });
      logger.info({ cleanerId, actorId }, 'cleaner approved');
      return after;
    });
  }

  static async rejectCleaner({ cleanerId, actorId, reason, ip }) {
    if (!reason?.trim()) {
      throw AppError.badRequest('REASON_REQUIRED', 'A rejection needs a reason on the record');
    }
    return withTransaction(async (client) => {
      const { rows: [before] } = await client.query(
        'SELECT * FROM cleaner_profiles WHERE user_id = $1 FOR UPDATE', [cleanerId]);
      if (!before) throw AppError.notFound('Cleaner');

      const { rows: [after] } = await client.query(
        `UPDATE cleaner_profiles SET onboarding_status = 'rejected', is_available = false
          WHERE user_id = $1 RETURNING *`, [cleanerId]);

      await this.audit(client, {
        actorId, action: 'cleaner.reject', entityType: 'cleaner', entityId: cleanerId,
        before, after: { ...after, reason }, ip,
      });
      return after;
    });
  }

  /**
   * Suspension pulls a cleaner out of dispatch without destroying their
   * account or their earnings history. Live jobs are left alone — stranding a
   * customer mid-booking to enforce a suspension helps nobody.
   */
  static async suspendCleaner({ cleanerId, actorId, days, reason, ip }) {
    return withTransaction(async (client) => {
      const until = new Date(Date.now() + days * 86_400_000);
      const { rows: [before] } = await client.query(
        'SELECT * FROM cleaner_profiles WHERE user_id = $1 FOR UPDATE', [cleanerId]);
      if (!before) throw AppError.notFound('Cleaner');

      const { rows: [after] } = await client.query(
        `UPDATE cleaner_profiles SET suspended_until = $2, is_available = false
          WHERE user_id = $1 RETURNING *`, [cleanerId, until]);

      const { rows: [{ count }] } = await client.query(
        `SELECT COUNT(*)::int AS count FROM bookings
          WHERE cleaner_id = $1 AND status IN ('assigned','en_route','arrived','in_progress')`,
        [cleanerId]);

      await this.audit(client, {
        actorId, action: 'cleaner.suspend', entityType: 'cleaner', entityId: cleanerId,
        before, after: { ...after, reason, days }, ip,
      });
      return { ...after, live_bookings_untouched: count };
    });
  }

  // ------------------------------------------------------------ disputes ---
  static async disputeQueue({ status = 'open', limit = 50 } = {}) {
    const { rows } = await query(
      `SELECT d.*, b.reference, b.scheduled_at, b.completed_at, b.total_cents,
              b.subtotal_cents, b.payout_cents, b.service_code,
              cu.full_name AS customer_name, cl.full_name AS cleaner_name,
              b.cleaner_id, b.customer_id,
              p.id AS payment_id, p.captured_cents, p.refunded_cents,
              (SELECT COUNT(*)::int FROM job_photos jp WHERE jp.booking_id = b.id) AS photo_count,
              (SELECT COUNT(*)::int FROM location_breadcrumbs lb WHERE lb.booking_id = b.id) AS breadcrumb_count,
              (SELECT rating FROM reviews r
                WHERE r.booking_id = b.id AND r.author_type = 'customer') AS customer_rating
         FROM disputes d
         JOIN bookings b ON b.id = d.booking_id
         JOIN users cu ON cu.id = b.customer_id
         LEFT JOIN users cl ON cl.id = b.cleaner_id
         LEFT JOIN payments p ON p.booking_id = b.id
        WHERE ($1 = 'all' OR ($1 = 'open' AND d.status <> 'resolved') OR d.status = $1)
        ORDER BY d.created_at ASC
        LIMIT $2`,
      [status, limit],
    );
    return rows;
  }

  /**
   * Resolve a dispute. A refund and a cleaner penalty are separate decisions:
   * plenty of disputes end with the customer made whole and the cleaner at no
   * fault (a broken lockbox, a landlord who let someone else in). Coupling the
   * two would teach agents to under-refund to protect good cleaners.
   */
  static async resolveDispute({ disputeId, actorId, resolution, refundCents = 0, penalty, ip }) {
    return withTransaction(async (client) => {
      const { rows: [dispute] } = await client.query(
        'SELECT * FROM disputes WHERE id = $1 FOR UPDATE', [disputeId]);
      if (!dispute) throw AppError.notFound('Dispute');
      if (dispute.status === 'resolved') {
        throw AppError.conflict('ALREADY_RESOLVED', 'This dispute is already closed');
      }
      if (!resolution?.trim()) {
        throw AppError.badRequest('RESOLUTION_REQUIRED', 'Write what you decided and why');
      }

      if (refundCents > 0) {
        const { rows: [payment] } = await client.query(
          'SELECT id FROM payments WHERE booking_id = $1', [dispute.booking_id]);
        if (!payment) throw AppError.unprocessable('NO_PAYMENT', 'No payment to refund');
        await PaymentService.refund({
          client, paymentId: payment.id, amountCents: refundCents,
          reason: `dispute:${disputeId}`, issuedBy: actorId,
        });
      }

      if (penalty === 'hide_review' ) {
        await client.query(
          `UPDATE reviews SET is_hidden = true WHERE booking_id = $1 AND author_type = 'customer'`,
          [dispute.booking_id]);
        const { rows: [b] } = await client.query(
          'SELECT cleaner_id FROM bookings WHERE id = $1', [dispute.booking_id]);
        if (b?.cleaner_id) await ratingQueue.add('recompute', { cleanerId: b.cleaner_id });
      }

      const { rows: [after] } = await client.query(
        `UPDATE disputes
            SET status = 'resolved', resolution = $2, refund_cents = $3,
                assigned_to = $4, resolved_at = now()
          WHERE id = $1 RETURNING *`,
        [disputeId, resolution, refundCents, actorId]);

      await client.query(`UPDATE bookings SET status = 'settled' WHERE id = $1 AND status = 'disputed'`,
        [dispute.booking_id]);

      await this.audit(client, {
        actorId, action: 'dispute.resolve', entityType: 'dispute', entityId: disputeId,
        before: dispute, after: { ...after, penalty }, ip,
      });
      return after;
    });
  }

  /** Everything an agent needs to judge one booking, in one round trip. */
  static async bookingDossier(bookingId) {
    const [booking, timeline, photos, payment, reviews, breadcrumbs] = await Promise.all([
      query(`SELECT b.*, cu.full_name AS customer_name, cl.full_name AS cleaner_name,
                    a.line1, a.city, a.region, a.postal_code
               FROM bookings b
               JOIN users cu ON cu.id = b.customer_id
               LEFT JOIN users cl ON cl.id = b.cleaner_id
               JOIN properties p ON p.id = b.property_id
               JOIN addresses a ON a.id = p.address_id
              WHERE b.id = $1`, [bookingId]),
      query(`SELECT from_status, to_status, actor_role, created_at,
                    ST_Y(location::geometry) AS lat, ST_X(location::geometry) AS lng
               FROM booking_status_history WHERE booking_id = $1 ORDER BY created_at`, [bookingId]),
      query('SELECT id, phase, s3_key, created_at FROM job_photos WHERE booking_id = $1', [bookingId]),
      query('SELECT * FROM payments WHERE booking_id = $1', [bookingId]),
      query('SELECT * FROM reviews WHERE booking_id = $1', [bookingId]),
      query(`SELECT ST_Y(point::geometry) AS lat, ST_X(point::geometry) AS lng, recorded_at
               FROM location_breadcrumbs WHERE booking_id = $1 ORDER BY recorded_at`, [bookingId]),
    ]);

    if (!booking.rows[0]) throw AppError.notFound('Booking');
    return {
      booking: booking.rows[0],
      timeline: timeline.rows,
      photos: photos.rows,
      payment: payment.rows[0] ?? null,
      reviews: reviews.rows,
      breadcrumbs: breadcrumbs.rows,
    };
  }

  // -------------------------------------------------------- webhook DLQ ---
  /**
   * Failed webhooks the replay sweep is working on or has given up on.
   *   status = 'dead'    → poison-pilled (attempts exhausted); a human must act
   *           'failing'  → still inside the backoff/retry budget
   *           'all'      → both
   * The payload is deliberately omitted — it can be large and holds PII; pull a
   * single dossier separately if you need the body.
   */
  static async listFailedWebhooks({ status = 'dead' } = {}) {
    const max = config.webhooks.maxReplayAttempts;
    const clause = { dead: 'AND attempts >= $1', failing: 'AND attempts < $1', all: '' }[status]
      ?? 'AND attempts >= $1';
    const { rows } = await query(
      `SELECT id, provider, event_type, attempts, error,
              received_at, last_attempt_at, next_attempt_at
         FROM webhook_events
        WHERE processed_at IS NULL AND error IS NOT NULL ${clause}
        ORDER BY received_at DESC
        LIMIT 200`,
      clause ? [max] : [],
    );
    return { poison_pill_at: max, webhooks: rows };
  }

  /**
   * Hand a failed webhook back to the sweep: clear the attempt count so the
   * poison-pill gate reopens, make it due now, and nudge the queue so it doesn't
   * wait for the next tick. Idempotent effects mean re-running the handler is
   * safe; refusing an already-processed event keeps this from looking like it
   * "did" something it didn't.
   */
  static async requeueWebhook({ eventId, actorId, ip }) {
    const after = await withTransaction(async (client) => {
      const { rows: [before] } = await client.query(
        'SELECT * FROM webhook_events WHERE id = $1 FOR UPDATE', [eventId]);
      if (!before) throw AppError.notFound('Webhook event');
      if (before.processed_at) {
        throw AppError.conflict('ALREADY_PROCESSED', 'This event already succeeded — nothing to replay');
      }

      const { rows: [row] } = await client.query(
        `UPDATE webhook_events
            SET attempts = 0, next_attempt_at = now()
          WHERE id = $1
        RETURNING id, provider, event_type, attempts, error, next_attempt_at`,
        [eventId]);

      // audit_log.entity_id is a uuid; webhook ids are provider strings (evt_…),
      // so the id rides in the JSON rather than the entity_id column.
      await this.audit(client, {
        actorId, action: 'webhook.requeue', entityType: 'webhook_event', entityId: null,
        before: { id: before.id, attempts: before.attempts, error: before.error },
        after: { id: before.id, attempts: 0 }, ip,
      });
      return row;
    });

    await webhookQueue.add('replay_failed', {}, { jobId: `replay:${eventId}:${Date.now()}` });
    logger.info({ eventId, actorId }, 'webhook requeued for replay');
    return after;
  }
}

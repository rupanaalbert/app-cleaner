import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, requireBookingParty } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { query } from '../../db/pool.js';
import { config } from '../../config/index.js';
import { AppError } from '../../utils/errors.js';
import { ratingQueue } from '../../jobs/queues.js';

const router = Router();

router.post('/bookings/:id/reviews', requireAuth, requireBookingParty,
  validate(z.object({
    rating: z.number().int().min(1).max(5),
    tags: z.array(z.string()).max(5).default([]),
    comment: z.string().max(2000).optional(),
  })),
  async (req, res, next) => {
    try {
      const { rows: [booking] } = await query(
        `SELECT * FROM bookings WHERE id = $1 AND status IN ('completed','settled','disputed')`,
        [req.params.id]);
      if (!booking) throw AppError.conflict('NOT_REVIEWABLE', 'You can review a job once it is complete');

      const daysSince = (Date.now() - new Date(booking.completed_at)) / 86_400_000;
      if (daysSince > config.booking.reviewWindowDays) {
        throw AppError.conflict('REVIEW_WINDOW_CLOSED', 'The review window has closed');
      }

      const authorType = booking.customer_id === req.user.id ? 'customer' : 'cleaner';
      const subjectId = authorType === 'customer' ? booking.cleaner_id : booking.customer_id;

      // Double-blind: hidden until both sides submit, so neither can retaliate.
      const { rows: [review] } = await query(
        `INSERT INTO reviews (booking_id, author_type, author_id, subject_id, rating, tags, comment, is_hidden)
         VALUES ($1,$2,$3,$4,$5,$6,$7,true)
         ON CONFLICT (booking_id, author_type) DO NOTHING RETURNING *`,
        [booking.id, authorType, req.user.id, subjectId, req.body.rating, req.body.tags, req.body.comment]);
      if (!review) throw AppError.conflict('ALREADY_REVIEWED', 'You already reviewed this job');

      const { rows: [{ count }] } = await query(
        'SELECT COUNT(*)::int AS count FROM reviews WHERE booking_id = $1', [booking.id]);
      if (count === 2) {
        await query('UPDATE reviews SET is_hidden = false WHERE booking_id = $1', [booking.id]);
        await ratingQueue.add('recompute', { cleanerId: booking.cleaner_id });
      }

      res.status(201).json({ review: { ...review, is_hidden: count < 2 } });
    } catch (err) { next(err); }
  });

router.get('/cleaners/:id/reviews', async (req, res, next) => {
  try {
    const { rows } = await query(
      `SELECT r.rating, r.tags, r.comment, r.created_at, u.full_name AS author_first_name
         FROM reviews r JOIN users u ON u.id = r.author_id
        WHERE r.subject_id = $1 AND r.author_type = 'customer' AND r.is_hidden = false
        ORDER BY r.created_at DESC LIMIT $2`,
      [req.params.id, Math.min(Number(req.query.limit) || 20, 50)]);
    const { rows: [snap] } = await query(
      'SELECT bayesian_rating, review_count, jobs_completed FROM cleaner_rating_snapshot WHERE cleaner_id = $1',
      [req.params.id]);
    res.json({
      summary: snap ?? null,
      reviews: rows.map((r) => ({ ...r, author_first_name: r.author_first_name?.split(' ')[0] })),
    });
  } catch (err) { next(err); }
});

export default router;

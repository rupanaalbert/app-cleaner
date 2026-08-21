import { Router } from 'express';
import { z } from 'zod';
import { requireAuth } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { query } from '../../db/pool.js';
import { config } from '../../config/index.js';
import { privacyQueue } from '../../jobs/queues.js';

const router = Router();

/** GDPR Art. 15 / 20 — access and portability. */
router.get('/export', requireAuth, async (req, res, next) => {
  try {
    const { rows: [request] } = await query(
      `INSERT INTO data_requests (user_id, kind) VALUES ($1,'export') RETURNING id`, [req.user.id]);
    await privacyQueue.add('export', { userId: req.user.id, requestId: request.id });
    res.status(202).json({ request_id: request.id, message: 'Your data export will be emailed within 30 days.' });
  } catch (err) { next(err); }
});

/**
 * GDPR Art. 17 — erasure, with a 14-day grace window (logging back in cancels it).
 * Financial records survive under the legal-obligation exemption; say so plainly.
 */
router.delete('/', requireAuth, async (req, res, next) => {
  try {
    const scheduledFor = new Date(Date.now() + config.privacy.erasureGraceDays * 86_400_000);
    const { rows: [request] } = await query(
      `INSERT INTO data_requests (user_id, kind, scheduled_for) VALUES ($1,'erasure',$2) RETURNING id`,
      [req.user.id, scheduledFor]);
    await privacyQueue.add('erasure', { userId: req.user.id },
      { delay: config.privacy.erasureGraceDays * 86_400_000, jobId: `erasure:${req.user.id}` });
    res.status(202).json({
      request_id: request.id,
      scheduled_for: scheduledFor,
      retained: 'Invoices and payout records are kept for 7 years to meet tax and accounting obligations.',
    });
  } catch (err) { next(err); }
});

/** CCPA do-not-sell/share. */
router.patch('/privacy', requireAuth, validate(z.object({ dns_optout: z.boolean() })),
  async (req, res, next) => {
    try {
      await query('UPDATE users SET dns_optout = $2 WHERE id = $1', [req.user.id, req.body.dns_optout]);
      res.json({ dns_optout: req.body.dns_optout });
    } catch (err) { next(err); }
  });

router.post('/consents', requireAuth,
  validate(z.object({ purpose: z.string(), version: z.string(), granted: z.boolean() })),
  async (req, res, next) => {
    try {
      await query(
        `INSERT INTO consents (user_id, purpose, version, ip_address, user_agent, withdrawn_at)
         VALUES ($1,$2,$3,$4,$5, CASE WHEN $6 THEN NULL ELSE now() END)`,
        [req.user.id, req.body.purpose, req.body.version, req.ip, req.get('user-agent'), req.body.granted]);
      res.status(201).json({ recorded: true });
    } catch (err) { next(err); }
  });

export default router;

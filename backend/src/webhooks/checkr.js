import { Router } from 'express';
import crypto from 'node:crypto';
import { query } from '../db/pool.js';
import { logger } from '../utils/logger.js';

const router = Router();

/** Checkr status → our gate. Only the status and report id are stored, never the report body. */
const STATUS_MAP = {
  clear: 'clear',
  consider: 'consider',
  suspended: 'suspended',
  dispute: 'consider',
};

router.post('/', async (req, res) => {
  const signature = req.get('x-checkr-signature');
  const expected = crypto.createHmac('sha256', process.env.CHECKR_WEBHOOK_SECRET ?? '')
    .update(req.body).digest('hex');
  if (!signature || !crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) {
    return res.status(400).send('invalid signature');
  }

  const event = JSON.parse(req.body.toString());
  const { rowCount } = await query(
    `INSERT INTO webhook_events (id, provider, event_type, payload)
     VALUES ($1,'checkr',$2,$3) ON CONFLICT (id) DO NOTHING`,
    [event.id, event.type, event],
  );
  if (rowCount === 0) return res.json({ received: true, duplicate: true });

  if (event.type === 'report.completed') {
    const status = STATUS_MAP[event.data.object.status] ?? 'consider';
    await query(
      `UPDATE cleaner_profiles
          SET bg_status = $2,
              bg_completed_at = now(),
              bg_expires_at = now() + interval '1 year',
              onboarding_status = CASE WHEN $2 = 'clear' THEN 'approved' ELSE onboarding_status END
        WHERE bg_report_id = $1`,
      [event.data.object.id, status],
    );
    logger.info({ reportId: event.data.object.id, status }, 'background check resolved');
  }

  await query('UPDATE webhook_events SET processed_at = now() WHERE id = $1', [event.id]);
  res.json({ received: true });
});

export default router;

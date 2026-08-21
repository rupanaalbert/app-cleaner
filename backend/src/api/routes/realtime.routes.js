import { Router } from 'express';
import { z } from 'zod';
import rateLimit from 'express-rate-limit';
import { requireAuth, requireRole, requireBookingParty } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { RealtimeService } from '../../services/realtime.service.js';

const router = Router();

/** Exchange an API token for a Firebase custom token. Short-lived by design. */
router.post('/realtime/token', requireAuth, async (req, res, next) => {
  try {
    const token = await RealtimeService.mintToken(req.user.id, req.user.role);
    res.json({ firebase_token: token, expires_in: 3600 });
  } catch (err) { next(err); }
});

/**
 * Coarse breadcrumb, one per minute. The live 10-second stream never touches
 * this tier — a limit here is what keeps a buggy client from turning the
 * dispute trail into a firehose.
 */
const breadcrumbLimiter = rateLimit({
  windowMs: 60_000, max: 3, standardHeaders: 'draft-7', legacyHeaders: false,
  keyGenerator: (req) => `${req.user.id}:${req.params.id}`,
});

router.post('/bookings/:id/breadcrumb',
  requireAuth, requireRole('cleaner'), requireBookingParty, breadcrumbLimiter,
  validate(z.object({
    lat: z.number().min(-90).max(90),
    lng: z.number().min(-180).max(180),
  })),
  async (req, res, next) => {
    try {
      await RealtimeService.recordBreadcrumb(req.params.id, req.body);
      res.status(204).end();
    } catch (err) { next(err); }
  });

export default router;

import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, requireRole } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { OfferController } from '../controllers/offer.controller.js';

const router = Router();

router.get('/cleaner/offers', requireAuth, requireRole('cleaner'), OfferController.list);
router.post('/offers/:id/accept', requireAuth, requireRole('cleaner'), OfferController.accept);
router.post('/offers/:id/decline', requireAuth, requireRole('cleaner'),
  validate(z.object({ reason: z.enum(['too_far', 'bad_timing', 'low_pay', 'other']) })),
  OfferController.decline);

export default router;

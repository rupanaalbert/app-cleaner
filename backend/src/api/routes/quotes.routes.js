import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, requireRole } from '../../middleware/auth.js';
import { validate } from '../../middleware/validate.js';
import { quoteLimiter } from '../../middleware/rateLimit.js';
import { QuoteController } from '../controllers/quote.controller.js';

const router = Router();

const createQuote = z.object({
  property_id: z.string().uuid(),
  service_code: z.enum(['standard', 'deep']),
  addon_codes: z.array(z.string()).max(6).default([]),
  scheduled_at: z.coerce.date(),
});

router.post('/', requireAuth, requireRole('customer'), quoteLimiter,
  validate(createQuote), QuoteController.create);

router.post('/:id/paypal-order', requireAuth, requireRole('customer'), QuoteController.createPaypalOrder);

export default router;
